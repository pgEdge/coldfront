package partition

import (
	"context"
	"fmt"
	"time"
)

// Spec is one table's partition-lifecycle job — the inputs a single reconcile
// pass needs. An upper layer (or a standalone manager) maps its own per-table
// config onto this; the partition core stays agnostic about where it came from.
type Spec struct {
	Parent     string        // the partitioned table
	Schema     string        // its schema
	Column     string        // the RANGE key column
	Period     string        // PeriodMonthly | PeriodDaily
	Premake    int           // future partitions kept ahead of now
	Retention  time.Duration // detach+drop partitions whose upper bound is older than now-Retention
	Boundary   Boundary      // how the RANGE key maps to time; nil means TimeBoundary
	LeafPrefix string        // prepended to leaf names; "" for single-level (set per-child in 2-level)
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
	expired, err := lc.FindExpired(ctx, s.Parent, s.Schema, now.Add(-s.Retention), b)
	if err != nil {
		return fmt.Errorf("find expired %s.%s: %w", s.Schema, s.Parent, err)
	}
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
		if err := lc.Drop(ctx, s.Schema, p.Name); err != nil {
			return err
		}
	}
	return nil
}

// ParseRetention parses a "N unit" string ("3 months", "7 days", "2 weeks",
// "1 year") into a Duration, using approximate 30-day months and 365-day years.
// Good enough for retention comparisons — the cutoff need only land safely
// within the target period; exact PG interval arithmetic is not required.
func ParseRetention(s string) (time.Duration, error) {
	var n int
	var unit string
	if _, err := fmt.Sscanf(s, "%d %s", &n, &unit); err != nil {
		return 0, fmt.Errorf("invalid interval %q: expected \"N unit\"", s)
	}
	switch unit {
	case "day", "days":
		return time.Duration(n) * 24 * time.Hour, nil
	case "week", "weeks":
		return time.Duration(n) * 7 * 24 * time.Hour, nil
	case "month", "months":
		return time.Duration(n) * 30 * 24 * time.Hour, nil
	case "year", "years":
		return time.Duration(n) * 365 * 24 * time.Hour, nil
	default:
		return 0, fmt.Errorf("unsupported interval unit %q", unit)
	}
}
