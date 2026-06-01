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
	ensureErr error
	findErr   error
	detachErr error
	dropErr   error
}

func (f *fakeLifecycle) EnsureFuture(_ context.Context, parent, schema, column, period string, count int, _ time.Time) error {
	f.log = append(f.log, fmt.Sprintf("ensure %s.%s col=%s %s x%d", schema, parent, column, period, count))
	return f.ensureErr
}
func (f *fakeLifecycle) FindExpired(_ context.Context, parent, schema string, cutoff time.Time) ([]Info, error) {
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
	want := []string{"ensure public.events col=ts monthly x3", "find public.events", "detach p_old", "drop p_old"}
	if got := strings.Join(f.log, "|"); got != strings.Join(want, "|") {
		t.Fatalf("got %v want %v", f.log, want)
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
