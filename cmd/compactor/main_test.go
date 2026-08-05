package main

import (
	"context"
	"net"
	"strings"
	"sync/atomic"
	"testing"
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
