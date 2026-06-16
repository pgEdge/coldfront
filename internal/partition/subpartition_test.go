package partition

import (
	"context"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
)

func TestSubName(t *testing.T) {
	cases := []struct {
		top, val, want string
		wantErr        bool
	}{
		{"events", "eu", "events_eu", false},
		{"events", "EU-West", "events_eu_west", false}, // lowercased, non-ident -> _
		{"events", "o'brien", "events_o_brien", false},
		{"events", strings.Repeat("x", 60), "", true}, // would overflow the 63-byte leaf budget
	}
	for _, c := range cases {
		got, err := SubName(c.top, c.val)
		if c.wantErr {
			if err == nil {
				t.Errorf("SubName(%q,%q): expected error", c.top, c.val)
			}
			continue
		}
		if err != nil {
			t.Errorf("SubName(%q,%q): %v", c.top, c.val, err)
			continue
		}
		if got != c.want {
			t.Errorf("SubName(%q,%q) = %q, want %q", c.top, c.val, got, c.want)
		}
	}
}

func TestEnsureListChild_SQL(t *testing.T) {
	db := &mockDB{}
	m := NewManager(db)
	if err := m.EnsureListChild(context.Background(), "events", "public", "eu", "events_eu", "ts"); err != nil {
		t.Fatal(err)
	}
	if len(db.execSQL) != 1 {
		t.Fatalf("expected 1 statement, got %d", len(db.execSQL))
	}
	sql := db.execSQL[0]
	for _, want := range []string{
		"CREATE TABLE IF NOT EXISTS",
		`"public"."events_eu"`,
		`PARTITION OF "public"."events"`,
		"FOR VALUES IN ('eu')",
		`PARTITION BY RANGE ("ts")`,
	} {
		if !strings.Contains(sql, want) {
			t.Errorf("SQL missing %q:\n%s", want, sql)
		}
	}
}

func TestEnsureListChild_EscapesValue(t *testing.T) {
	db := &mockDB{}
	m := NewManager(db)
	if err := m.EnsureListChild(context.Background(), "events", "public", "o'brien", "events_o_brien", "ts"); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(db.execSQL[0], "FOR VALUES IN ('o''brien')") {
		t.Fatalf("single quote not doubled:\n%s", db.execSQL[0])
	}
}

func TestListValues(t *testing.T) {
	db := &mockDB{
		rowsFunc: func(_ context.Context, _ string, _ ...any) (pgx.Rows, error) {
			return &mockRows{rows: []func(dest ...any) error{
				func(dest ...any) error { *(dest[0].(*string)) = "eu"; return nil },
				func(dest ...any) error { *(dest[0].(*string)) = "us"; return nil },
			}}, nil
		},
	}
	m := NewManager(db)
	got, err := m.ListValues(context.Background(), "SELECT code FROM regions")
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 2 || got[0] != "eu" || got[1] != "us" {
		t.Fatalf("ListValues = %v, want [eu us]", got)
	}
}

func TestRunReconcileTwoLevel_ProvisionsEachSubtree(t *testing.T) {
	f := &fakeLifecycle{}
	s := Spec{Parent: "events", Schema: "public", Column: "ts", Period: PeriodMonthly, Premake: 3, RetentionInterval: "90 days"}
	if err := RunReconcileTwoLevel(context.Background(), f, s, []string{"eu", "us"}, time.Now(), nil); err != nil {
		t.Fatal(err)
	}
	want := []string{
		"listchild public.events_eu in=eu range=ts",
		"ensure public.events_eu col=ts monthly x3 pfx=events_eu_",
		"current public.events_eu monthly pfx=events_eu_",
		"find public.events_eu",
		"listchild public.events_us in=us range=ts",
		"ensure public.events_us col=ts monthly x3 pfx=events_us_",
		"current public.events_us monthly pfx=events_us_",
		"find public.events_us",
	}
	if got := strings.Join(f.log, "|"); got != strings.Join(want, "|") {
		t.Fatalf("call order mismatch:\n got: %v\nwant: %v", f.log, want)
	}
}

func TestRunReconcileTwoLevel_CollisionFailsLoud(t *testing.T) {
	f := &fakeLifecycle{}
	s := Spec{Parent: "events", Schema: "public", Column: "ts", Period: PeriodMonthly, Premake: 1}
	// "eu-west" and "eu_west" both sanitize to events_eu_west: a silent
	// table-name collision must fail loud, not clobber one subtree.
	err := RunReconcileTwoLevel(context.Background(), f, s, []string{"eu-west", "eu_west"}, time.Now(), nil)
	if err == nil || !strings.Contains(err.Error(), "collision") {
		t.Fatalf("expected collision error, got %v", err)
	}
}
