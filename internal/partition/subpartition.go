package partition

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
)

// maxIdentLen is PostgreSQL's identifier limit (NAMEDATALEN-1). A name longer
// than this is silently truncated by the server, which can collide two distinct
// partitions; we fail loud instead.
const maxIdentLen = 63

// checkIdent rejects a generated identifier that PostgreSQL would truncate.
func checkIdent(name string) error {
	if len(name) > maxIdentLen {
		return fmt.Errorf("generated identifier %q is %d bytes; PostgreSQL truncates at %d (shorten the table or sub-partition value)", name, len(name), maxIdentLen)
	}
	return nil
}

// SubName derives the level-1 (LIST) child table name for one value: the parent
// name, an underscore, and the value sanitized to a legal identifier fragment
// (lowercased, non-[a-z0-9_] runes mapped to _). The raw value is still used
// verbatim in FOR VALUES IN; only the table name is sanitized. It errors if the
// result leaves no room for the longest RANGE-leaf suffix within maxIdentLen.
func SubName(parent, value string) (string, error) {
	var b strings.Builder
	for _, r := range strings.ToLower(value) {
		if (r >= 'a' && r <= 'z') || (r >= '0' && r <= '9') || r == '_' {
			b.WriteRune(r)
		} else {
			b.WriteRune('_')
		}
	}
	name := parent + "_" + b.String()
	// Reserve room for "_" + the longest leaf name (daily: p_YYYY_MM_DD = 12).
	if len(name) > maxIdentLen-13 {
		return "", fmt.Errorf("sub-partition name %q is too long to hold a leaf within %d bytes", name, maxIdentLen)
	}
	return name, nil
}

// EnsureListChild creates the level-1 LIST child <childName> as a partition of
// <parent> for one list value, itself sub-partitioned BY RANGE on rangeCol. It
// is idempotent (IF NOT EXISTS). The list value is emitted as a quoted string
// literal; the column and table names go through pgx.Identifier.
func (m *Manager) EnsureListChild(ctx context.Context, parent, schema, listValue, childName, rangeCol string) error {
	sql := fmt.Sprintf(
		`CREATE TABLE IF NOT EXISTS %s PARTITION OF %s FOR VALUES IN ('%s') PARTITION BY RANGE (%s)`,
		pgx.Identifier{schema, childName}.Sanitize(),
		pgx.Identifier{schema, parent}.Sanitize(),
		strings.ReplaceAll(listValue, "'", "''"),
		pgx.Identifier{rangeCol}.Sanitize())
	if _, err := m.db.Exec(ctx, sql); err != nil {
		return fmt.Errorf("create list child %s: %w", childName, err)
	}
	return nil
}

// ListValues runs the configured values_source query and returns its single
// text column — the current set of level-1 values to provision sub-trees for.
func (m *Manager) ListValues(ctx context.Context, query string) ([]string, error) {
	rows, err := m.db.Query(ctx, query)
	if err != nil {
		return nil, fmt.Errorf("values_source query: %w", err)
	}
	defer rows.Close()
	var values []string
	for rows.Next() {
		var v string
		if err := rows.Scan(&v); err != nil {
			return nil, fmt.Errorf("scan values_source: %w", err)
		}
		values = append(values, v)
	}
	return values, rows.Err()
}

// SubLifecycle is the Lifecycle plus level-1 child creation — the surface
// RunReconcileTwoLevel drives.
type SubLifecycle interface {
	Lifecycle
	EnsureListChild(ctx context.Context, parent, schema, listValue, childName, rangeCol string) error
}

var _ SubLifecycle = (*Manager)(nil)

// RunReconcileTwoLevel reconciles a LIST(level-1) → RANGE(level-2) table. For
// each level-1 value it ensures the LIST child exists (sub-partitioned by the
// RANGE column) and then runs the ordinary single-level RANGE reconcile beneath
// that child — so premake, retention and the ExpireFunc seam are reused exactly,
// only the parent and leaf-name prefix change. A newly appearing value gets its
// forward window provisioned automatically on the next pass. Two values that
// sanitize to the same child name fail loud rather than clobber one sub-tree.
func RunReconcileTwoLevel(ctx context.Context, lc SubLifecycle, s Spec, values []string, now time.Time, expire ExpireFunc) error {
	seen := make(map[string]string, len(values))
	var behind []string
	for _, v := range values {
		child, err := SubName(s.Parent, v)
		if err != nil {
			return err
		}
		if prev, ok := seen[child]; ok {
			return fmt.Errorf("sub-partition name collision: values %q and %q both map to %q", prev, v, child)
		}
		seen[child] = v

		if err := lc.EnsureListChild(ctx, s.Parent, s.Schema, v, child, s.Column); err != nil {
			return err
		}
		childSpec := s
		childSpec.Parent = child
		childSpec.LeafPrefix = child + "_"
		// A behind sub-tree is healed in place; collect it and keep going so one
		// lagging value never blocks provisioning the rest. Any other error is
		// fatal for the pass.
		if err := RunReconcile(ctx, lc, childSpec, now, expire); err != nil {
			if errors.Is(err, ErrBehind) {
				behind = append(behind, child)
				continue
			}
			return fmt.Errorf("reconcile sub-tree %s: %w", child, err)
		}
	}
	if len(behind) > 0 {
		return fmt.Errorf("%w: sub-trees healed but lagging: %s", ErrBehind, strings.Join(behind, ", "))
	}
	return nil
}
