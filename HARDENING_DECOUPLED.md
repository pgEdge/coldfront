# Hardening notes — decoupled-bakery patch

Context: the duckdb-iceberg patch that removes the cache-time
`parent_snapshot_id` stamp at Finalize and reads it fresh from
Lakekeeper inside the bakery hold in `IRCTransaction::DoTableUpdates`.
Validated on bench A (single writer, no contention) and bench C
(3 writers × 30M rows on 3 nodes, contention). No 409s, 2.62×
speedup vs A, 90M ↔ 90M ↔ 90M consistency. The notes below catalogue
what is *not* yet covered and where the residual risk lives.

## By-design limitations

### 1. External writers bypass the bakery

The bakery only serialises coldfront writers. If anything outside
coldfront writes to the same iceberg table while we hold a ticket
between our `GetTable` and our commit POST, the catalog head can
still move and produce a 409. Examples:

- A manual `curl` POST to the Lakekeeper REST API.
- A Spark / Flink / Trino job using the same warehouse.
- Another DuckDB process that has the same iceberg table attached
  and writes directly, not going through coldfront's wrapper view.

Mitigation: documented as single-system. Mixed-writer deployments
need a different serialisation strategy (catalog-side optimistic
retry, dedicated single-writer namespaces, etc.).

### 2. Multi-table writes in one transaction aren't atomically protected

`coldfront._exec_iceberg_with_claim(p_iceberg_table, p_sql)` takes
one iceberg table per call. The bakery ticket is per-table.

If a caller bypasses coldfront and writes to multiple iceberg tables
in one DuckDB transaction (via `duckdb.raw_query`), the patch
refreshes metadata for each touched table inside `DoTableUpdates`,
but no ticket gates them collectively. A concurrent commit on a
*different* table can still race the second-table-in-the-batch's
POST.

Mitigation: coldfront doesn't do this today. A future helper that
needs multi-table writes should acquire a batched ticket covering
the full set of tables before starting the INSERTs.

## Workloads not yet exercised

### 3. UPDATE / DELETE under contention

The patch targets `IcebergTableUpdateType::ADD_SNAPSHOT`. Both the
APPEND/DELETE Finalize site and the OVERWRITE Finalize site
(`AddUpdateSnapshot`) had the cache-time stamp removed, so the
refresh-and-stamp logic *should* apply to UPDATE / DELETE workloads
identically — but only INSERT was actually bench'd.

Follow-up: a 3-writer bench where each writer does
`UPDATE bench_evts SET status = ... WHERE id BETWEEN ...` and a
similar `DELETE` bench, to confirm the OVERWRITE snapshot path
under contention.

### 4. Schema change concurrent with INSERT

If one writer does `ALTER TABLE` and another does `INSERT` against
the same iceberg table, both go through `DoTableUpdates`. The patch
refreshes table_metadata before commit; iceberg's existing
`AssertCurrentSchemaIdRequirement` and `AssertLastAssignedFieldId`
should reject a stale-schema INSERT, but this combination wasn't
bench'd. Worst case: the INSERT writer commits against a refreshed
metadata that has the new schema and trips an existing precondition
loudly.

Follow-up: ALTER-on-A + INSERT-on-B + INSERT-on-C bench.

### 5. Multiple staged snapshots in one DuckDB transaction

Tested only via `coldfront.create_iceberg_table`'s priming step
(CREATE + INSERT prime + DELETE prime in one transaction, two
AddSnapshots staged, table being created). Passed.

The chain logic — first AddSnapshot in the staged-updates list
anchors to the freshly-refreshed catalog head (or to `has_parent =
false` for a being-created table), subsequent AddSnapshots chain
off the predecessor's `snapshot_id` and increment `sequence_number`
monotonically — has not been exercised on a workload that stages
many (5+) AddSnapshots from one transaction. Such a workload would
be the only one to catch a subtle off-by-one in `next_seq` or
`prev_snapshot_id`.

Follow-up: synthetic test that runs N back-to-back INSERTs inside
one PG transaction against an iceberg-only view, asserts N
snapshots with strictly monotonic sequence numbers, asserts each
snapshot's `parent_snapshot_id` matches the prior `snapshot_id`.

## Future-proofing

### 6. New upstream code paths in `DoTableUpdates`

The patch gates the refresh on two conditions:

