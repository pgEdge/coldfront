package main

import (
	"context"
	"net"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

// The claim wrapper opens PG lazily so a pure --dry-run, which claims nothing,
// never touches the database. A local listener that accepts and immediately
// closes stands in for PG: it counts connection attempts, and pgx fails fast on
// the missing handshake.
func TestNewClaimer_ConnectsOnFirstClaimOnly(t *testing.T) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	defer func() { _ = ln.Close() }()

	var accepted atomic.Int64
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			accepted.Add(1)
			_ = c.Close()
		}
	}()

	dsn := "postgres://u:p@" + ln.Addr().String() + "/db?sslmode=disable"
	claim, closeConn := newClaimer(context.Background(), dsn, `"ice"."public"."t"`)
	defer closeConn()

	if got := accepted.Load(); got != 0 {
		t.Fatalf("connected before any claim: %d connection(s)", got)
	}

	called := false
	err = claim(func() error {
		called = true
		return nil
	})
	if err == nil {
		t.Fatal("expected the claim to fail against a non-PG listener")
	}
	if !strings.Contains(err.Error(), "connect postgres (bakery)") {
		t.Fatalf("error lost its context: %v", err)
	}
	if called {
		t.Fatal("fn ran despite the connection failing")
	}
	if got := accepted.Load(); got == 0 {
		t.Fatal("the first claim did not attempt a connection")
	}
}

// checkFlags refuses, by flag name, a target size below 1 MiB or one whose byte
// count overflows int64, and an orphan age of 0 or less.
func TestCheckFlags_RefusesValuesTheCompactorCannotHonour(t *testing.T) {
	const sizeErr = "--target-size-mb must be between 1 and 8796093022207, got "
	cases := []struct {
		name      string
		targetMB  int64
		orphanAge time.Duration
		want      string
	}{
		{"zero size", 0, 72 * time.Hour, sizeErr + "0"},
		{"negative size", -5, 72 * time.Hour, sizeErr + "-5"},
		{"size whose bytes overflow", 8796093022208, 72 * time.Hour, sizeErr + "8796093022208"},
		{"zero orphan age", 128, 0, "--orphan-age must be positive, got 0s"},
		{"negative orphan age", 128, -time.Hour, "--orphan-age must be positive, got -1h0m0s"},
		{"defaults", 128, 72 * time.Hour, ""},
		{"smallest values", 1, time.Second, ""},
		{"largest size", 8796093022207, 72 * time.Hour, ""},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			err := checkFlags(c.targetMB, c.orphanAge)
			if c.want == "" {
				if err != nil {
					t.Fatalf("refused valid values: %v", err)
				}
				return
			}
			if err == nil || err.Error() != c.want {
				t.Fatalf("got %v, want %q", err, c.want)
			}
		})
	}
}
