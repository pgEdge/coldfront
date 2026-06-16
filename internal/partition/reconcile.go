package partition

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"
)

// ErrBehind reports that premake had fallen behind: the table already had a
// past partition but none covered `now` when a reconcile pass began, so live
// inserts had no home. (A fresh table with only just-premade future partitions
// is NOT behind — see EnsureCurrent.) RunReconcile heals it (creates the current
// partition) and then returns an error wrapping ErrBehind, so the run exits loud
// while the table is left correct. Callers distinguish it with errors.Is.
var ErrBehind = errors.New("premake fell behind")

// Spec is one table's partition-lifecycle job — the inputs a single reconcile
// pass needs. An upper layer (or a standalone manager) maps its own per-table
// config onto this; the partition core stays agnostic about where it came from.
type Spec struct {
	Parent            string   // the partitioned table
	Schema            string   // its schema
	Column            string   // the RANGE key column
	Period            string   // PeriodMonthly | PeriodDaily
	Premake           int      // future partitions kept ahead of now
	RetentionInterval string   // a PostgreSQL interval ("90 days", "1 year"); expire partitions older than now - this. "" ⇒ no expiry.
	Boundary          Boundary // how the RANGE key maps to time; nil means TimeBoundary
	LeafPrefix        string   // prepended to leaf names; "" for single-level (set per-child in 2-level)
	Strategy          string   // StrategyDrop (default, ""⇒drop) or StrategyDetach; default-path expiry only
}

// boundary returns the Spec's Boundary, defaulting to time-mode so a zero Spec
// (and every existing time-keyed caller) behaves exactly as before.
func (s Spec) boundary() Boundary {
	if s.Boundary == nil {
		return TimeBoundary{}
	}
	return s.Boundary
}

// Lifecycle is the subset of *Manager that RunReconcile drives. Expressing it as
// an interface keeps RunReconcile unit-testable with a hand-written fake and
// keeps this orchestration free of any concrete DB type.
type Lifecycle interface {
	EnsureFuture(ctx context.Context, parent, schema, column, period string, count int, now time.Time, b Boundary, leafPrefix string) error
	EnsureCurrent(ctx context.Context, parent, schema, period string, now time.Time, b Boundary, leafPrefix string) (behind bool, err error)
	// ExpiryCutoff resolves now - interval using PostgreSQL interval arithmetic
	// (calendar-accurate: real months/years, leap days), returning the instant
	// before which partitions have expired. Done in the DB, never in Go, so a
	// free-form PG interval never has to round-trip through a time.Duration.
	ExpiryCutoff(ctx context.Context, now time.Time, interval string) (time.Time, error)
	FindExpired(ctx context.Context, parent, schema string, cutoff time.Time, b Boundary) ([]Info, error)
	Detach(ctx context.Context, parent, schema, partName string) error
	Drop(ctx context.Context, schema, partName string) error
}

// *Manager is the production Lifecycle; assert it at compile time so a signature
// drift in either place is caught by the build, not at runtime.
var _ Lifecycle = (*Manager)(nil)

// ExpireFunc handles one expired partition end to end and OWNS its removal. The
// default (a nil ExpireFunc) is Detach + Drop — the standalone partition
// manager. An upper layer supplies one that does its own work and performs the
// removal itself: e.g. a cold-storage export whose cutover issues the DETACH
// atomically with its catalog/view update, so the core must NOT also detach.
// This is the single seam by which retention is specialised WITHOUT the
// partition core depending on that layer — the dependency points strictly down.
type ExpireFunc func(ctx context.Context, p Info) error

// RunReconcile brings one table's partitions to the desired state: premake the
// forward window, then expire every partition past retention. Expiry runs the
// ExpireFunc when one is supplied (it owns the removal), else the default
// Detach + Drop. Unconditional — no external cutoff gate, no branch. The DDL the
// default path issues runs top-level on the pool (DETACH ... CONCURRENTLY cannot
// run inside a transaction), so callers must pass a non-transactional handle.
func RunReconcile(ctx context.Context, lc Lifecycle, s Spec, now time.Time, expire ExpireFunc) error {
	b := s.boundary()
	if err := lc.EnsureFuture(ctx, s.Parent, s.Schema, s.Column, s.Period, s.Premake, now, b, s.LeafPrefix); err != nil {
		return fmt.Errorf("premake %s.%s: %w", s.Schema, s.Parent, err)
	}
	behind, err := lc.EnsureCurrent(ctx, s.Parent, s.Schema, s.Period, now, b, s.LeafPrefix)
	if err != nil {
		return fmt.Errorf("ensure current %s.%s: %w", s.Schema, s.Parent, err)
	}
	expired, err := resolveExpired(ctx, lc, s, now, b)
	if err != nil {
		return err
	}
	if err := expireAll(ctx, lc, s, expired, expire); err != nil {
		return err
	}
	if behind {
		return fmt.Errorf("%w for %s.%s: no partition covered %s at the start of the pass (created it now; widen premake=%d or run more often)",
			ErrBehind, s.Schema, s.Parent, now.Format(time.RFC3339), s.Premake)
	}
	return nil
}