1. The table's `transaction_data->updates` contains at least one
   `ADD_SNAPSHOT` (else: skip, nothing to re-stamp).
2. The table's `transaction_data->requirements` does NOT contain an
   `ASSERT_CREATE` (else: skip; table doesn't exist in the catalog
   yet, `GetTable` would 404).

If upstream adds new update or requirement types that change the
shape of a commit, the gates may misclassify. Concrete failure
modes:

- New requirement type that should also gate-out refresh
  (analogous to `ASSERT_CREATE`): patch attempts a `GetTable` that
  the upstream design expected to skip → throws → transaction
  aborts. Loud failure, not silent corruption.
- New update type that should be re-stamped like `ADD_SNAPSHOT`
  (e.g. a hypothetical `ADD_SNAPSHOT_OVERWRITE_REF`): patch skips
  re-stamping → that update's `parent_snapshot_id` (or analog) is
  stale → commit POST may or may not 409 depending on whether
  upstream validates it.

Mitigation: review the patch against upstream `DoTableUpdates`
diffs whenever rebasing onto a newer duckdb-iceberg release.

### 7. Tighter architectural separation

The current patch lives inline in `DoTableUpdates`, gated by
`has_add_snapshot` + `is_being_created`. A cleaner separation
(deferred for now — keeping the patch small until the LOGIC is
stable) would be:

- Expose a dedicated method on `IRCTransaction`,
  e.g. `RefreshMetadataForPendingSnapshots()`, that does only the
  refresh + re-stamp for staged `IcebergAddSnapshot`s on existing
  tables.
- Multitier calls it explicitly from `_exec_iceberg_with_claim`
  after `_claim_iceberg_lock`, before letting the function return,
  so the refresh runs inside the bakery hold but is not entangled
  with the generic commit path.
- `DoTableUpdates` stays pristine — no gating, no special cases.

Requires plumbing a SQL-callable wrapper (via pg_duckdb's
`duckdb.raw_query` or a new exposed function in duckdb-iceberg) so
plpgsql can invoke the C++ method. Tracked as a follow-up; not
needed for the current single use case.

## Performance

### 8. Extra GET per commit

One `IRCAPI::GetTable` per dirty iceberg table per commit POST,
~10-20 ms RTT to Lakekeeper. Hidden behind the ~300-400 ms commit
POST itself on our setup. On a faster local-network catalog the
overhead percentage would be larger but the absolute cost stays
~10-20 ms / commit.

Lakekeeper load doubles for the per-commit catalog API (one GET
plus one POST instead of one POST). Lakekeeper at our bench load
handled this with no observable backpressure.

## What we know is safe

- **Memory:** in-place mutation of already-allocated
  `IcebergAddSnapshot.snapshot` fields. All references are valid for
  the iteration scope.
- **Error handling:** `IRCAPI::GetTable` errors throw
  `InvalidConfigurationException`, which propagates through the
  existing `IRCTransaction::Commit` try / catch → PG transaction
  aborts → coldfront's C `XactCallback` releases the bakery
  regardless of whether the commit succeeded.
- **Manifest list content:** not touched by the patch. Still written
  exactly once by the existing `IcebergAddSnapshot::CreateUpdate`
  call inside `GetTransactionRequest`, after our re-stamp.
- **Single-writer throughput:** bench A pre-patch and post-patch
  match within noise (~93 s vs ~90 s on 90 M rows), confirming the
  patch adds no measurable overhead in the no-contention path.
- **Sequence number monotonicity:** under bakery serialisation each
  writer's refresh sees the previous writer's committed
  `last_sequence_number`, so the `++next_seq` stamp is strictly
  monotonic across writers.
- **Bakery release on commit failure:** coldfront's
  `_enqueue_release` queues the release via a C-side `XactCallback`
  that fires at PG transaction end regardless of commit / rollback,
  so a thrown exception inside `DoTableUpdates` cannot leak a
  claim row.

## Recommended next-actions before broader rollout

1. Bench (3) — UPDATE / DELETE under contention.
2. Bench (4) — concurrent schema change + INSERT.
3. Synthetic test (5) — many AddSnapshots per single transaction
   with sequence-number and parent-chain assertions.
4. Review the patch against any duckdb-iceberg upstream rebase
   before adopting newer versions.
