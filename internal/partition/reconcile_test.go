package partition

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"testing"
	"time"
)

// fakeLifecycle is a hand-written test double (no mock framework) that records
// the ordered sequence of lifecycle calls RunReconcile makes, and can inject
// errors and a canned expired set.
type fakeLifecycle struct {
	log       []string
	expired   []Info
	gotCutoff time.Time
	behind    bool // canned EnsureCurrent return
	ensureErr error
	findErr   error
	detachErr error
	dropErr   error
}

func (f *fakeLifecycle) EnsureFuture(_ context.Context, parent, schema, column, period string, count int, _ time.Time, _ Boundary, leafPrefix string) error {
	entry := fmt.Sprintf("ensure %s.%s col=%s %s x%d", schema, parent, column, period, count)
	if leafPrefix != "" {
		entry += " pfx=" + leafPrefix
	}
	f.log = append(f.log, entry)
	return f.ensureErr
}
func (f *fakeLifecycle) EnsureCurrent(_ context.Context, parent, schema, period string, _ time.Time, _ Boundary, leafPrefix string) (bool, error) {
	entry := fmt.Sprintf("current %s.%s %s", schema, parent, period)
	if leafPrefix != "" {
		entry += " pfx=" + leafPrefix
	}
	f.log = append(f.log, entry)
	return f.behind, f.ensureErr
}
func (f *fakeLifecycle) EnsureListChild(_ context.Context, parent, schema, listValue, childName, rangeCol string) error {
	f.log = append(f.log, fmt.Sprintf("listchild %s.%s in=%s range=%s", schema, childName, listValue, rangeCol))
	return f.ensureErr
}
func (f *fakeLifecycle) FindExpired(_ context.Context, parent, schema string, cutoff time.Time, _ Boundary) ([]Info, error) {
	f.gotCutoff = cutoff
	f.log = append(f.log, fmt.Sprintf("find %s.%s", schema, parent))
	return f.expired, f.findErr
}
func (f *fakeLifecycle) Detach(_ context.Context, _, _, partName string) error {
	f.log = append(f.log, "detach "+partName)
	return f.detachErr
}
func (f *fakeLifecycle) Drop(_ context.Context, _, partName string) error {
	f.log = append(f.log, "drop "+partName)
	return f.dropErr
}

func testSpec() Spec {
	return Spec{
		Parent: "events", Schema: "public", Column: "ts",
		Period: PeriodMonthly, Premake: 3, Retention: 90 * 24 * time.Hour,
	}
}

func TestRunReconcile_CustomExpireOwnsRemoval(t *testing.T) {
	f := &fakeLifecycle{expired: []Info{{Name: "p_2026_01"}, {Name: "p_2026_02"}}}
	// A custom ExpireFunc owns the whole expiry; the core must NOT also detach/drop.
	expire := func(_ context.Context, p Info) error { f.log = append(f.log, "expire "+p.Name); return nil }

	if err := RunReconcile(context.Background(), f, testSpec(), time.Now(), expire); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	want := []string{
		"ensure public.events col=ts monthly x3",
		"current public.events monthly",
		"find public.events",
		"expire p_2026_01",
		"expire p_2026_02",
	}
	if got := strings.Join(f.log, "|"); got != strings.Join(want, "|") {
		t.Fatalf("call order mismatch:\n got: %v\nwant: %v", f.log, want)
	}
	for _, c := range f.log {
		if strings.HasPrefix(c, "detach") || strings.HasPrefix(c, "drop") {
			t.Fatalf("core detached/dropped despite a custom ExpireFunc: %v", f.log)
		}
	}
}

func TestRunReconcile_NilHookJustDetachDrops(t *testing.T) {
	f := &fakeLifecycle{expired: []Info{{Name: "p_old"}}}
	if err := RunReconcile(context.Background(), f, testSpec(), time.Now(), nil); err != nil {
		t.Fatal(err)
	}
	want := []string{"ensure public.events col=ts monthly x3", "current public.events monthly", "find public.events", "detach p_old", "drop p_old"}
	if got := strings.Join(f.log, "|"); got != strings.Join(want, "|") {
		t.Fatalf("got %v want %v", f.log, want)
	}
}