// resolveExpired resolves the expiry cutoff in Postgres (calendar-accurate
// now - interval) and finds the partitions past it. An empty interval means no
// destroy boundary on this spec: skip expiry entirely (and never hand
// ”::interval to Postgres), returning no partitions.
func resolveExpired(ctx context.Context, lc Lifecycle, s Spec, now time.Time, b Boundary) ([]Info, error) {
	if s.RetentionInterval == "" {
		return nil, nil
	}
	cutoff, err := lc.ExpiryCutoff(ctx, now, s.RetentionInterval)
	if err != nil {
		return nil, fmt.Errorf("retention cutoff %s.%s: %w", s.Schema, s.Parent, err)
	}
	expired, err := lc.FindExpired(ctx, s.Parent, s.Schema, cutoff, b)
	if err != nil {
		return nil, fmt.Errorf("find expired %s.%s: %w", s.Schema, s.Parent, err)
	}
	return expired, nil
}

// expireAll removes every expired partition. A non-nil ExpireFunc owns the
// removal end to end; otherwise the default path detaches and (unless
// StrategyDetach leaves it in place as a standalone table) drops it.
func expireAll(ctx context.Context, lc Lifecycle, s Spec, expired []Info, expire ExpireFunc) error {
	for _, p := range expired {
		if expire != nil {
			if err := expire(ctx, p); err != nil {
				return fmt.Errorf("expire %s: %w", p.Name, err)
			}
			continue
		}
		if err := lc.Detach(ctx, s.Parent, s.Schema, p.Name); err != nil {
			return err
		}
		// StrategyDetach leaves the detached partition in place as a standalone
		// table (data preserved); the default (StrategyDrop / "") destroys it.
		if s.Strategy == StrategyDetach {
			continue
		}
		if err := lc.Drop(ctx, s.Schema, p.Name); err != nil {
			return err
		}
	}
	return nil
}

// RowQuerier is the one-row query surface ValidatePeriods needs — satisfied by
// *pgx.Conn, a pool, and partition.DBTX. Keeps the validator usable from both
// the CLI (a bare conn) and the binaries (the Manager's handle) without dragging
// in a concrete DB type.
type RowQuerier interface {
	QueryRow(ctx context.Context, sql string, args ...any) pgx.Row
}

// ValidatePeriods enforces the lifecycle-period rules that are PostgreSQL
// interval semantics, not Go's: each non-empty value must be a valid PG interval
// ("1 mon", "90 days", "1 year 2 mons", …), and when both are set retention must
// strictly exceed hot (a retention shorter than the hot window would destroy
// data before it ever tiers). Both checks run in one round-trip — the casts
// validate syntax and the comparison validates ordering. Empty means "unset".
// This is the single home for period validation (register, set, binary startup);
// the interval column type is the backstop for any write that bypasses it.
func ValidatePeriods(ctx context.Context, q RowQuerier, hot, retention string) error {
	switch {
	case hot != "" && retention != "":
		return validateOrdering(ctx, q, hot, retention)
	case hot != "":
		if err := validInterval(ctx, q, "hot_period", hot); err != nil {
			return err
		}
	case retention != "":
		if err := validInterval(ctx, q, "retention_period", retention); err != nil {
			return err
		}
	}
	return nil
}

// validateOrdering checks (in one round-trip) that retention strictly exceeds
// hot when both are set: the casts validate syntax and the comparison validates
// ordering. A retention shorter than the hot window would destroy data before
// it ever tiers.
func validateOrdering(ctx context.Context, q RowQuerier, hot, retention string) error {
	var ok bool
	if err := q.QueryRow(ctx, `SELECT $1::interval > $2::interval`, retention, hot).Scan(&ok); err != nil {
		return fmt.Errorf("invalid hot_period (%q) or retention_period (%q): %w", hot, retention, err)
	}
	if !ok {
		return fmt.Errorf("retention_period (%s) must exceed hot_period (%s)", retention, hot)
	}
	return nil
}

// validInterval confirms v parses as a PostgreSQL interval (the ::interval cast
// raises otherwise), naming the field in the error.
func validInterval(ctx context.Context, q RowQuerier, field, v string) error {
	var ok bool
	if err := q.QueryRow(ctx, `SELECT ($1::interval) IS NOT NULL`, v).Scan(&ok); err != nil {
		return fmt.Errorf("invalid %s interval %q: %w", field, v, err)
	}
	return nil
}
