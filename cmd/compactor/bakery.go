package main

import (
	"context"
	"fmt"

	"github.com/jackc/pgx/v5"
)

// withBakeryClaim runs fn while holding the coldfront bakery claim for
// icebergRef, so the compactor's direct-to-Lakekeeper commit serializes against
// concurrent cold writers exactly like a cold write does — preserving the
// proactive no-409 guarantee.
//
// It opens ONE PG transaction and calls coldfront._claim_iceberg_external, which
// (mesh) takes the Ricart-Agrawala claim via _claim_iceberg_lock and arms the
// deferred release via _enqueue_release, or (vanilla) takes the local advisory
// xact lock — the same chokepoint cold writes use. fn then performs the
// iceberg-go RewriteDataFiles + Commit. Committing the PG transaction fires
// coldfront's C XactCallback, which releases the claim; on any error we roll
// back (vanilla: advisory lock auto-releases; mesh: the claim is reaped).
//
// The claim is therefore held across fn's entire read->rewrite->commit — the
// stock-ordering discipline the TLA+ model proves safe (docs/formal). fn must
// NOT defer its iceberg commit outside this window.
func withBakeryClaim(ctx context.Context, conn *pgx.Conn, icebergRef string, fn func() error) (err error) {
	tx, err := conn.Begin(ctx)
	if err != nil {
		return fmt.Errorf("begin bakery tx: %w", err)
	}
	committed := false
	defer func() {
		if !committed {
			_ = tx.Rollback(ctx)
		}
	}()

	if _, err = tx.Exec(ctx, "SELECT coldfront._claim_iceberg_external($1)", icebergRef); err != nil {
		return fmt.Errorf("acquire bakery claim for %s: %w", icebergRef, err)
	}
	if err = fn(); err != nil {
		return err // rollback releases the claim; no iceberg commit happened (or it failed)
	}
	if err = tx.Commit(ctx); err != nil {
		return fmt.Errorf("commit bakery tx (release claim) for %s: %w", icebergRef, err)
	}
	committed = true
	return nil
}