func TestRunReconcile_DetachOnlyDoesNotDrop(t *testing.T) {
	f := &fakeLifecycle{expired: []Info{{Name: "p_old"}}}
	s := testSpec()
	s.Strategy = StrategyDetach
	if err := RunReconcile(context.Background(), f, s, time.Now(), nil); err != nil {
		t.Fatal(err)
	}
	want := []string{"ensure public.events col=ts monthly x3", "current public.events monthly", "find public.events", "detach p_old"}
	if got := strings.Join(f.log, "|"); got != strings.Join(want, "|") {
		t.Fatalf("got %v want %v", f.log, want)
	}
	for _, c := range f.log {
		if strings.HasPrefix(c, "drop") {
			t.Fatalf("detach-only strategy must NOT drop: %v", f.log)
		}
	}
}

func TestRunReconcile_ExpireErrorStops(t *testing.T) {
	f := &fakeLifecycle{expired: []Info{{Name: "p1"}}}
	boom := errors.New("export failed")
	expire := func(_ context.Context, p Info) error { f.log = append(f.log, "expire "+p.Name); return boom }

	err := RunReconcile(context.Background(), f, testSpec(), time.Now(), expire)
	if !errors.Is(err, boom) {
		t.Fatalf("want boom wrapped, got %v", err)
	}
	for _, c := range f.log {
		if strings.HasPrefix(c, "detach") || strings.HasPrefix(c, "drop") {
			t.Fatalf("detach/drop ran despite expire error: %v", f.log)
		}
	}
}

func TestRunReconcile_FailsLoudWhenBehind(t *testing.T) {
	f := &fakeLifecycle{behind: true, expired: []Info{{Name: "p_old"}}}
	err := RunReconcile(context.Background(), f, testSpec(), time.Now(), nil)
	if !errors.Is(err, ErrBehind) {
		t.Fatalf("want ErrBehind wrapped, got %v", err)
	}
	// The pass still heals (EnsureCurrent) and runs retention before failing loud.
	joined := strings.Join(f.log, "|")
	for _, want := range []string{"current public.events", "detach p_old", "drop p_old"} {
		if !strings.Contains(joined, want) {
			t.Fatalf("expected %q in log %v", want, f.log)
		}
	}
}

func TestRunReconcileTwoLevel_BehindSubtreeDoesNotBlockSiblings(t *testing.T) {
	// behind=true makes every child report behind; both must still be provisioned
	// (listchild + ensure for each) and the call must wrap ErrBehind, not abort.
	f := &fakeLifecycle{behind: true}
	s := Spec{Parent: "events", Schema: "public", Column: "ts", Period: PeriodMonthly, Premake: 1}
	err := RunReconcileTwoLevel(context.Background(), f, s, []string{"eu", "us"}, time.Now(), nil)
	if !errors.Is(err, ErrBehind) {
		t.Fatalf("want ErrBehind, got %v", err)
	}
	joined := strings.Join(f.log, "|")
	for _, want := range []string{"listchild public.events_eu", "listchild public.events_us"} {
		if !strings.Contains(joined, want) {
			t.Fatalf("sibling not provisioned: missing %q in %v", want, f.log)
		}
	}
}

func TestRunReconcile_CutoffIsNowMinusRetention(t *testing.T) {
	f := &fakeLifecycle{}
	now := time.Date(2026, 6, 1, 0, 0, 0, 0, time.UTC)
	if err := RunReconcile(context.Background(), f, testSpec(), now, nil); err != nil {
		t.Fatal(err)
	}
	if want := now.Add(-90 * 24 * time.Hour); !f.gotCutoff.Equal(want) {
		t.Fatalf("cutoff = %v, want %v", f.gotCutoff, want)
	}
}

func TestRunReconcile_EnsureErrorStopsBeforeFind(t *testing.T) {
	f := &fakeLifecycle{ensureErr: errors.New("nope")}
	if err := RunReconcile(context.Background(), f, testSpec(), time.Now(), nil); err == nil {
		t.Fatal("expected error")
	}
	if len(f.log) != 1 {
		t.Fatalf("expected to stop after ensure, got %v", f.log)
	}
}

func TestParseRetention(t *testing.T) {
	tests := []struct {
		input string
		hours int
		err   bool
	}{
		{"1 day", 24, false},
		{"7 days", 168, false},
		{"1 month", 720, false},
		{"3 months", 2160, false},
		{"1 year", 8760, false},
		{"2 weeks", 336, false},
		{"bad", 0, true},
		{"1 fortnight", 0, true},
	}
	for _, tt := range tests {
		t.Run(tt.input, func(t *testing.T) {
			d, err := ParseRetention(tt.input)
			if tt.err {
				if err == nil {
					t.Fatalf("expected error for %q", tt.input)
				}
				return
			}
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if int(d.Hours()) != tt.hours {
				t.Fatalf("%q: got %d hours, want %d", tt.input, int(d.Hours()), tt.hours)
			}
		})
	}
}
