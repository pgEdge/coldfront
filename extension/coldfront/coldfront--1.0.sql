\echo Use "CREATE EXTENSION coldfront" to load this file. \quit

DO $$ BEGIN
  CREATE SCHEMA coldfront;
EXCEPTION WHEN duplicate_schema THEN NULL;
END $$;

-- Registry of tiered views. Populated by the archiver on each table-swap,
-- or by coldfront.create_iceberg_table() in decoupled (iceberg-only) mode.
-- Keyed by the transparent view's (schema_name, relname). The name is stable
-- across the DROP+CREATE the archiver / DDL-rebuild does each cycle (a view OID
-- is not), and a name replicates cleanly across a Spock mesh (an OID is
-- node-local). The post_parse_analyze_hook resolves the target relation's name
-- here to decide whether to rewrite an UPDATE/DELETE into a dual-tier CTE.
--
-- hot_table and partition_col are NULLable: in iceberg-only mode there is no
-- PG-side hot heap, so neither field applies. The C hook checks
-- is_iceberg_only first and short-circuits to TIER_COLD without dereferencing
-- those columns.
CREATE TABLE coldfront.tiered_views (
    schema_name     text    NOT NULL,                  -- namespace of the transparent view
    relname         text    NOT NULL,                  -- name of the transparent view
    hot_table       text,                              -- 'public._events' (tiered) or NULL (iceberg-only)
    iceberg_table   text    NOT NULL,                  -- DuckDB ref, e.g. '"ice"."myapp"."events"'
    partition_col   text,                              -- 'ts' (tiered) or NULL (iceberg-only)
    is_iceberg_only boolean NOT NULL DEFAULT false,
    -- Whether the C hook rewrites INSERT/UPDATE/DELETE on this view, or refuses
    -- them. True for everything coldfront provisions, since it owns the Iceberg
    -- table it created or tiered into; false only for a table adopted from an
    -- existing catalog without p_writable, where reading someone else's lake
    -- must not become writing it by accident. Reads never consult it.
    is_writable     boolean NOT NULL DEFAULT true,
    -- The table's vector columns, in the order the Iceberg schema declares their
    -- cluster columns, or NULL when it has none. Recorded at registration because it
    -- cannot be derived afterwards in either mode: the view exposes real[] rather
    -- than the pgvector type, and a decoupled table names its types without holding
    -- them. Every cold write path asks here which columns its assignments describe.
    --
    -- The first element owns the file sort order and is the only one whose probe
    -- prunes row groups; see _vec_sort_key.
    vec_columns     text[],
    PRIMARY KEY (schema_name, relname),
    -- One relation per Iceberg table. _vec_list_cols_for_ref and
    -- _vec_list_prefix_for_ref resolve a table's cluster columns by ref, so two
    -- rows sharing one ref would make the first concatenate both tables' cluster
    -- columns into one INSERT list and the second fail with "more than one row
    -- returned by a subquery". Only adoption can name an existing ref twice.
    UNIQUE (iceberg_table)
);

-- Archive watermark: one row per managed (schema, table), recording the cutoff time
-- that divides the hot tier (rows with partition_col >= cutoff_time, living
-- in the PG heap as _<table>) from the cold tier (rows older than cutoff,
-- living in Iceberg as ice.<schema>.<table>). Written by the archiver at the
-- end of each archive cycle; read by the generated tiered view's hot/cold
-- UNION (internal/view/view.go) and by the coldfront rewriter's tier
-- classifier when deciding whether a predicate proves hot-only or cold-only.
--
-- Composite PK on (schema_name, table_name) because the archiver upserts this row every cycle via
-- ON CONFLICT (schema_name, table_name) DO UPDATE (internal/watermark/watermark.go:Set).
-- Created with IF NOT EXISTS because the archiver can also materialize it
-- on first run before CREATE EXTENSION runs against the DB.
--
-- A database the standalone partitioner set up before the extension holds
-- coldfront.partition_config as a plain table, and one the archiver ran on
-- holds archive_watermark the same way, both from the Go copies of this DDL
-- (internal/partcfg, internal/watermark). An extension script may skip
-- CREATE ... IF NOT EXISTS only for an object the extension owns, so such a
-- table is adopted first: its rows stay, and the pg_extension_config_dump
-- calls below then cover it like a table this script created.
DO $$
DECLARE t text;
BEGIN
    FOREACH t IN ARRAY ARRAY['archive_watermark', 'partition_config'] LOOP
        IF to_regclass('coldfront.' || t) IS NOT NULL AND NOT EXISTS (
               SELECT 1 FROM pg_depend
                WHERE classid = 'pg_class'::regclass
                  AND objid = to_regclass('coldfront.' || t)
                  AND refclassid = 'pg_extension'::regclass
                  AND deptype = 'e') THEN
            EXECUTE format('ALTER EXTENSION coldfront ADD TABLE coldfront.%I', t);
        END IF;
    END LOOP;
END $$;
CREATE TABLE IF NOT EXISTS coldfront.archive_watermark (
    schema_name text        NOT NULL,
    table_name  text        NOT NULL,
    cutoff_time timestamptz NOT NULL,
    PRIMARY KEY (schema_name, table_name)
);

-- coldfront._dummy_dml_target — a permanent, single-row DUMMY table whose data is
-- meaningless and which is NEVER written to. It exists for exactly one structural
-- reason, used ONLY in a narrow case:
--
-- Cold-tier DML is rewritten (in the parse-analyze hook) into a call to
-- coldfront._exec_iceberg_with_claim(...). At the top level that call is wrapped
-- in a plain SELECT — fine, the client discards the row. But inside a plpgsql
-- function / DO block / trigger, plpgsql rejects a bare result-returning SELECT
-- ("query has no destination for result data"); it only accepts a statement
-- whose command tag is a DML (INSERT/UPDATE/DELETE) returning no rows. So ONLY
-- when the hook detects it is running inside plpgsql, it wraps the cold call as a
-- DML over this table:
--
--   UPDATE coldfront._dummy_dml_target SET anchor = anchor
--    WHERE coldfront._exec_iceberg_with_claim(...) IS NULL
--
-- That is a DML (plpgsql accepts it), and the cold call runs exactly once — in
-- the WHERE qual, evaluated against the single row. _exec_iceberg_with_claim
-- returns VOID, and `void IS NULL` is ALWAYS false, so the WHERE matches zero
-- rows: the row is never updated -> no new tuple version, no dead tuple, no WAL,
-- no bloat, no vacuum, EVER. The table is a pure command-tag carrier. (In
-- dual-tier and tiered-INSERT rewrites the same UPDATE rides in a data-modifying
-- WITH-CTE, which PostgreSQL always runs to completion even when unreferenced.)
--
-- LOGGED on purpose: on a read-only standby an in-plpgsql cold write is then
-- rejected cleanly at executor start ("cannot execute UPDATE in a read-only
-- transaction") BEFORE the cold function runs — no stray Iceberg write from a
-- replica. The 0-row UPDATE writes no WAL, so LOGGED costs nothing here.
--
-- Node-local: each node's CREATE EXTENSION seeds its own single row; it is never
-- added to a replication set. Referenced ONLY by the in-plpgsql rewrite branch —
-- top-level cold DML never names it.
CREATE TABLE coldfront._dummy_dml_target (anchor boolean NOT NULL DEFAULT true);
INSERT INTO coldfront._dummy_dml_target DEFAULT VALUES;

-- Cold-tier S3 credential — the in-DB source of truth, set via
-- coldfront.set_storage_secret(). As an extension-member table its DATA is NOT
-- carried by pg_dump (no pg_extension_config_dump), and the one-time mesh step
-- coldfront.ensure_replicated() adds it to the Spock repset, so the row
-- replicates by value to every mesh node, unlike an FDW user-mapping (which
-- pg_dump DOES dump and which does not replicate).
--
-- The row is materialized into a DuckDB PERSISTENT SECRET (see
-- coldfront.materialize_storage_secret); DuckDB loads that at instance init, so
-- the credential is committed-visible BEFORE any query. That is what lets a
-- cold-write commit — which pg_duckdb runs in a fresh DuckDB transaction that
-- cannot see a secret registered in the still-open caller transaction — resolve
-- the credential on every PG major.
-- storage_type discriminates the cold-store backend: 's3' (AWS / any
-- S3-compatible store) or 'azure' (ADLS Gen2 over the DuckDB azure extension).
-- key_id/secret are the S3 access pair; connection_string carries the Azure
-- CONFIG-provider connection string (AccountName=…;AccountKey=…;EndpointSuffix=…)
-- — duckdb-azure has NO separate ACCOUNT_KEY param, so shared-key auth lives
-- entirely inside the connection string. The CHECKs enforce the right columns
-- per type (key_id/secret nullable so an azure row needs neither).
CREATE TABLE IF NOT EXISTS coldfront.storage_secret (
    name              text    NOT NULL DEFAULT 'cf_storage' PRIMARY KEY,
    storage_type      text    NOT NULL DEFAULT 's3',
    key_id            text,                            -- s3 only (NOT NULL enforced by ss_s3_creds)
    secret            text,                            -- s3 only
    endpoint          text,                            -- s3: NULL/'' ⇒ AWS default (vhost); set ⇒ path-style S3-compatible
    region            text    NOT NULL DEFAULT 'us-east-1',
    url_style         text    NOT NULL DEFAULT 'path',
    use_ssl           boolean NOT NULL DEFAULT false,
    connection_string text,                            -- azure CONFIG provider: AccountName/AccountKey (shared key)
    vended            boolean NOT NULL DEFAULT false,   -- true ⇒ Lakekeeper issues per-table creds; this row stores none
    CONSTRAINT ss_type_enum  CHECK (storage_type IN ('s3','azure')),
    CONSTRAINT ss_s3_creds   CHECK (vended OR storage_type <> 's3'
                                     OR (key_id IS NOT NULL AND secret IS NOT NULL)),
    CONSTRAINT ss_azure_conn CHECK (vended OR storage_type <> 'azure'
                                     OR (connection_string IS NOT NULL AND connection_string <> ''))
);

-- Per-table partition lifecycle config — the unified, name-keyed source of
-- truth that drives BOTH the standalone partitioner (partition-only lifecycle:
-- hot →retention_period→ dropped) and the tiered archiver (hot →hot_period→
-- cold →retention_period→ dropped). hot_period presence is the per-ROW mode
-- switch (NULL ⇒ partition-only). Name-keyed (schema,table — not OID, which
-- diverges per node) so it replicates by value across a Spock mesh, exactly
-- like coldfront.tiered_views / archive_watermark / claims. Connection config
-- (DSN, iceberg/S3 creds) is NOT stored here — it is per-node and must never
-- ride the replication stream. Mirrored by partcfg.EnsureTable so the vanilla
-- partitioner (stock PG, no extension) can self-materialize it.
--
-- hot_period/retention_period are native PostgreSQL `interval` columns: the
-- column type validates the value on write, and cutoffs are computed in-DB with
-- calendar-accurate interval arithmetic (now() - period). The retention>hot
-- invariant is operator-config policy, enforced at the register/CLI boundary
-- (partition.ValidatePeriods), not a CHECK — see partition_period below, which
-- stays text because it is a cadence enum, not a duration.
CREATE TABLE IF NOT EXISTS coldfront.partition_config (
    schema_name            text     NOT NULL DEFAULT 'public',
    table_name             text     NOT NULL,
    partition_period       text     NOT NULL,                 -- cadence enum ('monthly'/'daily'), NOT a duration
    partition_column       text,                              -- NULL ⇒ auto-detect (flat only)
    future_partitions      int      NOT NULL DEFAULT 3,
    part_mode              text     NOT NULL DEFAULT 'timestamp',
    id_scheme              text,
    hot_period             interval,                          -- NULL ⇒ partition-only; set ⇒ tiered
    retention_period       interval,
    sub_part_values_source text,                              -- NULL ⇒ flat; set ⇒ 2-level LIST→RANGE
    expiration_strategy     text    NOT NULL DEFAULT 'drop',   -- partitioner expiry: 'drop' (destroy) | 'detach' (preserve)
    enabled                boolean NOT NULL DEFAULT true,
    PRIMARY KEY (schema_name, table_name),
    CONSTRAINT pc_period_enum   CHECK (partition_period IN ('monthly','daily')),
    CONSTRAINT pc_partmode_enum CHECK (part_mode IN ('timestamp','id')),
    CONSTRAINT pc_id_scheme     CHECK ((part_mode = 'id') = (id_scheme IS NOT NULL)),
    CONSTRAINT pc_scheme_enum   CHECK (id_scheme IS NULL OR id_scheme IN ('uuidv7','snowflake')),
    CONSTRAINT pc_future_pos    CHECK (future_partitions >= 1),
    CONSTRAINT pc_destroy       CHECK (hot_period IS NOT NULL OR retention_period IS NOT NULL),
    CONSTRAINT pc_cold_timeonly CHECK (hot_period IS NULL OR part_mode = 'timestamp'),
    CONSTRAINT pc_2level_col    CHECK (sub_part_values_source IS NULL OR partition_column IS NOT NULL),
    CONSTRAINT pc_strategy_enum CHECK (expiration_strategy IN ('drop','detach')),
    CONSTRAINT pc_strategy_part CHECK (expiration_strategy = 'drop' OR hot_period IS NULL)  -- 'detach' is partition-only
);

-- Routing state for a vector column. Name-keyed like partition_config, so a mesh
-- replicates it by value and every node assigns identical cluster ids.
--
-- A generation is immutable: a retrain writes a new one and moves the pointer, so
-- an assignment already stored keeps meaning what it meant. Centroids are real[],
-- not pgvector values: these tables are created with the extension, which must
-- install on a database that has no vectors and may never have any. Scoring a query
-- against them goes through the same `<=>` shim a caller uses, which delegates to
-- pgvector, and by then a vector column exists.
CREATE TABLE IF NOT EXISTS coldfront.vector_config (
    schema_name  text    NOT NULL DEFAULT 'public',
    table_name   text    NOT NULL,
    column_name  text    NOT NULL,
    nlist        int     NOT NULL,
    nprobe       int     NOT NULL,
    generation   int     NOT NULL DEFAULT 0,   -- 0 ⇒ nothing trained yet
    addition_cap int     NOT NULL DEFAULT 0,   -- post-generation centroids allowed
    PRIMARY KEY (schema_name, table_name, column_name),
    CONSTRAINT vc_nlist_pos  CHECK (nlist  >= 1),
    CONSTRAINT vc_nprobe_pos CHECK (nprobe >= 1),
    CONSTRAINT vc_nprobe_fit CHECK (nprobe <= nlist)
);

CREATE TABLE IF NOT EXISTS coldfront.vector_centroids (
    schema_name text   NOT NULL DEFAULT 'public',
    table_name  text   NOT NULL,
    column_name text   NOT NULL,
    generation  int    NOT NULL,
    centroid_id int    NOT NULL,
    parent_id   int,                            -- set on an adaptive addition
    centroid    real[] NOT NULL,
    PRIMARY KEY (schema_name, table_name, column_name, generation, centroid_id),
    CONSTRAINT vcent_gen_pos CHECK (generation >= 1)
);

-- Carry the durable tiering metadata across pg_dump/restore so a restored node
-- re-attaches to the same Iceberg cold tier with no re-provisioning. These are
-- extension-member tables, whose data pg_dump would otherwise omit;
-- pg_extension_config_dump marks their contents to be dumped. Deliberately NOT
-- carried: coldfront.storage_secret (a credential — re-establish after restore
-- with coldfront.set_storage_secret) and the bakery's claims / claim_acks /
-- deferred_acks (transient, per-node mesh state).
SELECT pg_extension_config_dump('coldfront.tiered_views', '');
SELECT pg_extension_config_dump('coldfront.archive_watermark', '');
SELECT pg_extension_config_dump('coldfront.partition_config', '');
-- Losing these means every stored cluster id is uninterpretable and the table has
-- to be retrained from scratch, so they travel with a dump like the rest.
SELECT pg_extension_config_dump('coldfront.vector_config', '');
SELECT pg_extension_config_dump('coldfront.vector_centroids', '');

-- ============================================================================
-- ONE-TIME MESH SETUP
-- ============================================================================
-- coldfront.ensure_replicated(): run once on every node of a Spock mesh, after
-- spock.node_create and the node's spock.sub_create calls and before the first
-- cold write, storage secret or table registration. It puts every ColdFront
-- table that replicates by value in the node's default replication set.
-- Membership is a property of the provider, so each node adds the tables for
-- the rows it will send; a peer's subscription then receives them. Nothing
-- calls it at run time: a node that skipped it keeps its claim acks, registry
-- rows, secret and lifecycle config to itself.
--
-- The tables, all keyed by name so a row is identical on every node:
--   claims, claim_acks               the bakery's tickets and acknowledgements
--   tiered_views                     the registry the hook resolves a view by
--   archive_watermark                the hot/cold cutoff a tiered write routes by
--   storage_secret                   the cold-store credential
--   partition_config                 per-table lifecycle (the archiver and the
--                                    partitioner add it themselves as well, since
--                                    the partitioner runs without the extension)
--   vector_config, vector_centroids  cluster routing state
-- Two tables stay local by design and are not added: deferred_acks (each
-- node's own queue of acks it owes) and _dummy_dml_target (each node's
-- CREATE EXTENSION seeds its row).
--
-- Idempotent, and a no-op without the spock extension. spock.repset_add_table
-- needs the local Spock node, which is why this cannot run at CREATE EXTENSION
-- time. No EXCEPTION block: pg_duckdb rejects every subtransaction.
CREATE FUNCTION coldfront.ensure_replicated() RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
    t text;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'spock') THEN
        RETURN;
    END IF;
    FOREACH t IN ARRAY ARRAY['coldfront.claims', 'coldfront.claim_acks',
                             'coldfront.tiered_views', 'coldfront.archive_watermark',
                             'coldfront.storage_secret', 'coldfront.partition_config',
                             'coldfront.vector_config', 'coldfront.vector_centroids'] LOOP
        PERFORM spock.repset_add_table('default', t::regclass, false)
        WHERE NOT EXISTS (
            SELECT 1 FROM spock.replication_set rs
              JOIN spock.replication_set_table rst ON rst.set_id = rs.set_id
             WHERE rs.set_name = 'default' AND rst.set_reloid = t::regclass
        );
    END LOOP;
END;
$$;

-- ensure_attached() issues ATTACH IF NOT EXISTS for the Lakekeeper catalog
-- using the coldfront.warehouse and coldfront.lakekeeper_endpoint GUCs. Called
-- lazily by the extension hook (coldfront.c) on the first query in a session
-- that touches a registered tiered view — read OR write — so the catalog 'ice'
-- resolves on PG 16/17/18 (a version-agnostic lazy attach). The S3
-- credential it needs at commit time comes from the persistent secret
-- (coldfront.set_storage_secret), not from this ATTACH. Safe to call repeatedly
-- — ATTACH IF NOT EXISTS is idempotent.
CREATE OR REPLACE FUNCTION coldfront.ensure_attached() RETURNS void AS $$
DECLARE
  wh   text := current_setting('coldfront.warehouse', true);
  ep   text := current_setting('coldfront.lakekeeper_endpoint', true);
  mode text := coldfront._attach_delegation_mode();
BEGIN
  IF wh IS NOT NULL AND wh <> '' AND ep IS NOT NULL AND ep <> '' THEN
    -- iceberg (and avro transitively) are auto-installed/auto-loaded by
    -- pg_duckdb when this ATTACH (TYPE ICEBERG, ...) fires, gated by
    -- duckdb.autoinstall_known_extensions / autoload_known_extensions. No
    -- explicit install or per-session LOAD needed. ACCESS_DELEGATION_MODE is
    -- VENDED_CREDENTIALS for a vended cold store (Lakekeeper issues per-table
    -- creds), else NONE (the persistent secret supplies them).
    PERFORM duckdb.raw_query(format(
      'ATTACH IF NOT EXISTS %L AS ice (TYPE ICEBERG, ENDPOINT %L, '
      'AUTHORIZATION_TYPE NONE, ACCESS_DELEGATION_MODE %s)',
      wh, ep, mode
    ));
    -- Pin DuckDB's BUNDLED httpfs client (cpp-httplib + mbedtls), not the system
    -- libcurl DuckDB 1.5 defaults to. The libcurl client's threaded resolver calls
    -- glibc getaddrinfo, whose IPv6 check_pf() netlink probe is fragile under a
    -- copy-on-write Iceberg DELETE's concurrent S3 connections resolving an
    -- object-store HOSTNAME (AWS S3, GCS); bare-IP stores (SeaweedFS) skip
    -- getaddrinfo, which is why CI never hit it. curl 8.11.1 made this a hard crash
    -- via CVE-2025-0665 (resolver double-closed an fd → glibc SIGABRT); the base now
    -- builds curl 8.12.0 (CVE-fixed), but we still pin httplib: it resolves in-thread
    -- (no resolver-thread churn), keeps DuckDB fully parallel, and is what stock
    -- pg_duckdb 1.1.1 used. This SET is the SINGLE home of the httplib pin —
    -- cmd/archiver calls ensure_attached() to reuse it.
    -- Background: https://curl.se/docs/CVE-2025-0665.html
    -- Run AFTER the ATTACH (httpfs loaded); GLOBAL = this backend's instance; idempotent.
    PERFORM duckdb.raw_query($q$SET GLOBAL httpfs_client_implementation = 'httplib'$q$);
    -- Skip the metadata-log time-travel read at table load. When a table's
    -- metadata is newer than the transaction start (guaranteed for every
    -- bakery-serialized writer that waited on a peer's commit), duckdb-iceberg
    -- reconstructs as-of-start metadata by fetching a previous metadata.json
    -- from object storage. That fetch happens BEFORE the table's credentials
    -- exist in the session, so under vended credentials it fails (403); with
    -- false, the fallback rewinds the snapshot pointer in the already-loaded
    -- metadata with no storage read. Also saves one GET per conflicting
    -- statement under static credentials. GLOBAL = this backend's instance.
    PERFORM duckdb.raw_query($q$SET GLOBAL iceberg_use_metadata_log = false$q$);
    -- httpfs (s3) already loaded as a side-effect of the ATTACH above; azure does
    -- not, so its lazy autoload would otherwise fire later as the non-superuser
    -- app role and hit pg_duckdb's LocalFileSystem block. Pre-load it
    -- here, while still in this SECURITY DEFINER (elevated) context.
    IF EXISTS (SELECT 1 FROM coldfront.storage_secret WHERE storage_type = 'azure') THEN
      PERFORM duckdb.raw_query('LOAD azure');
    END IF;
  END IF;
END;
-- SECURITY DEFINER: this must run elevated. pg_duckdb force-disables DuckDB's
-- LocalFileSystem for non-superusers, which blocks the side-loaded iceberg
-- extension's load-on-ATTACH. Running as the (superuser) extension owner loads
-- iceberg + ATTACHes 'ice' while the FS is enabled; the per-backend DuckDB
-- instance keeps it loaded, so the outer scan/commit then runs as the
-- (non-superuser) app role over S3/httpfs — no server-file roles needed. Inputs
-- are operator-trusted: warehouse/lakekeeper_endpoint are PGC_SUSET (a
-- non-superuser cannot redirect this ATTACH). search_path pinned per SECURITY
-- DEFINER hardening; the body references only pg_catalog + schema-qualified duckdb.
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog;

-- ensure_pg_attached() loads DuckDB's `postgres` extension and ATTACHes the
-- *local* PG instance as `pglocal`, so DuckDB-side SQL inside `raw_query` can
-- read PG tables directly (e.g. `SELECT … FROM pglocal.<schema>.<table>`).
-- This is the path coldfront uses to stream PG-source rows into Iceberg
-- without intermediate local materialisation: one raw_query of the form
-- `INSERT INTO ice.… SELECT … FROM pglocal.<src>` pipelines source → DuckDB
-- → Iceberg writer → S3 in one pass.
--
-- DSN comes from the `coldfront.local_pg_dsn` GUC, set by the operator in
-- postgresql.conf or via `-c coldfront.local_pg_dsn=…` (same pattern as
-- coldfront.warehouse / .lakekeeper_endpoint). Empty/unset → no-op; the
-- helper runs but pglocal is just not made available, and any caller that
-- needs it will fail with a clear "Catalog 'pglocal' does not exist" rather
-- than silently doing the wrong thing.
--
-- Every use is a read: the PG tables that feed an Iceberg write, and the centroid
-- lookup a cold write on a clustered table carries. The ATTACH is a plain one, so
-- that is a property of what coldfront emits rather than one it enforces.
CREATE OR REPLACE FUNCTION coldfront.ensure_pg_attached() RETURNS void AS $$
DECLARE
  dsn text := current_setting('coldfront.local_pg_dsn', true);
BEGIN
  IF dsn IS NOT NULL AND dsn <> '' THEN
    -- LOAD + ATTACH only. duckdb.install_extension('postgres') is run once at
    -- setup by coldfront.set_storage_secret(); doing the install on this hot
    -- path would do network I/O per session, and pg_duckdb's GetConnection
    -- refuses to run inside a subtransaction.
    PERFORM duckdb.raw_query('LOAD postgres');
    PERFORM duckdb.raw_query(format(
      'ATTACH IF NOT EXISTS %L AS pglocal (TYPE postgres)',
      dsn
    ));
  END IF;
END;
-- SECURITY DEFINER for the same reason as ensure_attached(): LOAD postgres reads
-- the locally-installed extension file, which the non-superuser LocalFileSystem
-- block forbids. Elevated load + ATTACH lets a non-superuser's streaming
-- INSERT…SELECT (pglocal) write path work without server-file roles. local_pg_dsn
-- is PGC_SUSET + GUC_SUPERUSER_ONLY, so the DSN cannot be set or read by a
-- non-superuser. search_path pinned per SECURITY DEFINER hardening.
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog;

-- coldfront._hot_only: the per-row guard a hot MERGE's INSERT action gets on its
-- partition-column value. The hot MERGE runs in PostgreSQL against the hot table
-- alone, so a row below the cutoff, which belongs in Iceberg, is refused rather
-- than written to the wrong tier; any other value comes back unchanged. STABLE,
-- so the planner does not fold a constant value and EXPLAIN shows the guard.
CREATE OR REPLACE FUNCTION coldfront._hot_only(
    p_value timestamptz, p_cutoff timestamptz, p_view text, p_col text
) RETURNS timestamptz LANGUAGE plpgsql STABLE STRICT AS $$
BEGIN
  IF p_value < p_cutoff THEN
    RAISE EXCEPTION 'a MERGE into the hot tier of tiered view "%" cannot insert a row with "%" = %, which is below the cutoff',
      p_view, p_col, p_value
      USING ERRCODE = 'feature_not_supported',
            HINT = 'Insert the row with INSERT, which splits rows by the cutoff.';
  END IF;
  RETURN p_value;
END;
$$;

-- grant_app_access(target_role) — ONE-CALL onboarding for a NON-superuser app
-- role. Grants exactly the minimal privileges the transparent cold path needs
-- and nothing more: duckdb.postgres_role membership (DuckDB execution), USAGE on
-- coldfront + every schema holding a registered view, SELECT on the registry,
-- DML on the dual-write anchor + every registered tiered/decoupled view, and
-- EXECUTE on the runtime cold-path functions. No server-file roles, no
-- superuser, no admin/DDL functions (set_storage_secret, create_iceberg_table,
-- the *_tiered_view DDL helpers, grant_app_access itself) — those stay
-- operator-only. Idempotent; re-run after registering new tables to extend
-- coverage. Schema/view/sequence lists are DERIVED from the registry (never
-- hardcoded); the function-EXECUTE list is an explicit allow-list mirroring the
-- runtime callsites in coldfront.c (ensure_attached/ensure_pg_attached via SPI,
-- _exec_iceberg_with_claim/_cold_sink emitted into rewrites,
-- _enqueue_release + the R-A bakery _claim_iceberg_lock on the cold-write
-- path). Allow-list = fail safe: a missing entry breaks the app path loudly
-- (the journey's story_app_privilege + ci/ops.sh check 3 are the tripwires), it
-- never silently over-grants.
--
-- Spock mesh: CREATE ROLE and these GRANTs replicate via Spock DDL, so create the
-- app role + run this ONCE on any one node — both propagate to the whole mesh.
-- Do NOT repeat per-node (a repeated CREATE ROLE is a harmless local error).
--
-- SECURITY INVOKER + EXECUTE revoked from PUBLIC: only an operator/superuser may
-- run it, so an app role can never self-grant (that would be an escalation).
CREATE OR REPLACE FUNCTION coldfront.grant_app_access(target_role regrole)
RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
  duckrole text := current_setting('duckdb.postgres_role', true);
  tgt      text := target_role::text;     -- regrole::text is an already-quoted identifier
  r        record;
BEGIN
  IF duckrole IS NULL OR duckrole = '' THEN
    RAISE EXCEPTION 'duckdb.postgres_role is unset; set it in postgresql.conf and re-run (without it only superusers can run DuckDB, so no non-superuser cold path exists)';
  END IF;

  -- DuckDB execution: pg_duckdb gates on membership of duckdb.postgres_role.
  EXECUTE format('GRANT %I TO %s', duckrole, tgt);

  -- _cross_tier_move reads Iceberg through DuckDB inside a function, which
  -- pg_duckdb allows only under this parameter, and pg_duckdb defines it
  -- superuser-only. The app role runs that move under its own privileges, so it
  -- needs to set the parameter itself. Narrower than it looks: the deployment
  -- config GUCs stay superuser-only, so this cannot redirect the elevated ATTACH.
  EXECUTE format(
    'GRANT SET ON PARAMETER duckdb.unsafe_allow_execution_inside_functions TO %s', tgt);

  -- coldfront schema + registry read + the dual-write anchor table.
  EXECUTE format('GRANT USAGE ON SCHEMA coldfront TO %s', tgt);
  EXECUTE format('GRANT SELECT ON coldfront.tiered_views, coldfront.archive_watermark TO %s', tgt);
  EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON coldfront._dummy_dml_target TO %s', tgt);

  -- EXECUTE on the runtime cold-path functions only (allow-list mirrors coldfront.c).
  FOR r IN
    SELECT p.oid::regprocedure AS sig
    FROM pg_proc p
    WHERE p.pronamespace = 'coldfront'::regnamespace
      AND p.proname IN ('ensure_attached', 'ensure_pg_attached',
                        '_exec_iceberg_with_claim',
                        -- the tiered INSERT's cold sink and its row renderer
                        '_cold_sink', '_cold_sink_step', '_cold_sink_flush',
                        '_cold_sink_final', '_cold_row_literal',
                        -- an array column's shape check in that INSERT, and an
                        -- array parameter's renderer in a cold write
                        '_cold_list', '_render_cold_param',
                        -- the hot MERGE's per-row cutoff guard on INSERT actions
                        '_hot_only',
                        -- cross-tier move: the hook rewrites a partition-column
                        -- UPDATE to SELECT _cross_tier_move(...), which serialises
                        -- cold rows via _move_row_literal.
                        '_cross_tier_move', '_move_row_literal', '_move_pg_row_literal',
                        '_enqueue_release',
                        -- cold-write preconditions + serializer gate wrappers (the
                        -- standby refusal, the armed-predicate, the claim-or-advisory
                        -- acquire); app-role cold paths call these SECURITY INVOKER
                        -- wrappers, which delegate to the DEFINER primitives below.
                        '_reject_on_standby', '_bakery_armed', '_take_iceberg_claim',
                        -- R-A bakery coordination (mesh cold writes); SECURITY
                        -- DEFINER, so the app role just needs EXECUTE — the
                        -- spock/loopback/pg_stat_replication access happens as owner.
                        '_claim_iceberg_lock')
  LOOP
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO %s', r.sig::text, tgt);
  END LOOP;

  -- USAGE on each schema holding a registered view + DML on the views themselves,
  -- AND on the hot heap behind a tiered view. pg_duckdb's custom scan checks the
  -- INVOKER's privilege on the underlying hot table (not the view owner's), so a
  -- tiered read/write touching the hot tier needs DML on hot_table too — granting
  -- the view alone yields "permission denied for table <hot_table>". Iceberg-only
  -- (decoupled) rows have no hot heap (hot_table NULL), so they are skipped.
  -- hot_table is a ready-to-use (possibly schema-qualified, possibly quoted)
  -- relation reference, so it is substituted with %s, not %I.
  FOR r IN SELECT DISTINCT schema_name FROM coldfront.tiered_views LOOP
    EXECUTE format('GRANT USAGE ON SCHEMA %I TO %s', r.schema_name, tgt);
  END LOOP;
  FOR r IN SELECT schema_name, relname, hot_table, is_iceberg_only FROM coldfront.tiered_views LOOP
    EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON %I.%I TO %s',
                   r.schema_name, r.relname, tgt);
    IF NOT r.is_iceberg_only AND r.hot_table IS NOT NULL AND r.hot_table <> '' THEN
      EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON %s TO %s', r.hot_table, tgt);
    END IF;
  END LOOP;

  -- USAGE on the IDENTITY/serial sequences behind tiered hot tables: the cold
  -- INSERT rewrite calls nextval() on it AS THE INVOKER for each cold row, so
  -- the app role needs USAGE on it. Derived from
  -- pg_depend (sequences owned-by 'a'/'i' of each registered hot table) — not
  -- hardcoded; to_regclass tolerates NULL/iceberg-only hot_table (-> no row).
  FOR r IN
    SELECT DISTINCT d.objid::regclass AS seq
    FROM coldfront.tiered_views tv
    JOIN pg_depend d ON d.refobjid = to_regclass(tv.hot_table) AND d.deptype IN ('a','i')
    JOIN pg_class s ON s.oid = d.objid AND s.relkind = 'S'
    WHERE NOT tv.is_iceberg_only
  LOOP
    EXECUTE format('GRANT USAGE, SELECT ON SEQUENCE %s TO %s', r.seq, tgt);
  END LOOP;
END;
$$;
REVOKE EXECUTE ON FUNCTION coldfront.grant_app_access(regrole) FROM PUBLIC;

-- _build_storage_secret_opts() — PURE: returns the body of the DuckDB
-- CREATE PERSISTENT SECRET for the given row, branched on storage_type. It
-- touches no tables and issues no DuckDB calls, so it is unit-testable in
-- pg_regress (white-box, like the cold-DML rewrite helpers). Both branches
-- feed the same emission path in materialize_storage_secret().
CREATE OR REPLACE FUNCTION coldfront._build_storage_secret_opts(r coldfront.storage_secret)
RETURNS text
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE opts text;
BEGIN
  -- Vended rows carry no credentials: Lakekeeper issues per-table creds and
  -- duckdb-iceberg creates the DuckDB secret from them, so there is nothing to
  -- materialize here.
  IF r.vended THEN
    RETURN NULL;
  END IF;
  IF r.storage_type = 'azure' THEN
    -- CONFIG provider (PROVIDER omitted ⇒ config). Shared-key auth: the access
    -- key rides inside CONNECTION_STRING's AccountKey=… — duckdb-azure has no
    -- separate ACCOUNT_KEY param. The same secret serves abfss:// (ADLS Gen2)
    -- reads and writes.
    RETURN format('TYPE azure, CONNECTION_STRING %L', r.connection_string);
  END IF;
  -- s3 (default)
  opts := format('TYPE s3, KEY_ID %L, SECRET %L, REGION %L', r.key_id, r.secret, r.region);
  -- A set endpoint ⇒ S3-compatible store (SeaweedFS/MinIO): path-style + the
  -- custom endpoint. No endpoint ⇒ AWS default (virtual-hosted).
  IF r.endpoint IS NOT NULL AND r.endpoint <> '' THEN
    opts := opts || format(', ENDPOINT %L, URL_STYLE %L, USE_SSL %s',
                           r.endpoint, r.url_style,
                           CASE WHEN r.use_ssl THEN 'true' ELSE 'false' END);
  END IF;
  RETURN opts;
END;
$$;

-- materialize_storage_secret() writes the DuckDB PERSISTENT SECRET on THIS node
-- from the stored row. DuckDB persists it to its secret directory and loads it
-- at instance init, so every subsequent backend sees the credential committed
-- before any query — the property that lets a cold-write commit resolve it on
-- PG 16/17/18. Idempotent (CREATE OR REPLACE); no-op when no row is set. NO
-- EXCEPTION clause — pg_duckdb forbids running ATTACH / secret DDL inside a
-- subtransaction, and a plpgsql EXCEPTION block is one.
CREATE OR REPLACE FUNCTION coldfront.materialize_storage_secret() RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
  r    coldfront.storage_secret;
  opts text;
BEGIN
  SELECT * INTO r FROM coldfront.storage_secret LIMIT 1;
  IF NOT FOUND THEN RETURN; END IF;
  opts := coldfront._build_storage_secret_opts(r);
  -- Vended row ⇒ no secret body; drop any secret a prior static row left behind
  -- so a static→vended switch cannot keep serving the old credential.
  IF opts IS NULL THEN
    PERFORM duckdb.raw_query(format('DROP PERSISTENT SECRET IF EXISTS %I', r.name));
    RETURN;
  END IF;
  PERFORM duckdb.raw_query(format('CREATE OR REPLACE PERSISTENT SECRET %I (%s)',
                                  r.name, opts));
END;
$$;

-- Re-materialize on every node when the row changes — including during Spock
-- apply (which runs with session_replication_role = replica), hence
-- ENABLE ALWAYS; FOR EACH ROW so it fires on the replicated row change. This is
-- how a single set_storage_secret() call propagates to all mesh nodes: the row
-- replicates by value and each node materializes its own persistent secret.
CREATE FUNCTION coldfront._storage_secret_materialize_trg() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  PERFORM coldfront.materialize_storage_secret();
  RETURN NULL;
END;
$$;
CREATE TRIGGER coldfront_storage_secret_materialize
  AFTER INSERT OR UPDATE ON coldfront.storage_secret
  FOR EACH ROW EXECUTE FUNCTION coldfront._storage_secret_materialize_trg();
ALTER TABLE coldfront.storage_secret ENABLE ALWAYS TRIGGER coldfront_storage_secret_materialize;

-- _apply_storage_secret() — backend-NEUTRAL persist. Upserts the single
-- cf_storage row (the materialize trigger then emits the matching DuckDB
-- PERSISTENT SECRET, and the row replicates by value to mesh peers) and installs
-- DuckDB's `postgres` extension when the pglocal write path is configured
-- (coldfront.local_pg_dsn — install does I/O, hoisted out of the per-query hook).
-- This function knows NOTHING about s3 vs azure: it writes whatever row it is
-- given. The two typed setters below are the only backend-aware code — they
-- shape the row; this applies it. NO EXCEPTION clause (pg_duckdb forbids secret
-- DDL inside a subtransaction, and a plpgsql EXCEPTION block is one).
CREATE OR REPLACE FUNCTION coldfront._apply_storage_secret(p coldfront.storage_secret)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  dsn text := current_setting('coldfront.local_pg_dsn', true);
BEGIN
  INSERT INTO coldfront.storage_secret
       (name, storage_type, key_id, secret, endpoint, region, url_style, use_ssl, connection_string, vended)
       VALUES (p.name, p.storage_type, p.key_id, p.secret, p.endpoint,
               p.region, p.url_style, p.use_ssl, p.connection_string, p.vended)
  ON CONFLICT (name) DO UPDATE SET
       storage_type      = EXCLUDED.storage_type,
       key_id            = EXCLUDED.key_id,
       secret            = EXCLUDED.secret,
       endpoint          = EXCLUDED.endpoint,
       region            = EXCLUDED.region,
       url_style         = EXCLUDED.url_style,
       use_ssl           = EXCLUDED.use_ssl,
       connection_string = EXCLUDED.connection_string,
       vended            = EXCLUDED.vended;
  IF dsn IS NOT NULL AND dsn <> '' THEN
    PERFORM duckdb.install_extension('postgres');
  END IF;
END;
$$;

-- set_storage_secret() — the one-call cold-tier setup that replaces the old
-- duckdb.create_simple_secret setup. It writes the in-DB row (which
-- fires the materialize trigger → DuckDB PERSISTENT SECRET on this node, and
-- replicates the row to mesh peers) and pre-installs DuckDB's `postgres`
-- extension for the pglocal write path when coldfront.local_pg_dsn is set
-- (install does I/O, hoisted here once, out of the per-query hook). Requires no
-- superuser / ALTER SYSTEM.
CREATE OR REPLACE FUNCTION coldfront.set_storage_secret(
    p_key_id    text,
    p_secret    text,
    p_endpoint  text    DEFAULT NULL,
    p_region    text    DEFAULT 'us-east-1',
    p_url_style text    DEFAULT 'path',
    p_use_ssl   boolean DEFAULT false) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  -- Shape an s3 row; _apply_storage_secret does the (backend-neutral) persist.
  PERFORM coldfront._apply_storage_secret(ROW(
    'cf_storage', 's3', p_key_id, p_secret, p_endpoint,
    p_region, p_url_style, p_use_ssl, NULL, false
  )::coldfront.storage_secret);
END;
$$;

-- set_storage_secret_azure() — cold-tier setup for Azure ADLS Gen2 over the
-- DuckDB azure extension's CONFIG provider. p_connection_string carries
-- AccountName/AccountKey (shared key) + EndpointSuffix; this is the only
-- duckdb-azure path for access-key auth (it has no ACCOUNT_KEY param). Same
-- emission/replication path as the s3 setter: it writes the row → the
-- materialize trigger emits the PERSISTENT secret on every node. NO EXCEPTION
-- clause (pg_duckdb forbids secret DDL in a subtransaction). Requires the
-- DuckDB 1.5.x + azure extension stack to actually materialize (the azure
-- secret type must be registered); on an azure-less build the trigger's
-- raw_query raises, by design.
CREATE OR REPLACE FUNCTION coldfront.set_storage_secret_azure(
    p_connection_string text) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  -- Shape an azure row (region/url_style/use_ssl are s3-only — set to the column
  -- defaults to satisfy NOT NULL; the opts builder ignores them for azure).
  -- _apply_storage_secret does the (backend-neutral) persist.
  PERFORM coldfront._apply_storage_secret(ROW(
    'cf_storage', 'azure', NULL, NULL, NULL,
    'us-east-1', 'path', false, p_connection_string, false
  )::coldfront.storage_secret);
END;
$$;

-- set_storage_secret_vended(): cold-tier setup for compliance deployments that
-- must not store object-store credentials. It writes a credential-less row
-- (vended = true) so nothing is materialized as a DuckDB secret; instead
-- ensure_attached() turns on Iceberg REST credential vending and Lakekeeper
-- issues short-lived per-table credentials at read/write time. The Lakekeeper
-- warehouse keeps its own long-term credential (the client plane holds none).
-- p_storage_type selects s3 (default; AWS + S3-compatible) or azure (so
-- ensure_attached still LOADs the azure extension for the vended SAS). Same
-- emission/replication path as the static setters.
CREATE OR REPLACE FUNCTION coldfront.set_storage_secret_vended(
    p_storage_type text DEFAULT 's3') RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  IF p_storage_type NOT IN ('s3', 'azure') THEN
    RAISE EXCEPTION 'storage_type must be ''s3'' or ''azure'', got: %', p_storage_type;
  END IF;
  PERFORM coldfront._apply_storage_secret(ROW(
    'cf_storage', p_storage_type, NULL, NULL, NULL,
    'us-east-1', 'path', false, NULL, true
  )::coldfront.storage_secret);
END;
$$;

-- _attach_delegation_mode(): the DuckDB ICEBERG ATTACH access-delegation mode
-- for this node. VENDED_CREDENTIALS when the stored row is vended (Lakekeeper
-- issues per-table creds), else NONE (the persistent secret supplies them).
-- Absent row ⇒ NONE (no cold store configured yet).
CREATE OR REPLACE FUNCTION coldfront._attach_delegation_mode() RETURNS text
LANGUAGE sql STABLE AS $$
  SELECT CASE
           WHEN COALESCE((SELECT vended FROM coldfront.storage_secret LIMIT 1), false)
             THEN 'VENDED_CREDENTIALS'
           ELSE 'NONE'
         END;
$$;

-- ============================================================================
-- Archive capture pipeline.
--
-- During an archive cycle, the archiver does:
--   0. (idempotent prep — wipe any partial Iceberg state in the partition's
--      timestamp range from a previous crashed attempt)
--   1. SELECT coldfront.install_archive_capture(schema, partition)
--      → installs an UNLOGGED delta table + AFTER-row trigger on the partition
--   2. (bulk export PG → Iceberg under a captured REPEATABLE READ snapshot)
--   3. CALL coldfront.replay_archive_delta(schema, partition, snapshot, ice_ref)
--      → drains delta rows whose xid is NOT visible in the bulk-copy snapshot,
--        applying DELETE-then-INSERT to Iceberg, with batched COMMIT
--   4. CALL coldfront.cutover_archive(...)
--      → atomic: lock_timeout=100ms circuit-breaker, final inline drain,
--        watermark advance, view recreate, DETACH+DROP partition+delta+triggers
--
-- The trigger uses last-write-wins per source PK: one delta row per PK
-- regardless of how many writes accumulate. Replay applies DELETE+INSERT
-- (idempotent) so retries and snapshot-overlap are correctness-safe.
--
-- Hard requirement: source partition must have a primary key. Without one
-- there is no way to identify rows for UPDATE/DELETE replay against Iceberg.
-- ============================================================================

-- Install per-partition capture. Idempotent: drops any prior leftovers from
-- a crashed cycle before creating fresh.
CREATE OR REPLACE FUNCTION coldfront.install_archive_capture(
    p_schema text, p_part text
) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
    delta_tbl     text := format('coldfront.%I',
                                 'delta_' || p_schema || '_' || p_part);
    capture_fn    text := format('coldfront.%I',
                                 'delta_capture_' || p_schema || '_' || p_part);
    truncate_fn   text := format('coldfront.%I',
                                 'delta_block_truncate_' || p_schema || '_' || p_part);
    pk_cols       text;
    pk_count      int;
    all_cols      text;     -- 'col1, col2, ...'
    new_field_refs text;    -- 'r.col1, r.col2, ...'
    excluded_set  text;     -- 'col1=EXCLUDED.col1, col2=EXCLUDED.col2, ...'
BEGIN
    -- Resolve PK columns (ordered by position in indkey).
    SELECT string_agg(quote_ident(a.attname), ', ' ORDER BY x.ord),
           count(*)
    INTO pk_cols, pk_count
    FROM pg_index i
    JOIN pg_class c ON c.oid = i.indrelid
    JOIN pg_namespace n ON n.oid = c.relnamespace
    JOIN unnest(i.indkey) WITH ORDINALITY AS x(attnum, ord) ON true
    JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = x.attnum
    WHERE n.nspname = p_schema AND c.relname = p_part AND i.indisprimary;

    IF pk_count IS NULL OR pk_count = 0 THEN
        RAISE EXCEPTION 'coldfront: cannot install archive capture on %.%: no primary key',
            p_schema, p_part;
    END IF;

    -- Resolve all live columns of the partition.
    SELECT
        string_agg(quote_ident(a.attname),                       ', ' ORDER BY a.attnum),
        string_agg('r.' || quote_ident(a.attname),               ', ' ORDER BY a.attnum),
        string_agg(format('%I = EXCLUDED.%I', a.attname, a.attname), ', ' ORDER BY a.attnum)
    INTO all_cols, new_field_refs, excluded_set
    FROM pg_attribute a
    JOIN pg_class c ON c.oid = a.attrelid
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = p_schema AND c.relname = p_part
      AND a.attnum > 0 AND NOT a.attisdropped
      AND NOT coldfront._is_vec_companion(a.attname, a.attgenerated);

    -- Idempotent reset. CASCADE on DROP FUNCTION removes the AFTER-row /
    -- BEFORE-TRUNCATE triggers on the partition that reference these
    -- functions — without CASCADE, a prior failed cycle's leftover trigger
    -- pins the function and DROP errors with "other objects depend on it".
    EXECUTE format('DROP TABLE IF EXISTS %s CASCADE',        delta_tbl);
    EXECUTE format('DROP FUNCTION IF EXISTS %s() CASCADE',   capture_fn);
    EXECUTE format('DROP FUNCTION IF EXISTS %s() CASCADE',   truncate_fn);

    -- Delta table: same column shape as the partition + bookkeeping. UNLOGGED
    -- because it's discarded at cutover; durability is moot, WAL bandwidth saved.
    EXECUTE format($q$
        CREATE UNLOGGED TABLE %s (
            LIKE %I.%I INCLUDING DEFAULTS,
            coldfront_is_deleted boolean NOT NULL DEFAULT false,
            coldfront_xid        xid8    NOT NULL DEFAULT pg_current_xact_id(),
            PRIMARY KEY (%s)
        )
    $q$, delta_tbl, p_schema, p_part, pk_cols);

    -- Capture trigger function. Last-write-wins per source PK: one delta row
    -- per PK no matter how many writes accumulate.
    EXECUTE format($q$
        CREATE FUNCTION %s() RETURNS trigger LANGUAGE plpgsql AS $fn$
        DECLARE r record;
        BEGIN
            IF TG_OP = 'DELETE' THEN r := OLD; ELSE r := NEW; END IF;
            INSERT INTO %s (%s, coldfront_is_deleted, coldfront_xid)
            VALUES (%s, (TG_OP = 'DELETE'), pg_current_xact_id())
            ON CONFLICT (%s) DO UPDATE SET
                %s,
                coldfront_is_deleted = EXCLUDED.coldfront_is_deleted,
                coldfront_xid        = EXCLUDED.coldfront_xid;
            RETURN COALESCE(NEW, OLD);
        END $fn$
    $q$, capture_fn, delta_tbl, all_cols, new_field_refs, pk_cols, excluded_set);

    EXECUTE format($q$
        CREATE TRIGGER coldfront_delta_capture
        AFTER INSERT OR UPDATE OR DELETE ON %I.%I
        FOR EACH ROW EXECUTE FUNCTION %s()
    $q$, p_schema, p_part, capture_fn);

    -- TRUNCATE-blocker: per-row triggers don't fire on TRUNCATE, so a
    -- TRUNCATE during the archive window would silently bypass capture.
    -- This statement-level BEFORE trigger raises so the operator notices.
    EXECUTE format($q$
        CREATE FUNCTION %s() RETURNS trigger LANGUAGE plpgsql AS $fn$
        BEGIN
            RAISE EXCEPTION 'coldfront: TRUNCATE on %% blocked: archive in progress',
                TG_TABLE_NAME;
        END $fn$
    $q$, truncate_fn);

    EXECUTE format($q$
        CREATE TRIGGER coldfront_delta_block_truncate
        BEFORE TRUNCATE ON %I.%I
        EXECUTE FUNCTION %s()
    $q$, p_schema, p_part, truncate_fn);
END;
$$;

-- ============================================================================
-- The cold sink: the cold half of a tiered-view INSERT.
--
-- The C hook rewrites INSERT INTO <tiered view> ... into one statement that
-- holds the source in a MATERIALIZED CTE, inserts the hot rows into the hot
-- table from it, and aggregates the cold rows from it with _cold_sink. Each
-- row reaches the sink as jsonb with one key per hot-table column, projected
-- in the statement: the user's value, nextval() for an omitted identity
-- column, the DEFAULT expression for an omitted column that has one, NULL
-- otherwise. The sink renders and batches and does nothing else: the step
-- function renders each row as a DuckDB VALUES tuple and flushes every
-- coldfront.cold_write_batch_size rows as one INSERT under the table's claim,
-- and the final function flushes the rest and returns the row count. The
-- claim is taken once per table per transaction (_take_iceberg_claim), the
-- same sequence as every other cold write. The state is NULL until the first
-- row, so an aggregate over no cold rows writes nothing and returns 0.
-- ============================================================================
CREATE TYPE coldfront._cold_sink_state AS (
    iceberg text,       -- the DuckDB ref the batches are written to
    cols    text[],     -- hot-table columns in attnum order, vector companions excluded
    types   text[],     -- their PG types, for _cold_row_literal
    batch   int,        -- rows per flush
    buf     text[],     -- rendered tuples waiting for a flush
    total   bigint      -- rows rendered so far
);

-- coldfront._cold_row_literal: render one row (jsonb keyed by column name) as a
-- DuckDB positional VALUES tuple in attnum order. bytea is rebuilt with
-- from_hex from its hex digits, a vector is cast to FLOAT[], an array becomes a
-- DuckDB list of its elements' literals, a NULL is NULL, everything else is a
-- quoted literal DuckDB coerces to the storage type. Each vector's cluster column leads the tuple
-- (_vec_list_prefix), derived from that row's own vector literal.
CREATE FUNCTION coldfront._cold_row_literal(
    p_payload jsonb, p_cols text[], p_types text[], p_schema text, p_view text
) RETURNS text
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
    row_lit   text := '';
    col       text;
    val_text  text;
    i         int;
    vec_cols  text[] := '{}';
    vec_exprs text[] := '{}';
BEGIN
    FOR i IN 1 .. array_length(p_cols, 1) LOOP
        col := p_cols[i];
        IF i > 1 THEN row_lit := row_lit || ', '; END IF;
        IF p_payload ? col AND jsonb_typeof(p_payload->col) <> 'null' THEN
            val_text := p_payload->>col;
            IF coldfront._is_vector_type(p_types[i]) THEN
                vec_cols  := vec_cols  || col;
                vec_exprs := vec_exprs || coldfront._render_cold_value(val_text, p_types[i]);
                row_lit   := row_lit || vec_exprs[cardinality(vec_exprs)];
            ELSE
                row_lit := row_lit || coldfront._render_cold_value(val_text, p_types[i]);
            END IF;
        ELSE
            -- A NULL vector still owns its prefix slot: the Iceberg schema
            -- declares one cluster column per vector column unconditionally,
            -- so a shorter prefix would misalign the positional tuple.
            IF coldfront._is_vector_type(p_types[i]) THEN
                vec_cols  := vec_cols  || col;
                vec_exprs := vec_exprs || 'NULL'::text;
            END IF;
            row_lit := row_lit || 'NULL';
        END IF;
    END LOOP;
    RETURN coldfront._vec_list_prefix(p_schema, p_view, vec_cols, vec_exprs) || row_lit;
END;
$$;

-- One batch to Iceberg, under the table's claim.
CREATE FUNCTION coldfront._cold_sink_flush(s coldfront._cold_sink_state)
RETURNS coldfront._cold_sink_state
LANGUAGE plpgsql AS $$
BEGIN
    IF cardinality(s.buf) > 0 THEN
        PERFORM coldfront._take_iceberg_claim(s.iceberg);
        PERFORM duckdb.raw_query(format('INSERT INTO %s VALUES %s',
                                        s.iceberg, array_to_string(s.buf, ', ')));
        s.buf := '{}';
    END IF;
    RETURN s;
END;
$$;

-- The step function. The first row resolves the registry row and the hot
-- table's columns, with the standby guard ahead of every lookup.
CREATE FUNCTION coldfront._cold_sink_step(
    s coldfront._cold_sink_state, p_schema text, p_view text, p_row jsonb
) RETURNS coldfront._cold_sink_state
LANGUAGE plpgsql AS $$
DECLARE
    v_hot_table text;
    v_iceberg   text;
BEGIN
    IF s.iceberg IS NULL THEN
        PERFORM coldfront._reject_on_standby('execute a cold (Iceberg) write');
        -- The statement may run from a cached plan (PREPARE, a plpgsql
        -- function's later call) in a transaction the hook never saw, so the
        -- catalog attach and pg_duckdb's mixed-write guard belong here, at
        -- execution, ahead of the first flush.
        PERFORM coldfront.ensure_attached();
        SET LOCAL duckdb.unsafe_allow_mixed_transactions = on;
        SELECT tv.hot_table, tv.iceberg_table INTO v_hot_table, v_iceberg
          FROM coldfront.tiered_views tv
         WHERE tv.schema_name = p_schema AND tv.relname = p_view
           AND NOT tv.is_iceberg_only;
        IF v_iceberg IS NULL THEN
            RAISE EXCEPTION 'coldfront._cold_sink: view %.% is not a registered tiered view',
                p_schema, p_view;
        END IF;
        SELECT v_iceberg,
               array_agg(a.attname::text ORDER BY a.attnum),
               array_agg(format_type(a.atttypid, a.atttypmod) ORDER BY a.attnum),
               current_setting('coldfront.cold_write_batch_size')::int,
               '{}'::text[], 0::bigint
          INTO s
          FROM pg_attribute a
          JOIN pg_class c     ON c.oid = a.attrelid
          JOIN pg_namespace n ON n.oid = c.relnamespace
         WHERE n.nspname = (parse_ident(v_hot_table))[1]
           AND c.relname = (parse_ident(v_hot_table))[2]
           AND a.attnum > 0 AND NOT a.attisdropped
           AND NOT coldfront._is_vec_companion(a.attname, a.attgenerated);
        -- A cluster assignment reads the centroids over pglocal.
        IF coldfront._types_have_vector(s.types) THEN
            PERFORM coldfront.ensure_pg_attached();
        END IF;
    END IF;
    s.buf   := s.buf || ('(' || coldfront._cold_row_literal(p_row, s.cols, s.types, p_schema, p_view) || ')');
    s.total := s.total + 1;
    IF cardinality(s.buf) >= s.batch THEN
        s := coldfront._cold_sink_flush(s);
    END IF;
    RETURN s;
END;
$$;

CREATE FUNCTION coldfront._cold_sink_final(s coldfront._cold_sink_state)
RETURNS bigint
LANGUAGE plpgsql AS $$
BEGIN
    IF s.iceberg IS NULL THEN
        RETURN 0;
    END IF;
    s := coldfront._cold_sink_flush(s);
    RETURN s.total;
END;
$$;

CREATE AGGREGATE coldfront._cold_sink(text, text, jsonb) (
    SFUNC     = coldfront._cold_sink_step,
    STYPE     = coldfront._cold_sink_state,
    FINALFUNC = coldfront._cold_sink_final
);

-- coldfront._cross_tier_move: execute a partition-column UPDATE that crosses the
-- hot/cold cutoff, relocating the matched rows between tiers. The C post-parse-
-- analyze hook detects the move (partition column in
-- SET, cutoff present, coldfront.allow_mixed_writes on), deparses the user WHERE
-- (p_where) and the new partition-column value e (p_newpc) over the VIEW's columns,
-- and installs `SELECT coldfront._cross_tier_move(schema, view, where, e)` as the
-- statement — so this runs at top level, in the user's one transaction.
--
-- It is the mixed-tier-update shape (hot tier = plain PG, cold tier = one
-- duckdb.raw_query under one bakery claim), with rows routed by (current tier,
-- e vs cutoff) into four disjoint cases handled separately:
--   stay-hot  hot,  e>=cut : in-place UPDATE of the hot heap.
--   hot→cold  hot,  e<cut  : the row leaves the heap (DELETE) and is added to
--                            Iceberg (INSERT).
--   cold→hot  cold, e>=cut : the row is read from Iceberg into the heap (a
--                            cursor row, re-inserted by VALUE) and removed from Iceberg.
--   stay-cold cold, e<cut  : removed from Iceberg and re-added with the new ts.
-- Same-tier changes are in-place; crossings write the OTHER tier and remove from
-- the origin (different relations) — no same-relation overlap.
--
-- Cold tier: ONE raw_query (DELETE-set + INSERT-set = one MetaTransaction = one
-- snapshot, the replay_archive_delta idiom) under ONE claim (never per-row
-- tickets). The cold rows are read through the catalog's table entry
-- (duckdb.query over the Iceberg table), whose scan includes the transaction's
-- own pending rows; pg_duckdb permits that read inside a function only with
-- duckdb.unsafe_allow_execution_inside_functions, which the move needs because
-- the legs are deparsed and run together here. The cold rows destined to
-- stay/return cold are serialised by VALUE from that cursor before the one
-- raw_query runs; hot→cold rows are serialised from a heap cursor. DELETE is by
-- the OLD primary key; old/new keys differ (the partition column changed) so it
-- never hits a just-inserted row.
CREATE FUNCTION coldfront._cross_tier_move(
    p_view_schema text, p_view_name text, p_where text, p_newpc text
) RETURNS void
LANGUAGE plpgsql AS $fn$
DECLARE
    v_hot_table   text;
    v_iceberg     text;
    v_partcol     text;
    v_cutoff      timestamptz;
    v_hot_schema  text;
    v_hot_relname text;
    v_cut_lit     text;          -- 'YYYY-…'::timestamptz of the cutoff
    v_pc          text;          -- quoted partition column
    v_cols        text;          -- heap col list (all live cols), quoted
    v_cold_read   text;          -- cold read projection: r[col]::cast AS col
    v_has_ident   boolean;
    v_inner       text;          -- "SELECT v_cold_read FROM duckdb.query(...) AS t(r) WHERE r[pc] < cut"
    full_cols     text[];
    full_types    text[];
    pk_names      text[];
    pk_types      text[];          -- Iceberg storage type per PK column (for DELETE casts)
    v_pk_list     text;
    cur           refcursor;
    rec           record;
    payload       jsonb;
    pk_lit        text;
    ins_arr       text[] := '{}'; -- cold-destined Iceberg VALUES tuples (DuckDB literals)
    heap_arr      text[] := '{}'; -- cold→hot heap VALUES tuples (PG literals)
    del_arr       text[] := '{}'; -- OLD primary-key tuples to DELETE from Iceberg
    cold_sql      text := '';
    v_targets     timestamptz[];
    v_hot_targets timestamptz[];
    v_uncovered   bigint;
BEGIN
    -- The cold leg below reaches duckdb.raw_query directly rather than through
    -- _exec_iceberg_with_claim, so it carries the standby guard itself. The hook
    -- rewrite that reaches here is a bare SELECT, which PG's read-only check passes.
    PERFORM coldfront._reject_on_standby('move rows across tiers (Iceberg write)');
    SET LOCAL duckdb.unsafe_allow_execution_inside_functions = on;
    SET LOCAL duckdb.unsafe_allow_mixed_transactions = on;
    SET LOCAL coldfront.iceberg_async_parquet = off;
    SET LOCAL bytea_output = 'hex';

    SELECT tv.hot_table, tv.iceberg_table, tv.partition_col, aw.cutoff_time
    INTO v_hot_table, v_iceberg, v_partcol, v_cutoff
    FROM coldfront.tiered_views tv
    LEFT JOIN coldfront.archive_watermark aw ON aw.schema_name = p_view_schema AND aw.table_name = p_view_name
    WHERE tv.schema_name = p_view_schema AND tv.relname = p_view_name;
    IF v_hot_table IS NULL OR v_cutoff IS NULL THEN
        RAISE EXCEPTION 'coldfront: cross-tier move on %.% requires a tiered view with a cutoff',
            p_view_schema, p_view_name;
    END IF;

    v_hot_schema  := (parse_ident(v_hot_table))[1];
    v_hot_relname := (parse_ident(v_hot_table))[2];
    v_pc          := quote_ident(v_partcol);
    v_cut_lit     := quote_literal(to_char(v_cutoff AT TIME ZONE 'UTC',
                                           'YYYY-MM-DD HH24:MI:SS.US+00')) || '::timestamptz';

    -- All live heap columns in attnum order — names, types, and whether any is an
    -- identity column — in ONE catalog scan. v_cols (quoted list) and v_cold_read
    -- (the cold read projection r[col]::cast AS col) derive from the
    -- arrays, mirroring _rebuild_tiered_view's casts (one source of truth via
    -- _iceberg_view_cast_type / _iceberg_storage_type; view cast, else storage).
    SELECT array_agg(a.attname ORDER BY a.attnum),
           array_agg(format_type(a.atttypid, a.atttypmod) ORDER BY a.attnum),
           bool_or(a.attidentity <> '')
    INTO full_cols, full_types, v_has_ident
    FROM pg_attribute a JOIN pg_class c ON c.oid = a.attrelid
    JOIN pg_namespace nn ON nn.oid = c.relnamespace
    WHERE nn.nspname = v_hot_schema AND c.relname = v_hot_relname
      AND a.attnum > 0 AND NOT a.attisdropped
      AND NOT coldfront._is_vec_companion(a.attname, a.attgenerated);
    SELECT string_agg(quote_ident(col), ', ' ORDER BY ord),
           string_agg(format('r[%L]::%s AS %I', col,
                             COALESCE(NULLIF(coldfront._iceberg_view_cast_type(typ), ''),
                                      coldfront._iceberg_storage_type(typ)), col),
                      ', ' ORDER BY ord)
    INTO v_cols, v_cold_read
    FROM unnest(full_cols, full_types) WITH ORDINALITY AS u(col, typ, ord);
    SELECT array_agg(a.attname ORDER BY x.ord),
           array_agg(coldfront._iceberg_storage_type(format_type(a.atttypid, a.atttypmod)) ORDER BY x.ord)
    INTO pk_names, pk_types
    FROM pg_index idx JOIN pg_class c ON c.oid = idx.indrelid
    JOIN pg_namespace nn ON nn.oid = c.relnamespace
    JOIN unnest(idx.indkey) WITH ORDINALITY AS x(attnum, ord) ON true
    JOIN pg_attribute a ON a.attrelid = idx.indrelid AND a.attnum = x.attnum
    WHERE nn.nspname = v_hot_schema AND c.relname = v_hot_relname AND idx.indisprimary;
    IF pk_names IS NULL THEN
        RAISE EXCEPTION 'coldfront: cross-tier move on view "%" requires a primary key on the hot table', p_view_name;
    END IF;
    SELECT string_agg(quote_ident(nm), ', ' ORDER BY ord) INTO v_pk_list
    FROM unnest(pk_names) WITH ORDINALITY AS u(nm, ord);

    v_inner := format('SELECT %s FROM duckdb.query(%L) AS t(r) WHERE r[%L] < %s',
                      v_cold_read, format('SELECT * FROM %s', v_iceberg), v_partcol, v_cut_lit);
    PERFORM coldfront.ensure_attached();
    IF coldfront._types_have_vector(full_types) THEN
        PERFORM coldfront.ensure_pg_attached();
    END IF;

    -- Reject a cold→hot target with no covering hot partition, naming the VIEW
    -- (never the internal heap name): the heap is RANGE-partitioned with no default
    -- partition, so a row LANDING hot (cold→hot, or stay-hot whose new ts crosses a
    -- hot-partition boundary) would otherwise raise PG's "no partition of relation
    -- _events". Collect the distinct new-ts values of all hot-landing rows from both
    -- tiers (cold through DuckDB, hot via the heap) kept in SEPARATE queries so
    -- one never mixes the DuckDB read with pg_catalog (which pg_duckdb cannot
    -- read), then check coverage against pg_inherits leaf bounds (split_part on the
    -- single-key FOR VALUES FROM ('lo') TO ('hi') rendering; no regex).
    EXECUTE format(
        'SELECT array_agg(DISTINCT (%2$s)::timestamptz) FROM ( %1$s ) s WHERE (%3$s) AND (%2$s) >= %4$s',
        v_inner, p_newpc, p_where, v_cut_lit) INTO v_targets;
    EXECUTE format(
        'SELECT array_agg(DISTINCT (%6$s)::timestamptz) FROM %1$I.%2$I WHERE (%5$s) AND %3$s >= %4$s AND (%6$s) >= %4$s',
        v_hot_schema, v_hot_relname, v_pc, v_cut_lit, p_where, p_newpc) INTO v_hot_targets;
    v_targets := COALESCE(v_targets, '{}'::timestamptz[]) || COALESCE(v_hot_targets, '{}'::timestamptz[]);
    IF array_length(v_targets, 1) > 0 THEN
        SELECT count(*) INTO v_uncovered
        FROM unnest(v_targets) AS tv
        WHERE NOT EXISTS (
            SELECT 1 FROM pg_inherits i JOIN pg_class c ON c.oid = i.inhrelid,
            LATERAL pg_get_expr(c.relpartbound, c.oid) AS b
            WHERE i.inhparent = format('%I.%I', v_hot_schema, v_hot_relname)::regclass
              AND b LIKE 'FOR VALUES FROM %'
              AND tv >= split_part(b, '''', 2)::timestamptz
              AND tv <  split_part(b, '''', 4)::timestamptz);
        IF v_uncovered > 0 THEN
            RAISE EXCEPTION 'coldfront: cross-tier move on view "%" targets a hot partition that does not exist',
                p_view_name
                USING HINT = 'The new partition-column value falls outside the pre-made hot partitions; create the covering partition first, or choose a value within an existing one.';
        END IF;
    END IF;

    -- One claim for the whole move (released at xact end by the C XactCallback);
    -- mesh takes the R-A bakery, vanilla a local advisory xact lock.
    PERFORM coldfront._take_iceberg_claim(v_iceberg);

    -- ── Capture the moved rows by VALUE (no DuckDB read in any modifying stmt) ──
    -- Affected COLD rows are read with a SELECT cursor over the catalog read (a
    -- pure read, which pg_duckdb runs in DuckDB; a modifying INSERT … FROM that
    -- read would trip pg_duckdb's "cannot modify a Postgres table" path). Each
    -- affected cold row is DELETEd from Iceberg by its OLD pk; rows staying cold are
    -- re-added to Iceberg with the new ts; rows crossing to hot are added to the
    -- heap. cf_new_ts is computed in the cursor so e is evaluated once per row.
    OPEN cur FOR EXECUTE format(
        'SELECT s.*, (%2$s) AS cf_new_ts FROM ( %1$s ) s WHERE (%3$s)',
        v_inner, p_newpc, p_where);
    LOOP
        FETCH cur INTO rec;
        EXIT WHEN NOT FOUND;
        payload := to_jsonb(rec);
        -- OLD primary key, each part cast to its Iceberg storage type so DuckDB's
        -- row IN matches the typed columns (a bare string literal would not coerce).
        SELECT string_agg(quote_literal(payload->>nm) || '::' || typ, ', ' ORDER BY ord)
        INTO pk_lit
        FROM unnest(pk_names, pk_types) WITH ORDINALITY AS u(nm, typ, ord);
        del_arr := del_arr || ('(' || pk_lit || ')');

        IF (payload->>'cf_new_ts')::timestamptz < v_cutoff THEN
            -- stay-cold: re-add to Iceberg (DuckDB literal tuple).
            ins_arr := ins_arr || ('(' || coldfront._move_row_literal(payload, full_cols, full_types, v_partcol,
                                                              p_view_schema, p_view_name) || ')');
        ELSE
            -- cold→hot: add to the heap (PG literal tuple, partition column = e).
            heap_arr := heap_arr || ('(' || coldfront._move_pg_row_literal(payload, full_cols, full_types, v_partcol) || ')');
        END IF;
    END LOOP;
    CLOSE cur;

    -- hot→cold: remove the crossing rows from the heap and capture them for the
    -- Iceberg insert in ONE atomic DELETE ... RETURNING, so there is no
    -- read-then-delete window for a concurrent heap writer to race. cf_new_ts is
    -- computed over the deleted row, exactly as the cold cursor above does.
    FOR rec IN EXECUTE format(
        'DELETE FROM %1$I.%2$I h WHERE (%5$s) AND %3$s >= %4$s AND (%6$s) < %4$s RETURNING h.*, (%6$s) AS cf_new_ts',
        v_hot_schema, v_hot_relname, v_pc, v_cut_lit, p_where, p_newpc)
    LOOP
        payload := to_jsonb(rec);
        ins_arr := ins_arr || ('(' || coldfront._move_row_literal(payload, full_cols, full_types, v_partcol,
                                                              p_view_schema, p_view_name) || ')');
    END LOOP;

    -- ── Hot heap (plain PG) ───────────────────────────────────────────────────
    -- stay-hot: in-place ts change. Runs BEFORE the cold→hot INSERT so a
    -- row-dependent new value (e.g. ts + interval) is never applied a second time
    -- to a row this same statement just inserted.
    EXECUTE format(
        'UPDATE %1$I.%2$I SET %3$s = (%6$s) WHERE (%5$s) AND %3$s >= %4$s AND (%6$s) >= %4$s',
        v_hot_schema, v_hot_relname, v_pc, v_cut_lit, p_where, p_newpc);
    -- cold→hot: INSERT the captured rows (carrying the existing identity).
    IF array_length(heap_arr, 1) > 0 THEN
        EXECUTE format('INSERT INTO %1$I.%2$I (%3$s) %4$s VALUES %5$s',
            v_hot_schema, v_hot_relname, v_cols,
            CASE WHEN v_has_ident THEN 'OVERRIDING SYSTEM VALUE' ELSE '' END,
            array_to_string(heap_arr, ', '));
    END IF;

    -- ── Cold tier: ONE raw_query (DELETE old keys + INSERT cold-destined) ────────
    IF array_length(del_arr, 1) > 0 THEN
        cold_sql := format('DELETE FROM %s WHERE (%s) IN (%s)', v_iceberg, v_pk_list, array_to_string(del_arr, ', '));
    END IF;
    IF array_length(ins_arr, 1) > 0 THEN
        IF cold_sql <> '' THEN cold_sql := cold_sql || '; '; END IF;
        cold_sql := cold_sql || format('INSERT INTO %s VALUES %s', v_iceberg, array_to_string(ins_arr, ', '));
    END IF;
    IF cold_sql <> '' THEN
        PERFORM duckdb.raw_query(cold_sql);
    END IF;
END;
$fn$;

-- coldfront._move_row_literal: render one captured row (jsonb of surface values +
-- cf_new_ts) as a DuckDB positional VALUES tuple for the Iceberg INSERT: the
-- partition column takes cf_new_ts, and _cold_row_literal renders the tuple.
CREATE FUNCTION coldfront._move_row_literal(
    p_payload jsonb, p_cols text[], p_types text[], p_partcol text,
    p_schema text, p_view text
) RETURNS text
LANGUAGE sql IMMUTABLE AS $$
    SELECT coldfront._cold_row_literal(
        jsonb_set(p_payload, ARRAY[p_partcol], to_jsonb(p_payload->>'cf_new_ts')),
        p_cols, p_types, p_schema, p_view);
$$;

-- coldfront._move_pg_row_literal: the cold→hot counterpart of _move_row_literal —
-- render a captured row as a positional VALUES tuple for the PG heap INSERT. The
-- partition column takes cf_new_ts; every other value is an unknown-typed literal
-- (quote_nullable) that PG coerces to the heap column type on INSERT (so bytea hex
-- and jsonb text round-trip with no per-type handling), except an array, which
-- the payload holds as a jsonb list and the heap takes as PostgreSQL array text.
-- p_types are the heap columns' types, so a jsonb column's own list stays jsonb.
-- NULL stays NULL.
CREATE FUNCTION coldfront._move_pg_row_literal(
    p_payload jsonb, p_cols text[], p_types text[], p_partcol text
) RETURNS text
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
    row_lit text := '';
    col     text;
    i       int;
BEGIN
    FOR i IN 1 .. array_length(p_cols, 1) LOOP
        col := p_cols[i];
        IF i > 1 THEN row_lit := row_lit || ', '; END IF;
        IF col = p_partcol THEN
            row_lit := row_lit || quote_nullable(p_payload->>'cf_new_ts');
        ELSIF p_types[i] LIKE '%[]' AND jsonb_typeof(p_payload->col) = 'array' THEN
            row_lit := row_lit || quote_literal(coalesce(
                (SELECT array_agg(e ORDER BY o)
                   FROM jsonb_array_elements_text(p_payload->col) WITH ORDINALITY AS u(e, o))::text,
                '{}'));
        ELSE
            row_lit := row_lit || quote_nullable(p_payload->>col);
        END IF;
    END LOOP;
    RETURN row_lit;
END;
$$;


-- replay_archive_delta: drains delta rows whose xid is NOT visible in the
-- bulk-copy snapshot, applying DELETE-then-INSERT to Iceberg per source PK.
-- Loops with batched COMMIT so concurrent writers (whose triggers also write
-- to the delta) aren't blocked by long-held locks.
--
-- Each row's apply is one duckdb.raw_query call. For deletes that's a single
-- DELETE. For inserts/updates, DELETE-then-INSERT in one raw_query call (one
-- DuckDB tx) so the upsert is atomic per row. We don't use MERGE because
-- duckdb-iceberg's MERGE support varies by version; DELETE+INSERT always works.
--
-- Idempotent: replaying the same delta row twice is a no-op (DELETE matches
-- nothing the second time, INSERT lands the same values).
CREATE OR REPLACE PROCEDURE coldfront.replay_archive_delta(
    p_schema text, p_part text, p_snapshot text, p_iceberg_ref text
)
LANGUAGE plpgsql AS $$
DECLARE
    delta_tbl     text := format('coldfront.%I',
                                 'delta_' || p_schema || '_' || p_part);
    col_names     text[];
    pk_names      text[];
    batch_size    int := 1000;
    pk_list       text;
    col_list      text;
    col_types     text[];
    scratch_proj  text;
    visibility    text;
    scratch_tbl   text;
    scratch_qual  text;
    n_applied     bigint;
    total_applied bigint := 0;
BEGIN
    -- Resolve column / PK order ONCE per procedure call (stable for the
    -- lifetime of the partition's archive cycle).
    SELECT array_agg(a.attname ORDER BY a.attnum),
           array_agg(format_type(a.atttypid, a.atttypmod) ORDER BY a.attnum)
    INTO col_names, col_types
    FROM pg_attribute a
    JOIN pg_class c ON c.oid = a.attrelid
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = p_schema AND c.relname = p_part
      AND a.attnum > 0 AND NOT a.attisdropped
      AND NOT coldfront._is_vec_companion(a.attname, a.attgenerated);

    SELECT array_agg(a.attname ORDER BY x.ord)
    INTO pk_names
    FROM pg_index i
    JOIN pg_class c ON c.oid = i.indrelid
    JOIN pg_namespace n ON n.oid = c.relnamespace
    JOIN unnest(i.indkey) WITH ORDINALITY AS x(attnum, ord) ON true
    JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = x.attnum
    WHERE n.nspname = p_schema AND c.relname = p_part AND i.indisprimary;

    SELECT string_agg(quote_ident(name), ', ' ORDER BY ord) INTO pk_list
    FROM unnest(pk_names) WITH ORDINALITY AS u(name, ord);
    -- Two projections over the same columns. The scratch reads the delta through
    -- PostgreSQL, so a vector is cast to real[] there: DuckDB reads the scratch
    -- over libpq and cannot scan the pgvector type at all. The Iceberg INSERT is
    -- positional and its target leads with the cluster columns.
    SELECT string_agg(quote_ident(name), ', ' ORDER BY ord),
           string_agg(CASE WHEN coldfront._is_vector_type(typ)
                           THEN format('%I::real[] AS %I', name, name)
                           ELSE quote_ident(name) END, ', ' ORDER BY ord)
    INTO col_list, scratch_proj
    FROM unnest(col_names, col_types) WITH ORDINALITY AS u(name, typ, ord);

    -- The clusters lead the Iceberg INSERT, derived set-based from the scratch's
    -- own columns. Keyed on the ref, since the configuration names the user's table
    -- and this procedure is handed one of its partitions.
    col_list := COALESCE(coldfront._vec_list_prefix_for_ref(p_iceberg_ref, ''), '')
             || col_list;

    -- Snapshot filter: in replay, skip rows still visible in the bulk-copy
    -- snapshot (they're already in the bulk export). cutover_archive's
    -- final drain passes NULL to drain unconditionally.
    IF p_snapshot IS NULL THEN
        visibility := 'true';
    ELSE
        visibility := format('NOT pg_visible_in_snapshot(coldfront_xid, %L::pg_snapshot)',
                             p_snapshot);
    END IF;

    LOOP
        scratch_tbl  := format('replay_scratch_%s_%s',
                               pg_backend_pid()::text,
                               pg_current_xact_id()::text);
        scratch_qual := format('coldfront.%I', scratch_tbl);

        -- Stage: snapshot the eligible rows into a real (UNLOGGED) table.
        -- pglocal opens a fresh PG session (different from this procedure's
        -- session), so the scratch must be COMMITTED before the raw_query
        -- below — pglocal's read-committed snapshot only sees committed
        -- state of non-temp tables. UNLOGGED skips WAL but persists across
        -- the COMMIT, which is what we need.
        EXECUTE format(
            'CREATE UNLOGGED TABLE %s AS
             SELECT %s, coldfront_is_deleted, coldfront_xid FROM %s WHERE %s LIMIT %s',
            scratch_qual, scratch_proj, delta_tbl, visibility, batch_size);

        EXECUTE format('SELECT count(*) FROM %s', scratch_qual) INTO n_applied;

        IF n_applied = 0 THEN
            EXECUTE format('DROP TABLE %s', scratch_qual);
            EXIT;
        END IF;

        -- Make scratch visible to the pglocal session.
        COMMIT;

        -- Mixed-tx flag is SET LOCAL so it resets at COMMIT; re-arm.
        SET LOCAL duckdb.unsafe_allow_mixed_transactions = on;

        -- Ensure pglocal is attached on the DuckDB side (idempotent).
        PERFORM coldfront.ensure_pg_attached();

        -- Single raw_query: DELETE prior PKs from Iceberg, INSERT non-deleted
        -- rows by streaming over libpq from pglocal.<scratch>. DuckDB executes
        -- both statements in one MetaTransaction → one Iceberg snapshot for
        -- the entire batch. The DuckDB tx commits at the PG COMMIT below
        -- (via pg_duckdb's XactCallback); pglocal's libpq read tx commits
        -- with it, releasing the AccessShareLock it held on the scratch
        -- table.
        --
        -- Routed through _exec_iceberg_with_claim so this archiver batch
        -- commit is serialized against concurrent cold writers on other nodes
        -- (multi-node) or other local backends (single-node) — same no-409
        -- guarantee as user-facing cold DML. The loop COMMITs per batch, so
        -- the claim/lock is acquired and released per batch.
        PERFORM coldfront._exec_iceberg_with_claim(p_iceberg_ref, format(
            'DELETE FROM %s WHERE (%s) IN (SELECT %s FROM pglocal.coldfront.%I);
             INSERT INTO %s SELECT %s FROM pglocal.coldfront.%I WHERE NOT coldfront_is_deleted',
            p_iceberg_ref, pk_list, pk_list, scratch_tbl,
            p_iceberg_ref, col_list, scratch_tbl));

        total_applied := total_applied + n_applied;

        -- COMMIT here is the lock-release point. Before this, pglocal's
        -- libpq tx (opened by DuckDB to read pglocal.<scratch>) still
        -- holds AccessShareLock on the scratch table — DuckDB defers the
        -- pglocal commit to the iceberg MetaTransaction commit, which
        -- itself fires at PG xact commit via pg_duckdb's XactCallback.
        -- Attempting DROP TABLE before this COMMIT would deadlock on
        -- AccessExclusive.
        COMMIT;
        SET LOCAL duckdb.unsafe_allow_mixed_transactions = on;

        -- Lock now free: drain the scratched PKs from the real delta
        -- table, then drop the scratch.
        EXECUTE format(
            'DELETE FROM %s d WHERE (%s) IN (SELECT %s FROM %s)',
            delta_tbl, pk_list, pk_list, scratch_qual);

        EXECUTE format('DROP TABLE %s', scratch_qual);

        COMMIT;
        SET LOCAL duckdb.unsafe_allow_mixed_transactions = on;
    END LOOP;

    RAISE NOTICE 'coldfront: replay applied % rows from %', total_applied, delta_tbl;
END;
$$;

-- cutover_archive: atomic Phase 4. Holds AccessExclusive on the partition's
-- parent + the partition itself for ≤1s, with a 100ms lock_timeout circuit
-- breaker. On any RAISE EXCEPTION (lock timeout, post-lock elapsed > budget,
-- final drain leaves residue), the entire procedure rolls back cleanly:
-- watermark unchanged, view unchanged, partition still attached. Caller can
-- retry.
--
-- p_view_ddl is the full CREATE OR REPLACE VIEW statement built by the
-- archiver from the source's column types. We pass it through rather than
-- reconstructing it here because the column→DuckDB type mapping lives in Go.
-- cutover_archive: DML (UPDATE watermark) + BAKERY + LOCK + DDL (view + DETACH).
-- Caller drains the delta via replay_archive_delta before AND after this.
--
-- p_iceberg_ref is the cold table this partition feeds. We take the SAME bakery
-- serializer the cold-write path takes on that key BEFORE the ACCESS EXCLUSIVE,
-- so the DETACH can never race a concurrent cold writer: an in-flight writer is
-- waited out (its RowExclusive drops at commit) and new writers block. The
-- bakery (B) is always acquired before the partition lock (A) — a global lock
-- order that, with the lock_timeout circuit breaker on A, is deadlock-free.
CREATE OR REPLACE PROCEDURE coldfront.cutover_archive(
    p_schema text, p_part text, p_source text,
    p_new_cutoff timestamptz, p_view_ddl text, p_iceberg_ref text,
    p_lock_timeout_ms int DEFAULT 100
)
LANGUAGE plpgsql AS $$
DECLARE
    parent_table text;
BEGIN
    SELECT format('%I.%I', n.nspname, c.relname) INTO parent_table
    FROM pg_inherits i
    JOIN pg_class c ON c.oid = i.inhparent
    JOIN pg_namespace n ON n.oid = c.relnamespace
    JOIN pg_class child ON child.oid = i.inhrelid
    JOIN pg_namespace cn ON cn.oid = child.relnamespace
    WHERE cn.nspname = p_schema AND child.relname = p_part;
    IF parent_table IS NULL THEN
        RAISE EXCEPTION 'cutover: % is not an attached partition', p_part;
    END IF;

    UPDATE coldfront.archive_watermark
       SET cutoff_time = p_new_cutoff
     WHERE schema_name = p_schema AND table_name = p_source;
    IF NOT FOUND THEN
        INSERT INTO coldfront.archive_watermark (schema_name, table_name, cutoff_time)
        VALUES (p_schema, p_source, p_new_cutoff);
    END IF;

    -- GLOBAL LOCK ORDER, step 1 — take the bakery (resource B) BEFORE any
    -- partition ACCESS EXCLUSIVE (resource A). Every path that holds both
    -- acquires B before A, so no wait-for cycle can form. Held to this proc's
    -- COMMIT: mesh release is enqueued for the C XactCallback (fires after
    -- pg_duckdb's, so the iceberg side is settled), vanilla advisory is
    -- xact-scoped. Deliberately NO lock_timeout on this acquire — we WANT to
    -- wait out an in-flight cold writer's full commit so its RowExclusive on the
    -- partition is gone before we ask for ACCESS EXCLUSIVE.
    -- Same per-iceberg-table mutex the cold WRITE path takes, on the SAME key,
    -- so the cutover serializes against concurrent cold writers (mesh R-A claim,
    -- vanilla advisory). No lock_timeout here (deliberate; see above).
    PERFORM coldfront._take_iceberg_claim(p_iceberg_ref);

    -- GLOBAL LOCK ORDER, step 2 — now A. lock_timeout is the circuit breaker on
    -- the ACCESS EXCLUSIVE acquisition ONLY (not the bakery above): if a writer
    -- still holds RowExclusive (took A before B — the dual-tier CTE order is
    -- undefined), this proc aborts in p_lock_timeout_ms, frees B, and the Go
    -- harness retries. lock_timeout (100ms) < deadlock_timeout (1s) so the
    -- cutover, never the writer, yields first.
    EXECUTE format('SET LOCAL lock_timeout = %L', p_lock_timeout_ms || 'ms');
    EXECUTE format('LOCK TABLE %s IN ACCESS EXCLUSIVE MODE', parent_table);
    EXECUTE format('LOCK TABLE %I.%I IN ACCESS EXCLUSIVE MODE', p_schema, p_part);

    EXECUTE p_view_ddl;
    EXECUTE format('ALTER TABLE %s DETACH PARTITION %I.%I', parent_table, p_schema, p_part);
END;
$$;

-- cutover_cleanup: drain stragglers that arrived in the gap between Phase 3's
-- final commit and cutover_archive's ACCESS EXCLUSIVE lock, then drop the
-- detached partition + coldfront-private artifacts. Runs in its own
-- uncontended tx after cutover_archive has committed: partition is detached,
-- so no new writes can route to it, capture trigger is inert, the inner
-- replay is a finite catch-up over whatever landed during the lock window.
CREATE OR REPLACE PROCEDURE coldfront.cutover_cleanup(
    p_schema text, p_part text,
    p_snapshot text, p_iceberg_ref text
)
LANGUAGE plpgsql AS $$
DECLARE
    delta_tbl   text := format('coldfront.%I', 'delta_' || p_schema || '_' || p_part);
    capture_fn  text := format('coldfront.%I', 'delta_capture_' || p_schema || '_' || p_part);
    truncate_fn text := format('coldfront.%I', 'delta_block_truncate_' || p_schema || '_' || p_part);
BEGIN
    CALL coldfront.replay_archive_delta(p_schema, p_part, p_snapshot, p_iceberg_ref);

    EXECUTE format('DROP TABLE IF EXISTS %I.%I', p_schema, p_part);
    EXECUTE format('DROP FUNCTION IF EXISTS %s() CASCADE', capture_fn);
    EXECUTE format('DROP FUNCTION IF EXISTS %s() CASCADE', truncate_fn);
    EXECUTE format('DROP TABLE IF EXISTS %s', delta_tbl);
END;
$$;

-- ============================================================================
-- Decoupled (iceberg-only) operating mode.
--
-- Helpers below let an operator create a table that lives entirely in
-- Iceberg from row 1: no PG heap, no hot tier, no archiver. The PG side is
-- a thin wrapper view that projects the Iceberg table into PG-typed columns.
-- INSERT/UPDATE/DELETE on the wrapper view are rewritten by the coldfront
-- post_parse_analyze hook (which short-circuits to TIER_COLD when the
-- registry row has is_iceberg_only=true).
--
-- The supported column types are those coldfront._iceberg_storage_type maps,
-- the map tiered mode uses as well. Anything outside the set is rejected at
-- create time. See docs/architecture_decoupled.md for the full table.
-- ============================================================================

-- pgvector's vector/halfvec, with or without the dimension typmod. Both maps
-- below call this so they cannot disagree about what counts as a vector: the
-- storage type and the view cast have to move together or a column stores one
-- way and reads another. sparsevec is excluded deliberately (densifying it is a
-- 100x storage blowup), so it falls through to the unsupported-type error.
CREATE OR REPLACE FUNCTION coldfront._is_vector_type(p_pg_type text)
RETURNS boolean
LANGUAGE sql IMMUTABLE STRICT AS $$
    SELECT lower(trim(p_pg_type)) IN ('vector', 'halfvec')
        OR lower(trim(p_pg_type)) LIKE 'vector(%'
        OR lower(trim(p_pg_type)) LIKE 'halfvec(%';
$$;

-- k-means++ seeding over the session's sample (temp.main.cf_samp): one seed at
-- random, then each next drawn with probability proportional to its squared
-- distance from the nearest seed already chosen, so the seeds spread out instead
-- of clumping. Lloyd's iterations only move centroids locally, so they cannot
-- repair a clumped start. Leaves the seeds in temp.main.cf_cent as (cid, v).
--
-- It matters most where dense clumps exist, which is the lower dimensionalities
-- many embedding models produce; at 1024 dimensions distances concentrate and the
-- spread start makes little difference. Seeding is a one-time training cost and
-- nothing a query pays.
--
-- The draw is an exponential race: for weights w, the minimum of -ln(u)/w is
-- distributed exactly as a weighted draw, in one pass and with no cumulative sum.
-- d is maintained incrementally, folding in only the seed just added, so a round
-- is one pass over the sample rather than one per seed chosen so far. The first
-- seed's draw is fixed, like the sample's, so a retrain on unchanged data
-- reproduces the same centroids.
CREATE OR REPLACE FUNCTION coldfront._vec_seed_kmeanspp(p_nlist int) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
    i int;
BEGIN
    PERFORM duckdb.raw_query(
        'CREATE OR REPLACE TEMP TABLE cf_seed AS '
        'SELECT 1 AS seq, id, v FROM temp.main.cf_samp '
        'USING SAMPLE reservoir(1 ROWS) REPEATABLE (7)');
    PERFORM duckdb.raw_query(
        'CREATE OR REPLACE TEMP TABLE cf_seed_d AS '
        'SELECT s.id, s.v, '
               '(SELECT min(list_cosine_distance(s.v, p.v)) FROM temp.main.cf_seed p) AS d '
          'FROM temp.main.cf_samp s');
    FOR i IN 2 .. p_nlist LOOP
        -- A sample smaller than nlist, or one whose remaining rows all duplicate a
        -- seed, leaves d = 0 everywhere and the draw returns nothing. The centroid
        -- count the caller records is whatever came back, so that resolves itself.
        PERFORM duckdb.raw_query(format(
            'INSERT INTO temp.main.cf_seed '
            'SELECT %s, id, v FROM temp.main.cf_seed_d '
            'WHERE d > 0 ORDER BY -ln(random()) / (d * d) LIMIT 1', i));
        -- Keyed on seq, because a sample id says nothing about insertion order.
        PERFORM duckdb.raw_query(format(
            'UPDATE temp.main.cf_seed_d SET d = least(d, '
                'list_cosine_distance(v, (SELECT p.v FROM temp.main.cf_seed p '
                                         'WHERE p.seq = %s)))', i));
    END LOOP;
    PERFORM duckdb.raw_query(
        'CREATE OR REPLACE TEMP TABLE cf_cent AS '
        'SELECT row_number() OVER (ORDER BY seq) AS cid, v FROM temp.main.cf_seed');
END;
$$;

-- Lloyd's iterations over the session's sample, from the centroids in
-- temp.main.cf_cent and back into it: assign, then recompute each cluster's
-- mean, p_iterations times. The mean unnests the vector against a matching range
-- so the two lists advance together: DuckDB has no WITH ORDINALITY, and position
-- is what makes the average element-wise. Empty clusters do not come back from
-- the mean.
CREATE OR REPLACE FUNCTION coldfront._vec_lloyd(p_iterations int, p_dim int) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
    i int;
BEGIN
    FOR i IN 1 .. p_iterations LOOP
        PERFORM duckdb.raw_query(
            'CREATE OR REPLACE TEMP TABLE cf_asg AS '
            'SELECT s.id, arg_min(c.cid, list_cosine_distance(s.v, c.v)) AS cid '
            'FROM temp.main.cf_samp s CROSS JOIN temp.main.cf_cent c GROUP BY s.id');
        PERFORM duckdb.raw_query(format(
            'CREATE OR REPLACE TEMP TABLE cf_cent AS '
            'SELECT cid, list(m ORDER BY i)::FLOAT[] AS v FROM ('
            '  SELECT cid, i, avg(x) AS m FROM ('
            '    SELECT a.cid, unnest(range(1, %s)) AS i, unnest(s.v) AS x '
            '    FROM temp.main.cf_samp s JOIN temp.main.cf_asg a USING (id))'
            '  GROUP BY cid, i) GROUP BY cid', p_dim + 1));
    END LOOP;
END;
$$;

-- Train a centroid set for one vector column, store it as a new generation, and
-- assign every cold row to its nearest centroid of that generation.
--
-- Lloyd iterations over a reservoir sample, run as DuckDB statements: both the
-- assignment and the mean are distance work over the cold corpus, which is what
-- DuckDB is for and what pulling the vectors into PostgreSQL would waste. The
-- sample and the working tables live in the session's own DuckDB instance, so the
-- whole loop has to run in one call. They are temporary tables rather than tables
-- in memory.main: a DuckDB transaction may write one attached database, the
-- temporary database is exempt, and the assignment at the end writes ice.
--
-- A PROCEDURE, not a function, and that is a hard requirement rather than a
-- preference: pg_duckdb refuses to execute a DuckDB query inside a function
-- ("DuckDB execution is not supported inside functions"), which is the only way
-- to read the trained centroids back. raw_query runs in a function but is a bare
-- DuckDB channel with no access to PostgreSQL tables, so a function can move data
-- in neither direction. CALL is what makes reading the result possible.
--
-- A retrain at the same nlist starts the iterations from the live centroids, so a
-- centroid keeps its id and moves with its data, and the assignment rewrites only
-- the rows whose nearest centroid changed. A first training, or a changed nlist,
-- has no set to start from and seeds with k-means++.
--
-- Empty clusters simply do not come back from the mean, so the stored count can be
-- below p_nlist; it is recorded rather than padded, since a centroid nothing was
-- assigned to routes nothing.
--
-- The table's claim is held from the sample to the commit, as the compactor holds
-- it across its read and rewrite: a cold write landing in between would carry an
-- assignment against the centroids this call replaces.
CREATE PROCEDURE coldfront.vector_train(
    p_schema     text,
    p_table      text,
    p_column     text,
    p_nlist      int DEFAULT NULL,
    p_sample     int DEFAULT 20000,
    p_iterations int DEFAULT 8
)
LANGUAGE plpgsql AS $$
DECLARE
    v_ice       text;
    v_writable  boolean;
    v_nlist     int;
    v_cfg_nlist int;
    v_gen       int;
    v_n         int;
    v_dim       int;
    v_col       text := quote_ident(coldfront._vec_list_col(p_column));
    v_nearest   text := coldfront._vec_nearest_expr('temp.main.cf_gen c', quote_ident(p_column));
BEGIN
    PERFORM coldfront._reject_on_standby('train vector centroids');

    SELECT iceberg_table, is_writable INTO v_ice, v_writable
    FROM coldfront.tiered_views
    WHERE schema_name = p_schema AND relname = p_table;
    IF v_ice IS NULL THEN
        RAISE EXCEPTION 'coldfront.vector_train: "%.%" is not a registered tiered table',
            p_schema, p_table;
    END IF;
    IF NOT v_writable THEN
        RAISE EXCEPTION 'coldfront.vector_train: "%.%" is adopted read-only', p_schema, p_table
            USING HINT = 'Training rewrites the cold rows. Release it and adopt again with p_writable => true.';
    END IF;

    SELECT COALESCE(p_nlist, nlist), nlist, generation INTO v_nlist, v_cfg_nlist, v_gen
    FROM coldfront.vector_config
    WHERE schema_name = p_schema AND table_name = p_table AND column_name = p_column;
    IF v_nlist IS NULL THEN
        RAISE EXCEPTION 'coldfront.vector_train: no configuration for "%.%"."%"',
            p_schema, p_table, p_column
            USING HINT = 'INSERT a coldfront.vector_config row first: it holds the '
                         'generation pointer this writes, so p_nlist alone is not enough.';
    END IF;

    SET LOCAL duckdb.unsafe_allow_mixed_transactions = on;
    PERFORM coldfront.ensure_attached();
    PERFORM coldfront._take_iceberg_claim(v_ice);

    -- The sample. Its seed is fixed so a retrain on unchanged data reproduces the
    -- same centroids.
    PERFORM duckdb.raw_query(format(
        'CREATE OR REPLACE TEMP TABLE cf_samp AS '
        'SELECT row_number() OVER () AS id, v FROM ('
        '  SELECT %I AS v FROM %s WHERE %I IS NOT NULL '
        '  USING SAMPLE reservoir(%s ROWS) REPEATABLE (42))',
        p_column, v_ice, p_column, p_sample));

    SELECT r['n']::int, r['d']::int INTO v_n, v_dim
    FROM duckdb.query('SELECT count(*) AS n, max(len(v)) AS d FROM temp.main.cf_samp') AS t(r);
    IF COALESCE(v_n, 0) = 0 THEN
        RAISE EXCEPTION 'coldfront.vector_train: "%.%"."%" has no cold rows to train on',
            p_schema, p_table, p_column;
    END IF;

    IF v_gen > 0 AND v_nlist = v_cfg_nlist THEN
        -- The live centroids are the seeds: same ids, and the iterations then
        -- move each one with its data.
        PERFORM coldfront.ensure_pg_attached();
        PERFORM duckdb.raw_query(format(
            'CREATE OR REPLACE TEMP TABLE cf_cent AS '
            'SELECT centroid_id AS cid, centroid AS v FROM pglocal.coldfront.vector_centroids '
            'WHERE schema_name = %L AND table_name = %L AND column_name = %L AND generation = %s',
            p_schema, p_table, p_column, v_gen));
    ELSE
        PERFORM coldfront._vec_seed_kmeanspp(v_nlist);
    END IF;
    PERFORM coldfront._vec_lloyd(p_iterations, v_dim);

    -- The generation as it is stored, in the columns the nearest-centroid
    -- expression reads. It is what the assignment below scores against: the set
    -- written to PostgreSQL in this transaction, which a read over pglocal could
    -- not see yet.
    PERFORM duckdb.raw_query(
        'CREATE OR REPLACE TEMP TABLE cf_gen AS '
        'SELECT cid::INTEGER AS centroid_id, v AS centroid FROM temp.main.cf_cent');

    -- The centroids land in a temporary heap first. A single INSERT reading a
    -- DuckDB scan is planned as a DuckDB statement, and DuckDB cannot write to a
    -- PostgreSQL table, so the read and the write have to be separate statements.
    -- The drop names pg_temp: an unqualified name would resolve through
    -- search_path and could hit a permanent table of the same name.
    IF to_regclass('pg_temp.cf_cent_pg') IS NOT NULL THEN
        DROP TABLE pg_temp.cf_cent_pg;
    END IF;
    CREATE TEMP TABLE cf_cent_pg ON COMMIT DROP AS
    SELECT r['centroid_id']::int AS centroid_id, r['centroid']::real[] AS centroid
    FROM duckdb.query('SELECT centroid_id, centroid FROM temp.main.cf_gen') AS t(r);

    -- A generation is immutable, so this writes a new one and moves the pointer.
    v_gen := COALESCE(v_gen, 0) + 1;
    INSERT INTO coldfront.vector_centroids
        (schema_name, table_name, column_name, generation, centroid_id, centroid)
    SELECT p_schema, p_table, p_column, v_gen, centroid_id, centroid FROM cf_cent_pg;

    GET DIAGNOSTICS v_n = ROW_COUNT;
    -- The trained count can fall below the configured nprobe (empty clusters do
    -- not come back from the mean); clamp it in the same statement or the row
    -- would fail vc_nprobe_fit and abort the whole training transaction.
    UPDATE coldfront.vector_config
       SET generation = v_gen, nlist = v_n, nprobe = LEAST(nprobe, v_n)
     WHERE schema_name = p_schema AND table_name = p_table AND column_name = p_column;

    -- The corpus, assigned: the loop's final step applied to the table rather than
    -- the sample. Only a row whose cluster changed is rewritten, and a row with no
    -- cluster counts as changed. The pointer and the assignments commit together.
    -- What it leaves behind is a merge-on-read delete per rewritten row, and those
    -- rows in update order rather than cluster order; compaction resolves both.
    PERFORM coldfront._exec_iceberg_with_claim(v_ice, format(
        'UPDATE %s SET %s = %s WHERE %s IS DISTINCT FROM %s',
        v_ice, v_col, v_nearest, v_col, v_nearest));

    RAISE NOTICE 'coldfront: trained % centroids for "%.%"."%" as generation % and assigned the cold rows; compact the table to apply the deletes and restore cluster order',
        v_n, p_schema, p_table, p_column, v_gen;
END;
$$;

-- What a decision about a clustered column needs, and nothing else available.
--
-- The headline is probe_fraction: the share of the corpus a probe reads on
-- average, which is the cost the whole layout exists to lower. Everything beside
-- it is there to explain that number when it is disappointing. rows_unassigned is
-- the part no probe can skip, because a row with no cluster is read by every one
-- of them. clusters_below_row_group counts occupied clusters holding fewer rows
-- than a row group: past that point extra clusters cut the rows scored without
-- cutting the rows read, which is the measured floor on nlist and the reason it is
-- a floor rather than a formula.
--
-- Deliberately absent: file count, bytes, and row-group structure. Reaching those
-- means resolving a table's metadata location, which is a Lakekeeper HTTP call,
-- and the SQL layer does not make HTTP calls. The compactor already reports files
-- and bytes on every pass, and file count is the wrong health signal anyway: a
-- merge bounds it without changing what a probe reads.
--
-- A PROCEDURE writing a temporary table, for the same reason vector_train is one:
-- pg_duckdb refuses to execute a DuckDB query inside a function, and a single
-- INSERT ... SELECT over a DuckDB scan is planned as DuckDB's, which cannot write
-- a PostgreSQL table. Nothing is staged on the way, though: DuckDB aggregates the
-- distribution and hands back one row (see the EXECUTE below).
CREATE PROCEDURE coldfront.vector_status(
    p_schema text DEFAULT NULL,
    p_table  text DEFAULT NULL
)
LANGUAGE plpgsql AS $$
DECLARE
    vt        record;
    v_schemas text[];
    v_names   text[];
    v_cols    text[];
    v_rows    bigint;
    v_unasg   bigint;
    v_occ     int;
    v_min     bigint;
    v_max     bigint;
    v_p50     bigint;
    v_p99     bigint;
    v_floor   int;
    v_trained int;
    v_added   int;
    v_i       int;
BEGIN
    -- Dropped by name only when it is there. IF EXISTS would do the same and add a
    -- NOTICE to every caller's output for the ordinary case of a first call.
    IF to_regclass('pg_temp.cf_vector_status') IS NOT NULL THEN
        DROP TABLE pg_temp.cf_vector_status;
    END IF;
    CREATE TEMP TABLE cf_vector_status (
        schema_name          text,
        table_name           text,
        column_name          text,
        -- False for a table's second and later vector columns: their probe filters
        -- the rows it scores but prunes no row groups, so their probe_fraction is
        -- what they score rather than what they read.
        prunes               boolean,
        generation           int,
        nlist                int,
        nprobe               int,
        clusters_trained     int,
        clusters_occupied    int,
        additions            int,
        addition_cap         int,
        rows_total           bigint,
        rows_unassigned      bigint,
        rows_per_cluster_min bigint,
        rows_per_cluster_max bigint,
        -- The pair a query's cost is actually bounded by. min/max are reported
        -- because they are free, but max/min is not a health signal: one tiny
        -- cluster sets it, and a real corpus has one.
        rows_per_cluster_p50 bigint,
        rows_per_cluster_p99 bigint,
        clusters_below_row_group int,
        probe_fraction       numeric,
        advice               text
    );
    -- Session lifetime, not ON COMMIT DROP: a bare CALL is its own transaction, so
    -- a table dropped at commit would be gone before the caller could select from
    -- it. Re-running the procedure replaces it.

    SET LOCAL duckdb.unsafe_allow_mixed_transactions = on;
    PERFORM coldfront.ensure_attached();

    -- The work list is a pair of key arrays walked by index, not a query the loop
    -- iterates: a plpgsql FOR over a query holds a portal open for its body, and
    -- pg_duckdb refuses a DuckDB read while one is ("DuckDB execution is not
    -- supported inside functions"). An integer loop opens none.
    -- One entry per (table, vector column), since a table may carry several and each
    -- has its own centroids, generation and distribution.
    SELECT array_agg(k.schema_name ORDER BY k.schema_name, k.relname, k.ord),
           array_agg(k.relname     ORDER BY k.schema_name, k.relname, k.ord),
           array_agg(k.col         ORDER BY k.schema_name, k.relname, k.ord)
      INTO v_schemas, v_names, v_cols
      FROM (SELECT tv.schema_name, tv.relname, c.col, c.ord
              FROM coldfront.tiered_views tv
              CROSS JOIN LATERAL unnest(tv.vec_columns) WITH ORDINALITY AS c(col, ord)
             WHERE tv.vec_columns IS NOT NULL
               AND (p_schema IS NULL OR tv.schema_name = p_schema)
               AND (p_table  IS NULL OR tv.relname     = p_table)) k;

    FOR v_i IN 1 .. COALESCE(array_length(v_schemas, 1), 0) LOOP
        SELECT tv.schema_name, tv.relname, v_cols[v_i] AS vec_column, tv.iceberg_table,
               vc.nlist, vc.nprobe, NULLIF(vc.generation, 0) AS generation,
               vc.addition_cap,
               v_cols[v_i] = tv.vec_columns[1] AS prunes
          INTO vt
          FROM coldfront.tiered_views tv
          LEFT JOIN coldfront.vector_config vc
                 ON vc.schema_name = tv.schema_name
                AND vc.table_name  = tv.relname
                AND vc.column_name = v_cols[v_i]
         WHERE tv.schema_name = v_schemas[v_i] AND tv.relname = v_names[v_i];

        -- One pass over the cold table: DuckDB groups by cluster and aggregates the
        -- grouping, so what crosses back is a single row of scalars.
        --
        -- Through EXECUTE because the table name is dynamic and duckdb.query needs a
        -- constant at plan time, not a literal in the source. Staging the grouping in
        -- a DuckDB table the way vector_train stages its centroids would work here
        -- too, but it is a table to name, drop and read back for a result that fits
        -- in one row.
        EXECUTE format(
            'SELECT t.r[%L]::bigint, t.r[%L]::bigint, t.r[%L]::int, '
                   't.r[%L]::bigint, t.r[%L]::bigint, t.r[%L]::bigint, '
                   't.r[%L]::bigint, t.r[%L]::int '
              'FROM duckdb.query(%L) AS t(r)',
            'rows_total', 'rows_unasg', 'occupied', 'min_n', 'max_n',
            'p50_n', 'p99_n', 'below',
            format(
                'WITH d AS (SELECT %I AS cl, count(*) AS n FROM %s GROUP BY 1) '
                'SELECT coalesce(sum(n), 0) AS rows_total, '
                       'coalesce(sum(n) FILTER (WHERE cl IS NULL), 0) AS rows_unasg, '
                       'count(*) FILTER (WHERE cl IS NOT NULL) AS occupied, '
                       'min(n) FILTER (WHERE cl IS NOT NULL) AS min_n, '
                       'max(n) FILTER (WHERE cl IS NOT NULL) AS max_n, '
                       'quantile_cont(n, 0.5) FILTER (WHERE cl IS NOT NULL) AS p50_n, '
                       'quantile_cont(n, 0.99) FILTER (WHERE cl IS NOT NULL) AS p99_n, '
                       'count(*) FILTER (WHERE cl IS NOT NULL AND n < ' || coldfront._vec_row_group_limit() || ') AS below '
                  'FROM d',
                coldfront._vec_list_col(vt.vec_column), vt.iceberg_table))
          INTO v_rows, v_unasg, v_occ, v_min, v_max, v_p50, v_p99, v_floor;

        SELECT count(*), count(*) FILTER (WHERE parent_id IS NOT NULL)
          INTO v_trained, v_added
          FROM coldfront.vector_centroids c
         WHERE c.schema_name = vt.schema_name AND c.table_name = vt.relname
           AND c.column_name = vt.vec_column AND c.generation = vt.generation;

        INSERT INTO cf_vector_status (
            schema_name, table_name, column_name, prunes,
            generation, nlist, nprobe,
            clusters_trained, clusters_occupied, additions, addition_cap,
            rows_total, rows_unassigned,
            rows_per_cluster_min, rows_per_cluster_max,
            rows_per_cluster_p50, rows_per_cluster_p99,
            clusters_below_row_group, probe_fraction, advice
        ) VALUES (
            vt.schema_name, vt.relname, vt.vec_column, vt.prunes,
            vt.generation, vt.nlist, vt.nprobe,
            v_trained, v_occ, v_added, vt.addition_cap,
            v_rows, v_unasg, v_min, v_max, v_p50, v_p99, v_floor,
            -- What a probe reads on average: its share of the occupied clusters,
            -- plus every unassigned row, which it always reads.
            CASE WHEN v_rows = 0 THEN NULL
                 ELSE round(LEAST(1.0, (
                     COALESCE(LEAST(vt.nprobe, v_occ)::numeric / NULLIF(v_occ, 0), 1)
                       * (v_rows - v_unasg) + v_unasg) / v_rows), 4)
            END,
            CASE
                WHEN vt.generation IS NULL THEN
                    'no trained generation: every row is unassigned and every probe reads the whole table'
                WHEN v_rows > 0 AND v_unasg::numeric / v_rows > 0.5 THEN
                    'over half the rows have no assignment, and a probe reads all of them'
                WHEN v_occ > 0 AND v_floor::numeric / v_occ > 0.5 THEN
                    'over half the occupied clusters hold less than one row group: retrain with a smaller nlist'
                -- Against the median, not the minimum: one tiny cluster sets max/min
                -- and every real corpus has one, so a rule on max/min fires on every
                -- table. The upper tail against the typical case is what a query
                -- landing in a large cluster actually pays.
                WHEN v_p50 IS NOT NULL AND v_p50 > 0 AND v_p99 > v_p50 * 4 THEN
                    'the largest clusters hold over 4x the median, so a query landing '
                    'in one reads that much more than probe_fraction suggests'
            END);
    END LOOP;

    IF NOT EXISTS (SELECT 1 FROM cf_vector_status) THEN
        RAISE NOTICE 'coldfront: no registered table has a clustered vector column';
    END IF;
END;
$$;

-- The distance operators a caller writes, on the real[] the view exposes.
--
-- Each function is named for the DuckDB function it has to become: pg_duckdb
-- resolves an operator by its implementing function's NAME in DuckDB's catalog, so
-- the cold side gets DuckDB's own list_cosine_distance / list_distance /
-- list_negative_inner_product. The PostgreSQL bodies are real implementations, not
-- stubs, because a read that stays in PostgreSQL executes them: they delegate to
-- pgvector, which is exact and SIMD-accelerated, rather than hand-rolling the
-- arithmetic. Scoring a query vector against the centroid table goes through the
-- same functions, so a probe and an assignment cannot disagree on the metric.
--
-- They are created in pgvector's own schema, whatever that is. A caller who has a
-- vector column has that schema on their search_path already, so `<=>` resolves
-- unqualified without ColdFront claiming public. Installed at onboarding rather
-- than at CREATE EXTENSION, since pgvector need not be present until a table
-- actually carries a vector.
CREATE OR REPLACE FUNCTION coldfront.install_vector_ops()
RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
    v_nsp  text;
    r      record;
BEGIN
    SELECT n.nspname INTO v_nsp
    FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace
    WHERE t.typname = 'vector';

    -- Install pgvector rather than demand it. A tiered table cannot have declared a
    -- vector column without it, but a decoupled table names its types in jsonb, so
    -- the type need never have existed until now.
    IF v_nsp IS NULL THEN
        CREATE EXTENSION IF NOT EXISTS vector;
        SELECT n.nspname INTO v_nsp
        FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace
        WHERE t.typname = 'vector';
    END IF;
    IF v_nsp IS NULL THEN
        RAISE EXCEPTION 'coldfront: pgvector is required for a vector column and could not be installed'
            USING HINT = 'Install the pgvector package, then CREATE EXTENSION vector;';
    END IF;

    FOR r IN
        SELECT * FROM (VALUES
            ('list_cosine_distance',          '<=>'),
            ('list_distance',                 '<->'),
            ('list_negative_inner_product',   '<#>')
        ) AS v(fn, op)
    LOOP
        EXECUTE format(
            'CREATE OR REPLACE FUNCTION %I.%I(real[], real[]) RETURNS double precision '
            'LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE AS '
            '$fn$ SELECT $1::%I.vector OPERATOR(%I.%s) $2::%I.vector $fn$',
            v_nsp, r.fn, v_nsp, v_nsp, r.op, v_nsp);

        IF NOT EXISTS (
            SELECT 1 FROM pg_operator o
            JOIN pg_namespace n ON n.oid = o.oprnamespace
            WHERE o.oprname = r.op
              AND n.nspname = v_nsp
              AND o.oprleft  = 'real[]'::regtype
              AND o.oprright = 'real[]'::regtype)
        THEN
            EXECUTE format(
                'CREATE OPERATOR %I.%s (LEFTARG = real[], RIGHTARG = real[], FUNCTION = %I.%I)',
                v_nsp, r.op, v_nsp, r.fn);
        END IF;
    END LOOP;
END;
$$;

-- The hot-side column a vector is read through. pg_duckdb rejects a pgvector
-- column while it builds the plan, before a cast in the projection can apply, so
-- the hot table carries a generated real[] column and every hot-side read goes
-- through that. The archiver derives the same name in Go (vecCompanion); the two
-- have to agree or the view reads a column that is not there.
CREATE OR REPLACE FUNCTION coldfront._vec_companion(p_col text)
RETURNS text
LANGUAGE sql IMMUTABLE STRICT AS $$
    SELECT '_cf_vec_' || p_col;
$$;

-- True for the generated column above. It belongs to the hot table alone, so no
-- column list describing the user's table includes it: not the Iceberg schema, not
-- the view's projection, not an INSERT's column list (a generated column cannot be
-- written). starts_with rather than LIKE, since the prefix is full of underscores.
CREATE OR REPLACE FUNCTION coldfront._is_vec_companion(p_attname name, p_attgenerated "char")
RETURNS boolean
LANGUAGE sql IMMUTABLE STRICT AS $$
    SELECT p_attgenerated <> '' AND starts_with(p_attname::text, coldfront._vec_companion(''));
$$;

-- The Iceberg-only column carrying a row's cluster assignment for one vector
-- column. It is in the Iceberg schema and nowhere else: not on the hot table, not
-- in either branch of the view, so no query written against the view can name it.
-- view.VecListColumn is the Go twin.
--
-- Named after the column it describes, because a table may carry several vector
-- columns and each needs its own assignment. The read-path rewrite derives this
-- name from whichever column a query orders by, so it is the contract between the
-- writer and the reader rather than an internal detail.
--
-- These lead the schema rather than trailing it. Iceberg evolution appends, and a
-- cold INSERT is positional because Iceberg rejects a targeted one, so a column
-- added later has to land after everything both sides already agree on.
--
-- The prefix extends _cf_vec_, which _is_vec_companion matches. There is no
-- collision: a companion is a generated column on the hot heap and a cluster column
-- exists only in Iceberg, so the two never appear in one relation.
CREATE OR REPLACE FUNCTION coldfront._vec_list_col(p_column text)
RETURNS text
LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE AS $$
    SELECT '_cf_vec_list_' || p_column;
$$;

-- The table's vector columns in Iceberg-schema order, or an empty array when it has
-- none. One lookup so no generator reads the registry column directly and they
-- cannot disagree on the order, which a positional cold write depends on.
CREATE OR REPLACE FUNCTION coldfront._vec_columns(p_schema text, p_table text)
RETURNS text[]
LANGUAGE sql STABLE AS $$
    SELECT COALESCE(tv.vec_columns, '{}')
      FROM coldfront.tiered_views tv
     WHERE tv.schema_name = p_schema AND tv.relname = p_table;
$$;

-- The one whose probe prunes: the first vector column, or NULL when there is none.
CREATE OR REPLACE FUNCTION coldfront._vec_sorted_column(p_schema text, p_table text)
RETURNS text
LANGUAGE sql STABLE AS $$
    SELECT (coldfront._vec_columns(p_schema, p_table))[1];
$$;

-- True when a column-type list contains a vector, which is what decides whether a
-- cold write has to attach pglocal at all: only the cluster lookup reads it, so a
-- table without a vector must not pay for the attach.
CREATE OR REPLACE FUNCTION coldfront._types_have_vector(p_types text[])
RETURNS boolean
LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE AS $$
    SELECT EXISTS (SELECT 1 FROM unnest(p_types) t WHERE coldfront._is_vector_type(t));
$$;

-- The one place a cluster assignment is defined. Given the text of an expression
-- yielding the vector as DuckDB sees it, returns the DuckDB expression that
-- assigns the cluster. Every cold write path emits this and none derives its own,
-- because a row whose cluster disagrees with its vector is invisible to its own
-- search and reports no error.
--
-- Two properties are deliberate. The centroids are read over pglocal, so the
-- PostgreSQL table is the only copy and no path has to inline a centroid set or
-- keep a session copy it has no way to check. And the generation is resolved by
-- the emitted SQL rather than baked into it, so a statement generated once (a
-- trigger body) keeps assigning against the live generation after a retrain
-- instead of filtering on a generation that no longer exists.
--
-- Before any training the config carries no generation, the inner query matches
-- nothing, and the expression yields NULL: unassigned, which a probe reads
-- through the null arm of its predicate rather than missing. A retrain cannot
-- interleave with a cold write, since vector_train holds the table's claim from
-- its sample to its commit and every cold write serialises on that same claim.
--
-- The formula itself is _vec_nearest_expr, shared with vector_train, which scores
-- the generation it has just trained from its own session: one formula, so a
-- write and the training can never disagree on a cluster.
CREATE OR REPLACE FUNCTION coldfront._vec_nearest_expr(p_from text, p_vec_expr text)
RETURNS text
LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE AS $$
    SELECT format('(SELECT arg_min(c.centroid_id, list_cosine_distance(c.centroid, %s)) FROM %s)',
                  p_vec_expr, p_from);
$$;

CREATE OR REPLACE FUNCTION coldfront._vec_list_expr(
    p_schema text, p_table text, p_column text, p_vec_expr text)
RETURNS text
LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE AS $$
    SELECT coldfront._vec_nearest_expr(format(
        'pglocal.coldfront.vector_centroids c '
        'WHERE c.schema_name = %L AND c.table_name = %L AND c.column_name = %L '
          'AND c.generation = (SELECT vc.generation FROM pglocal.coldfront.vector_config vc '
                              'WHERE vc.schema_name = %L AND vc.table_name = %L '
                                'AND vc.column_name = %L)',
        p_schema, p_table, p_column, p_schema, p_table, p_column), p_vec_expr);
$$;

-- The cluster columns for an Iceberg ref, quoted and comma-joined in schema order.
-- A targeted cold INSERT names them, so the order has to match the expressions
-- _vec_list_prefix_for_ref emits beside it.
CREATE OR REPLACE FUNCTION coldfront._vec_list_cols_for_ref(p_iceberg_ref text)
RETURNS text
LANGUAGE sql STABLE AS $$
    SELECT string_agg(quote_ident(coldfront._vec_list_col(c)), ', ' ORDER BY u.ord)
      FROM coldfront.tiered_views tv
      CROSS JOIN LATERAL unnest(tv.vec_columns) WITH ORDINALITY AS u(c, ord)
     WHERE tv.iceberg_table = p_iceberg_ref;
$$;

-- The same, for a caller holding the Iceberg ref rather than the view's name: the
-- C rewrite and the archiver's replay drain both know the ref they are writing to.
CREATE OR REPLACE FUNCTION coldfront._vec_list_prefix_for_ref(
    p_iceberg_ref text, p_alias text)
RETURNS text
LANGUAGE sql STABLE AS $$
    SELECT coldfront._vec_list_prefix(tv.schema_name, tv.relname, tv.vec_columns,
               ARRAY(SELECT p_alias || quote_ident(c) FROM unnest(tv.vec_columns) c))
      FROM coldfront.tiered_views tv
     WHERE tv.iceberg_table = p_iceberg_ref AND tv.vec_columns IS NOT NULL;
$$;

-- The row-group size a clustered layout is built around, in rows: the pruning
-- granule. One definition, because the writer is told this number
-- (_vec_layout_props) and vector_status's floor advice measures clusters against
-- it; disagreeing would mistune exactly the signal the advice exists to give.
CREATE OR REPLACE FUNCTION coldfront._vec_row_group_limit()
RETURNS int
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
    SELECT 2048;
$$;

-- The Iceberg table properties a clustered table is created with, as a CREATE
-- TABLE WITH clause, or '' for a table with no vector column.
--
-- Row groups are the pruning granularity, and the reader skips them on the cluster
-- column's statistics. The row count is what cuts them here, and it is read by
-- iceberg-go alone: DuckDB reads only write.parquet.row-group-size-bytes, and
-- setting that makes DuckDB refuse every write to the table ("does not work while
-- preserving insertion order"). So a trickle write lands one row group per file
-- and compaction is what establishes the layout, which is the division of labour
-- the compactor already has: it creates nothing, it preserves what it finds.
--
-- The file target is large because on object storage every file a query touches is
-- a billed round trip. A partitioned table is created without it: DuckDB refuses
-- the property on a partitioned table, and would not split its files by size
-- there anyway; the compactor takes its target from --target-size-mb. The sort
-- key is what lets a compaction concatenate a group's files in key order rather
-- than scrambling them.
--
-- Set at CREATE TABLE: the catalog takes properties there, and ColdFront never
-- alters them afterwards, so a table that predates its vector column keeps the
-- defaults.
CREATE OR REPLACE FUNCTION coldfront._vec_layout_props(p_sort_key text, p_partitioned boolean)
RETURNS text
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
    SELECT CASE WHEN p_sort_key IS NULL OR p_sort_key = '' THEN ''
                ELSE format(
                    ' WITH (%L=%L, %s%L=%L)',
                    'write.parquet.row-group-limit',      coldfront._vec_row_group_limit()::text,
                    CASE WHEN p_partitioned THEN ''
                         ELSE format('%L=%L, ', 'write.target-file-size-bytes', '536870912') END,
                    'coldfront.sort-key',                 p_sort_key)
           END;
$$;

-- The sort key for a clustered table: one cluster column first, since that is what
-- prunes, then the primary key as a tiebreak for determinism. The pk is not a
-- pruning aid; sorting by cluster scatters a cluster's rows through id space.
--
-- One vector column gets this and the rest do not, because a Parquet file has a
-- single physical row order. Ordering by a second cluster column after the first
-- would scatter its values inside every band of the first, leaving its row-group
-- statistics bounding the whole file. So a second vector column's probe filters the
-- rows it scores and prunes nothing.
CREATE OR REPLACE FUNCTION coldfront._vec_sort_key(p_column text, p_pk_cols text[])
RETURNS text
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
    SELECT CASE WHEN p_column IS NULL THEN NULL
                ELSE concat_ws(',', coldfront._vec_list_col(p_column),
                               NULLIF(array_to_string(COALESCE(p_pk_cols, '{}'), ','), ''))
           END;
$$;

-- The SET item a cold UPDATE adds when it sets the embedding, or NULL when the
-- table has no clustered vector column. A row whose embedding changes while its
-- cluster does not is permanently invisible to its own probe, silently, so this
-- rides in the same statement rather than in a follow-up.
CREATE OR REPLACE FUNCTION coldfront._vec_list_set_item(
    p_iceberg_ref text, p_column text, p_vec_expr text)
RETURNS text
LANGUAGE sql STABLE AS $$
    SELECT quote_ident(coldfront._vec_list_col(p_column)) || ' = '
        || coldfront._vec_list_expr(tv.schema_name, tv.relname, p_column, p_vec_expr)
      FROM coldfront.tiered_views tv
     WHERE tv.iceberg_table = p_iceberg_ref
       AND p_column = ANY (coldfront._vec_columns(tv.schema_name, tv.relname));
$$;

-- The leading entries every positional cold write needs, one per vector column in
-- the order the Iceberg schema declares them, or '' for a table with no vector
-- column. A cold INSERT supplies values by position, so a prefix short of the
-- schema's cluster columns would land every following value in the wrong column.
-- That is why a length mismatch between the two arrays is an error and not a
-- best-effort join: the caller has lost track of its own column list.
CREATE OR REPLACE FUNCTION coldfront._vec_list_prefix(
    p_schema text, p_table text, p_columns text[], p_vec_exprs text[])
RETURNS text
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
    v_out text := '';
    i     int;
BEGIN
    IF p_columns IS NULL OR cardinality(p_columns) = 0 THEN
        RETURN '';
    END IF;
    IF cardinality(p_columns) <> cardinality(COALESCE(p_vec_exprs, '{}')) THEN
        RAISE EXCEPTION 'coldfront: % vector column(s) but % expression(s)',
            cardinality(p_columns), cardinality(COALESCE(p_vec_exprs, '{}'));
    END IF;
    FOR i IN 1 .. cardinality(p_columns) LOOP
        v_out := v_out
              || coldfront._vec_list_expr(p_schema, p_table, p_columns[i], p_vec_exprs[i])
              || ', ';
    END LOOP;
    RETURN v_out;
END;
$$;

-- The probe set for one query vector: the ids of the nearest centroids in the live
-- generation, ascending, or NULL when there is nothing to probe against.
--
-- NULL is not a failure and this is the one place in the vector path that fails
-- open. A read that loses its predicate scans exactly, which is correct and is what
-- the product did before any of this existed; only a WRITE that cannot resolve a
-- generation has to fail, because a wrong cluster id makes a row invisible to its
-- own probe and says nothing. So an unconfigured table, an untrained one, and a
-- database whose distance shim was never installed all decline here.
--
-- Scored through that shim rather than in arithmetic here: it delegates to pgvector,
-- which is exact and SIMD-accelerated over the few hundred centroids a generation
-- holds, and it is the same function the assignment uses, so a probe cannot end up
-- on a different metric from the clusters it is searching.
--
-- Ascending ids, not distance order, because the predicate they become is a set
-- membership test: sorted ids make one generated qual for one probe set whatever
-- order the distances came back in.
CREATE OR REPLACE FUNCTION coldfront._vec_probe_ids(
    p_schema text, p_table text, p_column text, p_vec real[],
    p_nprobe int DEFAULT NULL)
RETURNS int[]
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_gen    int;
    v_nprobe int;
    v_fn     text;
    v_ids    int[];
BEGIN
    SELECT NULLIF(vc.generation, 0), COALESCE(p_nprobe, vc.nprobe)
      INTO v_gen, v_nprobe
      FROM coldfront.vector_config vc
     WHERE vc.schema_name = p_schema AND vc.table_name = p_table
       AND vc.column_name = p_column;
    IF v_gen IS NULL THEN
        RETURN NULL;
    END IF;

    -- install_vector_ops put this in pgvector's schema, wherever that is; its
    -- absence means no table here has ever carried a vector.
    SELECT p.oid::regproc::text INTO v_fn
      FROM pg_proc p
     WHERE p.proname = 'list_cosine_distance'
       AND p.pronargs = 2 AND p.proargtypes[0] = 'real[]'::regtype;
    IF v_fn IS NULL THEN
        RETURN NULL;
    END IF;

    EXECUTE format(
        'SELECT array_agg(s.centroid_id ORDER BY s.centroid_id) FROM ('
          'SELECT c.centroid_id FROM coldfront.vector_centroids c '
           'WHERE c.schema_name = $1 AND c.table_name = $2 AND c.column_name = $3 '
             'AND c.generation = $4 '
           'ORDER BY %s(c.centroid, $5) LIMIT $6) s', v_fn)
      INTO v_ids
     USING p_schema, p_table, p_column, v_gen, p_vec, v_nprobe;
    RETURN v_ids;
END;
$$;

-- The cluster column of p_column as the cold arm reads it. Cast, matching the
-- cutoff qual the view generator already emits: the subscript yields
-- duckdb.unresolved_type, and the cast is what makes a comparison on it an
-- integer comparison the Parquet reader can take.
CREATE OR REPLACE FUNCTION coldfront._vec_list_ref(p_column text, p_alias text DEFAULT 'r')
RETURNS text
LANGUAGE sql IMMUTABLE AS $$
    SELECT format('%s[%L]::integer', p_alias, coldfront._vec_list_col(p_column));
$$;

-- The predicate a probe set becomes on the cold arm, or NULL for an empty set:
-- an IN, which DuckDB pushes into the scan and checks against the manifest
-- bounds. The rows with no assignment are a second arm of the cold scan
-- (_vec_probed_viewdef), not an IS NULL here: DuckDB pushes an OR that carries
-- one to neither place.
CREATE OR REPLACE FUNCTION coldfront._vec_probe_qual(
    p_column text, p_ids int[], p_alias text DEFAULT 'r')
RETURNS text
LANGUAGE sql IMMUTABLE AS $$
    SELECT format('(%s IN (%s))',
                  coldfront._vec_list_ref(p_column, p_alias), array_to_string(p_ids, ', '))
     WHERE cardinality(p_ids) > 0;
$$;

-- The view's own definition with its cold arm probed, or NULL when there is no
-- cold arm to probe. The read rewrite substitutes this for the view reference,
-- and that substitution is what keeps the cluster column out of the view: the
-- predicate is added where the column already exists, instead of the view
-- exposing a column so a caller's query can name it.
--
-- The cold arm appears twice: once with the probe set, once with IS NULL on the
-- cluster column for the rows with no assignment. Two arms rather than one OR,
-- because DuckDB pushes the IN into the scan and to the manifest bounds but not
-- an OR that carries IS NULL, and the second arm reads only the files whose null
-- counts say they hold unassigned rows: nothing, when there are none.
--
-- Appended, not spliced. The generator puts the cold arm last and gives the view
-- neither ORDER BY nor LIMIT, so the end of the definition is the end of the cold
-- arm: of its WHERE for a tiered view, which always carries the cutoff qual, and of
-- its FROM for a decoupled one, which carries no qual at all. The registry says
-- which. A tiered view is one set operation, hot arm then cold arm, so its cold
-- arm is the text after the UNION ALL. The regress test's expected output locks
-- the shape.
--
-- A tiered view with no cutoff has no cold arm at all, only the hot heap, so there
-- is nothing to probe and the caller keeps its query.
CREATE OR REPLACE FUNCTION coldfront._vec_probed_viewdef(
    p_schema text, p_view text, p_column text, p_ids int[])
RETURNS text
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_iceberg_only boolean;
    v_has_cutoff   boolean;
    v_body         text;
    v_cold         text;
    v_probed       text;
    v_unassigned   text;
BEGIN
    v_probed := coldfront._vec_probe_qual(p_column, p_ids);
    IF v_probed IS NULL THEN
        RETURN NULL;
    END IF;

    SELECT tv.is_iceberg_only,
           EXISTS (SELECT 1 FROM coldfront.archive_watermark w
                    WHERE w.schema_name = p_schema AND w.table_name = p_view)
      INTO v_iceberg_only, v_has_cutoff
      FROM coldfront.tiered_views tv
     WHERE tv.schema_name = p_schema AND tv.relname = p_view
       AND tv.vec_columns IS NOT NULL;
    IF v_iceberg_only IS NULL OR NOT (v_iceberg_only OR v_has_cutoff) THEN
        RETURN NULL;
    END IF;

    v_body := rtrim(pg_get_viewdef(format('%I.%I', p_schema, p_view)::regclass),
                    E' \t\r\n;');
    v_unassigned := coldfront._vec_list_ref(p_column) || ' IS NULL';
    IF v_iceberg_only THEN
        RETURN format('%s WHERE %s UNION ALL %s WHERE %s',
                      v_body, v_probed, v_body, v_unassigned);
    END IF;
    v_cold := substring(v_body from '.*\n *UNION ALL\n(.*)$');
    RETURN format('%s AND %s UNION ALL %s AND %s',
                  v_body, v_probed, v_cold, v_unassigned);
END;
$$;

-- Cold-value rendering, shared so the write paths cannot disagree. DuckDB's list
-- cast accepts [1,2,3] and rejects PG's {1,2,3}, and whitespace between elements
-- is fine. A value taken from a jsonb payload is already bracketed: jsonb spells
-- a vector as a string and an array as a JSON array.

-- The literal for a value already serialised to text. Callers: _cold_row_literal,
-- reading a jsonb payload, and _render_cold_param, rendering a bound parameter
-- through its jsonb spelling.
CREATE OR REPLACE FUNCTION coldfront._render_cold_value(p_val_text text, p_pg_type text)
RETURNS text
LANGUAGE sql IMMUTABLE STRICT AS $$
    SELECT CASE
        -- An array is a DuckDB list of its elements, each rendered as a value of
        -- the element type, so no element's text is parsed twice. p_val_text is
        -- the array's jsonb spelling, whose escapes jsonb_array_elements_text
        -- undoes; DuckDB's VARCHAR-to-list cast would read \t and \n in it as the
        -- letters t and n. A list of string literals takes the column's type on
        -- INSERT, on UPDATE and in a comparison, as one string literal does.
        WHEN p_pg_type LIKE '%[]' THEN (
            SELECT '[' || coalesce(string_agg(coalesce(coldfront._render_cold_value(e, left(p_pg_type, -2)), 'NULL'),
                                              ', ' ORDER BY o), '') || ']'
              FROM jsonb_array_elements_text(p_val_text::jsonb) WITH ORDINALITY AS u(e, o))
        -- bytea arrives in the session's bytea_output, hex or escape, and bytea's
        -- own input reads either. DuckDB mis-parses PG's \x escape into a BLOB,
        -- so the bytes are rebuilt from their hex digits.
        WHEN p_pg_type = 'bytea' THEN format('from_hex(%L)', encode(p_val_text::bytea, 'hex'))
        -- The Iceberg column is FLOAT[]; without the cast the literal stays a
        -- VARCHAR and the INSERT fails.
        WHEN coldfront._is_vector_type(p_pg_type) THEN format('CAST(%L AS FLOAT[])', p_val_text)
        ELSE quote_literal(p_val_text)
    END;
$$;

-- Whether an array has the shape an Iceberg list holds: one dimension, numbered
-- from 1. NULL and an empty array have no dimension and pass.
CREATE FUNCTION coldfront._is_list(p anyarray)
RETURNS boolean
LANGUAGE sql IMMUTABLE AS $$
    SELECT array_ndims(p) IS NULL OR (array_ndims(p) = 1 AND array_lower(p, 1) = 1);
$$;

-- An array headed for the cold tier, refused unless it is a list. A cold write
-- renders an array through its jsonb spelling, which keeps no lower bound, so
-- the shape is checked here, while the value is still an array. p_col names the
-- column, or is NULL for a bound parameter.
CREATE FUNCTION coldfront._cold_list(p anyarray, p_col text)
RETURNS anyarray
LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
    IF NOT coldfront._is_list(p) THEN
        RAISE EXCEPTION 'coldfront: % holds an array of % dimension(s) starting at element %; the cold tier stores one-dimensional arrays starting at element 1',
            CASE WHEN p_col IS NULL THEN 'a bound parameter' ELSE format('column "%s"', p_col) END,
            array_ndims(p), array_lower(p, 1);
    END IF;
    RETURN p;
END;
$$;

-- A bound array parameter of a cold write as the DuckDB list _render_cold_value
-- makes of an array column. The C hook's cold_sql_arg calls this at execution.
CREATE FUNCTION coldfront._render_cold_param(p anyarray)
RETURNS text
LANGUAGE sql STABLE AS $$
    SELECT coalesce(coldfront._render_cold_value(to_jsonb(coldfront._cold_list(p, NULL))::text,
                                                 pg_typeof(p)::text),
                    'NULL');
$$;

-- Map a PG type name (canonical or common alias) to the DuckDB/Iceberg
-- storage type used in CREATE TABLE on the attached catalog. Raises on any
-- type that cannot round-trip cleanly — silent VARCHAR fallback would lose
-- data identity at write time, so we refuse it.
--
-- p_column names the column in the refusal when the caller knows it.
CREATE OR REPLACE FUNCTION coldfront._iceberg_storage_type(p_pg_type text, p_column text DEFAULT '')
RETURNS text
LANGUAGE plpgsql IMMUTABLE STRICT AS $$
DECLARE
    t      text := lower(trim(p_pg_type));
    v_col  text := CASE WHEN p_column <> '' THEN format('column "%s": ', p_column) ELSE '' END;
    v_elem text;
BEGIN
    -- A one-dimensional array of a native type stores as an Iceberg list of the
    -- element's storage type. format_type spells an array type as its element
    -- type's spelling followed by [], so the element is the name without its
    -- last [] and maps as a column of its own would; an element the map refuses
    -- refuses the array. First, because the scalar rules below would read
    -- character varying(8)[] as a varchar and vector(3)[] as a vector.
    IF t LIKE '%[]' THEN
        v_elem := coldfront._iceberg_storage_type(left(t, -2), p_column);
        IF v_elem LIKE '%[]' THEN
            RAISE EXCEPTION 'coldfront: %PG type % has no Iceberg-compatible mapping: an array element cannot itself be an array or a vector', v_col, p_pg_type;
        END IF;
        IF v_elem = 'VARCHAR' AND coldfront._iceberg_view_cast_type(left(t, -2)) <> '' THEN
            RAISE EXCEPTION 'coldfront: %PG type % has no Iceberg-compatible mapping: % is stored as text and read back through a cast, which an array element does not get', v_col, p_pg_type, left(t, -2);
        END IF;
        -- pg_duckdb (c04e6a2) cannot read a timestamptz[] column, and every read
        -- of a tiered view after its first archive is a pg_duckdb scan of the hot
        -- table (pg_regress type_map).
        IF v_elem = 'TIMESTAMPTZ' THEN
            RAISE EXCEPTION 'coldfront: %PG type % has no Iceberg-compatible mapping: pg_duckdb cannot read a timestamptz[] column (store timestamp[] in UTC instead)', v_col, p_pg_type;
        END IF;
        RETURN v_elem || '[]';
    END IF;
    -- Numeric / boolean
    IF t IN ('bigint', 'int8')             THEN RETURN 'BIGINT';   END IF;
    IF t IN ('integer', 'int', 'int4')     THEN RETURN 'INTEGER';  END IF;
    -- Iceberg has no 16-bit integer; widen smallint to INTEGER (lossless).
    -- duckdb-iceberg rejects SMALLINT outright.
    IF t IN ('smallint', 'int2')           THEN RETURN 'INTEGER';  END IF;
    IF t IN ('real', 'float4')             THEN RETURN 'REAL';     END IF;
    IF t IN ('double precision', 'float8') THEN RETURN 'DOUBLE';   END IF;
    IF t IN ('boolean', 'bool')            THEN RETURN 'BOOLEAN';  END IF;
    -- Temporal
    IF t IN ('timestamp with time zone', 'timestamptz')   THEN RETURN 'TIMESTAMPTZ'; END IF;
    IF t IN ('timestamp without time zone', 'timestamp')  THEN RETURN 'TIMESTAMP';   END IF;
    IF t = 'date'                                          THEN RETURN 'DATE';        END IF;
    IF t IN ('time without time zone', 'time')            THEN RETURN 'TIME';        END IF;
    -- Identifiers / strings / binary
    IF t = 'uuid'  THEN RETURN 'UUID';    END IF;
    IF t = 'text'  THEN RETURN 'VARCHAR'; END IF;
    IF t = 'bytea' THEN RETURN 'BLOB';    END IF;
    -- Variable-precision strings
    IF t LIKE 'character varying%' OR t LIKE 'varchar%'
       OR t LIKE 'character(%' OR t LIKE 'char(%' OR t = 'character'
    THEN RETURN 'VARCHAR'; END IF;
    -- Bounded numeric
    IF t ~ '^numeric\(\d+\s*,\s*\d+\)$' OR t ~ '^decimal\(\d+\s*,\s*\d+\)$' THEN
        RETURN 'DECIMAL' || substring(t FROM '\(.*\)');
    END IF;
    IF t IN ('numeric', 'decimal') THEN
        RAISE EXCEPTION 'coldfront: %unbounded numeric not supported in iceberg; use numeric(P,S) with P<=38', v_col;
    END IF;
    -- View-cast types: stored as VARCHAR, surfaced via wrapper view as native PG type
    IF t IN ('jsonb', 'json', 'interval') THEN RETURN 'VARCHAR'; END IF;
    -- pgvector: both widen losslessly to float4 and store as list<float>.
    IF coldfront._is_vector_type(t) THEN RETURN 'FLOAT[]'; END IF;
    -- inet/cidr/oid are NOT supported: pg_duckdb rejects them (inet Oid 869,
    -- oid Oid 26) in any query it plans, and every Iceberg-backed view read is
    -- planned by pg_duckdb, so no cast makes them readable. Store IP data as
    -- text and oid values as bigint instead.

    RAISE EXCEPTION 'coldfront: %PG type % has no Iceberg-compatible mapping. Supported: bigint, integer, smallint, real, double precision, boolean, timestamptz, timestamp, date, time, uuid, text, varchar(N), char(N), bytea, numeric(P,S), jsonb, json, interval, vector(N), halfvec(N), and one-dimensional arrays of those types except timestamptz, jsonb, json, interval and the vector types. inet/cidr/oid unsupported (store IP data as text, oid values as bigint); sparsevec unsupported (keep it in the hot tier)', v_col, p_pg_type;
END;
$$;

-- The reverse of _iceberg_storage_type: the PostgreSQL type a wrapper view
-- exposes an existing Iceberg column as. adopt_iceberg_table reads its columns
-- from the catalog rather than from a caller's declaration, so this is what
-- turns a DESCRIBE row into a view projection.
--
-- Lossier than the forward map, because Iceberg records no PG type: several PG
-- types share one storage type, and a column comes back as whichever one that
-- storage type reads as natively. A jsonb column created by coldfront adopts
-- as text; adopt_iceberg_table's p_types restores it, accepted only when the
-- override maps to the observed storage type.
--
-- Two spellings reach here for the same type. _iceberg_storage_type returns
-- REAL and TIMESTAMPTZ and keeps the caller's DECIMAL whitespace, while DESCRIBE
-- returns FLOAT, TIMESTAMP WITH TIME ZONE and DECIMAL(P,S). Both are accepted
-- and both land on the same PG type, which is what makes the p_types comparison
-- (both sides run through this function) a comparison of types rather than of
-- spellings.
--
-- p_column names the column in the refusal when the caller knows it. DuckDB
-- loads and DESCRIBEs a struct, map, variant or nested list without complaint,
-- so this refusal is coldfront's and it is all the caller is told.
CREATE OR REPLACE FUNCTION coldfront._pg_type_from_iceberg(
    p_duckdb_type text,
    p_column      text DEFAULT ''
)
RETURNS text
LANGUAGE plpgsql IMMUTABLE STRICT AS $$
DECLARE
    t      text := upper(trim(p_duckdb_type));
    hint   text := 'Supported: BOOLEAN, INTEGER, BIGINT, FLOAT, DOUBLE, DECIMAL(P,S), '
                   'DATE, TIME, TIMESTAMP, TIMESTAMP WITH TIME ZONE, VARCHAR, UUID, '
                   'BLOB, and lists of those types except TIMESTAMP WITH TIME ZONE. '
                   'Leave the table where it is, or project the unsupported columns '
                   'away into an Iceberg view first.';
    v_elem text;
BEGIN
    -- A list reads as an array of its element's type. Whether a list<float> is a
    -- clustered vector column is decided by its cluster sibling, not by its type.
    -- A nested list and a list of timestamptz fall through to the refusal below,
    -- as the forward map refuses the arrays they would read as. An element with
    -- no mapping is refused by the inner call, in DESCRIBE's spelling.
    IF t LIKE '%[]' THEN
        v_elem := coldfront._pg_type_from_iceberg(left(trim(p_duckdb_type), -2), p_column);
        IF v_elem NOT LIKE '%[]' AND v_elem <> 'timestamptz' THEN
            RETURN v_elem || '[]';
        END IF;
    END IF;
    IF t = 'BOOLEAN'                 THEN RETURN 'boolean';          END IF;
    IF t = 'INTEGER'                 THEN RETURN 'integer';          END IF;
    IF t = 'BIGINT'                  THEN RETURN 'bigint';           END IF;
    -- DuckDB's 4-byte float is FLOAT from DESCRIBE and REAL from the forward map.
    IF t IN ('FLOAT', 'REAL')        THEN RETURN 'real';             END IF;
    IF t = 'DOUBLE'                  THEN RETURN 'double precision'; END IF;
    IF t = 'DATE'                    THEN RETURN 'date';             END IF;
    IF t = 'TIME'                    THEN RETURN 'time';             END IF;
    IF t = 'TIMESTAMP'               THEN RETURN 'timestamp';        END IF;
    IF t IN ('TIMESTAMP WITH TIME ZONE', 'TIMESTAMPTZ')
                                     THEN RETURN 'timestamptz';      END IF;
    IF t = 'VARCHAR'                 THEN RETURN 'text';             END IF;
    IF t = 'UUID'                    THEN RETURN 'uuid';             END IF;
    IF t = 'BLOB'                    THEN RETURN 'bytea';            END IF;
    -- Precision and scale are carried through, canonically spelled, so the two
    -- input spellings compare equal.
    IF t ~ '^DECIMAL\s*\(\s*\d+\s*,\s*\d+\s*\)$' THEN
        RETURN format('numeric(%s,%s)',
                      (regexp_match(t, '\(\s*(\d+)\s*,'))[1],
                      (regexp_match(t, ',\s*(\d+)\s*\)'))[1]);
    END IF;

    IF p_column <> '' THEN
        RAISE EXCEPTION 'coldfront: column "%" has Iceberg type %, which has no PostgreSQL mapping',
            p_column, p_duckdb_type USING HINT = hint;
    END IF;
    RAISE EXCEPTION 'coldfront: Iceberg type % has no PostgreSQL mapping', p_duckdb_type
        USING HINT = hint;
END;
$$;

-- For PG types that Iceberg can't represent natively (jsonb, interval, …)
-- the wrapper view casts the cold-side VARCHAR back to the rich PG type so
-- applications see it natively. Returns '' when storage already matches the
-- surface type.
CREATE OR REPLACE FUNCTION coldfront._iceberg_view_cast_type(p_pg_type text)
RETURNS text
LANGUAGE sql IMMUTABLE STRICT AS $$
    SELECT CASE
        -- An array reads as an array of its element's surface type. text is the
        -- one element that reads under another spelling than its column would:
        -- a text column reads as varchar, which every text operator accepts, but
        -- the array operators (=, @>, &&) take varchar[] and text[] as different
        -- types. First, because vector(3)[] would otherwise read as a vector.
        WHEN t LIKE '%[]' THEN CASE
            WHEN left(t, -2) = 'text' THEN 'text[]'
            WHEN coldfront._iceberg_view_cast_type(left(t, -2)) <> ''
                THEN coldfront._iceberg_view_cast_type(left(t, -2)) || '[]'
            ELSE ''
        END
        WHEN t IN ('jsonb', 'json') THEN 'json'  -- DuckDB has no jsonb, surface as json
        WHEN t = 'interval'         THEN 'interval'
        -- PG has no bare "double" type, so the view's cold cast r['col']::DOUBLE
        -- (the Iceberg storage name) won't parse. Surface via "double precision".
        WHEN t IN ('double precision', 'float8') THEN 'double precision'
        -- BLOB is not a PG-parseable cast name; surface bytea via "bytea".
        WHEN t = 'bytea'            THEN 'bytea'
        -- FLOAT[] would parse in PG as double precision[] (FLOAT is an alias),
        -- so the two branches would disagree on the column type. real[] is the
        -- one spelling both engines read as 4-byte floats.
        WHEN coldfront._is_vector_type(t) THEN 'real[]'
        -- Everything else (incl. smallint→INTEGER widening) has a storage type
        -- that is itself a PG-parseable surface; the view casts BOTH branches
        -- to that storage type, so no separate surface cast is needed and
        -- bootstrap/post-cutover view column types still agree.
        ELSE ''
    END
    FROM (SELECT lower(trim(p_pg_type))) AS s(t);
$$;

-- ============================================================================
-- The hot table's guards: a CHECK on each column of a tiered table's hot table
-- whose type admits a value the cold tier cannot hold unchanged, so the value is
-- refused where it is written instead of failing every archive pass that meets
-- it, or reaching the cold tier changed.
--
--   * numeric NaN. Two readers turn PostgreSQL rows into DuckDB rows: pg_duckdb's
--     scan, which plans every read of a tiered view after its first archive and
--     the archiver's bulk export, and DuckDB's postgres extension, which streams
--     the archive's delta replay. Both, at pg_duckdb c04e6a2 with DuckDB v1.5.4,
--     read a numeric NaN as 0 (pg_regress hot_guard, ci/journey.sh TC-234), and
--     Iceberg's decimal has no NaN to keep.
--   * date, timestamp and timestamptz infinity. Iceberg has none, and
--     duckdb-iceberg refuses to write one.
--   * an array that is not a list: more than one dimension, or a lower bound
--     other than 1. An Iceberg list has neither, and both readers drop a lower
--     bound (pg_regress hot_guard, ci/journey.sh TC-249). An array's elements
--     meet the condition of their scalar type.
--
-- The archiver adds the guards when it first tiers a partition of the table,
-- the DDL hook's view rebuild adds one for a column it adds, and unregistering
-- drops them.
-- ============================================================================

-- A guard's name, keyed on the column's name so every node of a mesh names a
-- column's guard alike, whichever node added it. A column name too long to
-- follow the prefix within a name's 63 bytes is replaced by a hash of it, so two
-- long names that begin alike name two guards. A guard is found by this
-- prefix and the column it constrains, which hold whatever its name.
CREATE FUNCTION coldfront._hot_guard_name(p_col name)
RETURNS name
LANGUAGE sql IMMUTABLE STRICT AS $$
    SELECT ('coldfront_guard_' || CASE WHEN octet_length(p_col) > 47
                                       THEN left(encode(sha256(convert_to(p_col, 'UTF8')), 'hex'), 32)
                                       ELSE p_col END)::name;
$$;

-- The condition a column's values must meet, or NULL when every value of its
-- type reaches the cold tier unchanged. p_pg_type is format_type output.
CREATE FUNCTION coldfront._hot_guard_check(p_col name, p_pg_type text)
RETURNS text
LANGUAGE sql IMMUTABLE STRICT AS $$
    SELECT CASE
        WHEN p_pg_type LIKE '%[]' THEN format('coldfront._is_list(%I)', p_col) || CASE
            WHEN p_pg_type LIKE 'numeric%' THEN format(' AND NOT (%I && ''{NaN}'')', p_col)
            WHEN p_pg_type LIKE 'date%' OR p_pg_type LIKE 'timestamp%'
                THEN format(' AND NOT (%I && ''{infinity,-infinity}'')', p_col)
            ELSE ''
        END
        WHEN p_pg_type LIKE 'numeric%' THEN format('%I <> ''NaN''', p_col)
        WHEN p_pg_type = 'date' OR p_pg_type LIKE 'timestamp%' THEN format('isfinite(%I)', p_col)
    END;
$$;

-- Adds each guard the hot table's columns need and lack. Rows written after it
-- are checked. p_validate checks the rows already there as each guard is added,
-- inside the caller's transaction and under its lock; without it the guard is
-- added NOT VALID, with no scan, and _validate_hot_guards checks those rows.
--
-- A column declared with more than one array dimension is refused here: no
-- guard can help it, because pg_duckdb reads a column by its declared
-- dimensions, and the cold tier stores one.
CREATE FUNCTION coldfront._guard_hot_table(p_hot regclass, p_validate boolean DEFAULT false)
RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
    r record;
BEGIN
    SELECT a.attname, a.attndims INTO r
      FROM pg_attribute a
     WHERE a.attrelid = p_hot AND a.attnum > 0 AND NOT a.attisdropped AND a.attndims > 1
     ORDER BY a.attnum LIMIT 1;
    IF FOUND THEN
        RAISE EXCEPTION 'coldfront: column "%" is declared with % array dimensions; pg_duckdb reads a column by its declared dimensions, and the cold tier stores one-dimensional arrays',
            r.attname, r.attndims;
    END IF;
    -- A rename leaves a guard named after its column's old name; it takes the
    -- new one here, which frees the old name for a column added under it.
    FOR r IN
        SELECT c.conname, coldfront._hot_guard_name(a.attname) AS want
          FROM pg_constraint c
          JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = c.conkey[1]
         WHERE c.conrelid = p_hot AND c.contype = 'c' AND cardinality(c.conkey) = 1
           AND starts_with(c.conname::text, coldfront._hot_guard_name(''))
           AND c.conname <> coldfront._hot_guard_name(a.attname)
    LOOP
        EXECUTE format('ALTER TABLE %s RENAME CONSTRAINT %I TO %I', p_hot, r.conname, r.want);
    END LOOP;
    FOR r IN
        SELECT a.attname, g.chk
          FROM pg_attribute a,
               LATERAL coldfront._hot_guard_check(a.attname, format_type(a.atttypid, a.atttypmod)) AS g(chk)
         WHERE a.attrelid = p_hot AND a.attnum > 0 AND NOT a.attisdropped
           AND g.chk IS NOT NULL
           AND NOT EXISTS (SELECT 1 FROM pg_constraint c
                            WHERE c.conrelid = p_hot AND c.contype = 'c'
                              AND c.conkey = ARRAY[a.attnum]
                              AND starts_with(c.conname::text, coldfront._hot_guard_name('')))
         ORDER BY a.attnum
    LOOP
        EXECUTE format('ALTER TABLE %s ADD CONSTRAINT %I CHECK (%s)%s',
                       p_hot, coldfront._hot_guard_name(r.attname), r.chk,
                       CASE WHEN p_validate THEN '' ELSE ' NOT VALID' END);
    END LOOP;
END;
$$;

-- Validates each guard of the hot table not yet validated. Validation scans the
-- table under a lock that lets reads and writes go on, so the caller runs this in
-- a transaction that holds no stronger lock on it. A row that breaks a guard
-- fails the call with PostgreSQL's error, which names the guard and through it
-- the column.
CREATE FUNCTION coldfront._validate_hot_guards(p_hot regclass)
RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
    v_guard name;
BEGIN
    FOR v_guard IN
        SELECT c.conname FROM pg_constraint c
         WHERE c.conrelid = p_hot AND c.contype = 'c' AND NOT c.convalidated
           AND starts_with(c.conname::text, coldfront._hot_guard_name(''))
         ORDER BY c.conname
    LOOP
        EXECUTE format('ALTER TABLE %s VALIDATE CONSTRAINT %I', p_hot, v_guard);
    END LOOP;
END;
$$;

-- The reference a table in the attached catalog is registered and claimed under.
-- Every part is quoted and embedded quotes are doubled, as pgx.Identifier.Sanitize
-- spells the archiver's and the compactor's, so an Iceberg table has one
-- reference whichever path registered it, and cold writes and the compactor
-- claim one key for it.
CREATE FUNCTION coldfront._iceberg_ref(p_namespace text, p_table text)
RETURNS text
LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE AS $$
    SELECT '"ice"."' || replace(p_namespace, '"', '""') || '"."' || replace(p_table, '"', '""') || '"';
$$;

-- The PostgreSQL half of registering a decoupled relation: the wrapper view over
-- an Iceberg table plus the registry row that arms the C hook on it. Both
-- create_iceberg_table and adopt_iceberg_table end here, so a created table and
-- an adopted one are the same thing to every path downstream.
--
--   p_columns  jsonb array of {name, cast} in Iceberg schema order, cluster
--              columns excluded: they exist only in Iceberg and no query written
--              against the view can name them. cast is the PG type the view
--              casts the column to, which is the type the column reads as.
--   p_vec_cols the vector columns those cluster columns belong to, or '{}'.
--   p_writable whether the hook rewrites DML on the view or refuses it.
--
-- The view reads the table as duckdb.query('SELECT * FROM <ref>'): the catalog's
-- table entry, whose scan includes the transaction's own pending data and
-- delete files, so a SELECT inside a transaction block sees the same
-- transaction's prior INSERT/UPDATE/DELETE. A tiered view's cold branch reads
-- the same way (_rebuild_tiered_view, internal/view/view.go).
CREATE OR REPLACE FUNCTION coldfront._register_iceberg_view(
    p_schema   text,
    p_relname  text,
    p_ice_ref  text,
    p_columns  jsonb,
    p_vec_cols text[],
    p_writable boolean
) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
    view_proj text;
BEGIN
    SELECT string_agg(format('r[%L]::%s AS %I', c->>'name', c->>'cast', c->>'name'),
                      ', ' ORDER BY ord)
      INTO view_proj
      FROM jsonb_array_elements(p_columns) WITH ORDINALITY AS u(c, ord);

    EXECUTE format(
        'CREATE OR REPLACE VIEW %I.%I AS SELECT %s FROM duckdb.query(%L) AS t(r)',
        p_schema, p_relname, view_proj,
        format('SELECT * FROM %s', p_ice_ref)
    );

    -- is_iceberg_only=true tells the C post_parse_analyze hook to short-circuit
    -- classify_tier to TIER_COLD for any INSERT/UPDATE/DELETE on this view, and
    -- is_writable decides whether it rewrites them at all.
    INSERT INTO coldfront.tiered_views (schema_name, relname, hot_table, iceberg_table, partition_col, is_iceberg_only, is_writable, vec_columns)
    VALUES (p_schema, p_relname, NULL, p_ice_ref, NULL, true, p_writable, NULLIF(p_vec_cols, '{}'))
    ON CONFLICT (schema_name, relname) DO UPDATE SET
        hot_table       = NULL,
        iceberg_table   = EXCLUDED.iceberg_table,
        partition_col   = NULL,
        is_iceberg_only = true,
        is_writable     = EXCLUDED.is_writable,
        vec_columns     = EXCLUDED.vec_columns;
END;
$$;

-- Validate the proposed wrapper name and Iceberg reference before describing
-- the Iceberg table or creating the view and registry row. Refuses a missing PG
-- schema, an occupied relation or Iceberg reference, or an unconfigured catalog.
CREATE OR REPLACE FUNCTION coldfront._adopt_preflight(
    p_schema   text,
    p_relname  text,
    p_ice_ref  text
) RETURNS void
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_reg_ref text;
    v_owner   text;
BEGIN
    -- The wrapper view lands in a PG schema, which the Iceberg namespace is not.
    IF to_regnamespace(quote_ident(p_schema)) IS NULL THEN
        RAISE EXCEPTION 'coldfront.adopt_iceberg_table: schema "%" does not exist', p_schema
            USING HINT = 'Adoption puts a wrapper view in that schema. Create it first, or adopt into one that exists; p_namespace names the Iceberg side.';
    END IF;

    -- Adoption binds a name once, whatever registration holds it: an adopted
    -- table is released before its name is adopted again, and a tiered table's
    -- cold tier is already managed.
    SELECT iceberg_table INTO v_reg_ref
      FROM coldfront.tiered_views
     WHERE schema_name = p_schema AND relname = p_relname;
    IF v_reg_ref IS NOT NULL THEN
        RAISE EXCEPTION 'coldfront.adopt_iceberg_table: "%.%" is already registered for %',
            p_schema, p_relname, v_reg_ref
            USING HINT = 'Adoption binds a name once. Release an adopted table with coldfront.release_iceberg_table() before adopting under its name again; a tiered table keeps its name.';
    END IF;

    IF to_regclass(format('%I.%I', p_schema, p_relname)) IS NOT NULL THEN
        RAISE EXCEPTION 'coldfront.adopt_iceberg_table: "%.%" already exists', p_schema, p_relname
            USING HINT = 'Adoption puts a wrapper view under that name. Adopt under another name, or move the existing relation aside first.';
    END IF;

    SELECT format('%s.%s', schema_name, relname) INTO v_owner
      FROM coldfront.tiered_views
     WHERE iceberg_table = p_ice_ref;
    IF v_owner IS NOT NULL THEN
        RAISE EXCEPTION 'coldfront.adopt_iceberg_table: % is already registered as "%"', p_ice_ref, v_owner
            USING HINT = 'One relation per Iceberg table: the cluster-column and cold-write lookups resolve a table by its ref. Release the existing registration first.';
    END IF;

    -- Last, because a caller who got the names wrong should hear that first, and
    -- because the arguments are refused the same way whatever the configuration.
    -- ensure_attached() silently does nothing without both GUCs, and the DESCRIBE
    -- that follows would then fail against a catalog that was never attached. A
    -- table missing from a catalog that IS attached reports DuckDB's own error,
    -- which names the table and the near matches.
    IF COALESCE(current_setting('coldfront.warehouse', true), '') = ''
       OR COALESCE(current_setting('coldfront.lakekeeper_endpoint', true), '') = '' THEN
        RAISE EXCEPTION 'coldfront.adopt_iceberg_table: no Iceberg catalog is configured, so % cannot be read', p_ice_ref
            USING HINT = 'Set coldfront.warehouse and coldfront.lakekeeper_endpoint, then adopt again.';
    END IF;
END;
$$;

-- The PostgreSQL type one adopted column reads as, which is what the wrapper
-- view casts it to: the observed Iceberg type through the reverse map, or the
-- caller's p_types override where there is one.
--
-- An override is accepted only where it maps to the type the catalog already
-- stores. Both sides of that comparison run through the reverse map, because the
-- two spell some types differently, so this compares types rather than
-- spellings. The view then casts to the override's surface type (json for jsonb,
-- real[] for a pgvector type) or, where the override stores as the observed type
-- does already, to the observed type: an override changes what a column reads
-- as; it cannot reinterpret the stored bytes.
CREATE OR REPLACE FUNCTION coldfront._adopt_column_type(
    p_column      text,
    p_duckdb_type text,
    p_types       jsonb
) RETURNS text
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
    v_override text := p_types ->> p_column;
    v_observed text := coldfront._pg_type_from_iceberg(p_duckdb_type, p_column);
BEGIN
    IF v_override IS NULL THEN
        RETURN v_observed;
    END IF;
    IF coldfront._pg_type_from_iceberg(coldfront._iceberg_storage_type(v_override))
       IS DISTINCT FROM v_observed THEN
        RAISE EXCEPTION 'coldfront.adopt_iceberg_table: p_types gives column "%" the type %, which Iceberg would store as %, but the catalog stores %',
            p_column, v_override, coldfront._iceberg_storage_type(v_override), p_duckdb_type
            USING HINT = 'An override changes what a column reads as; it cannot reinterpret the stored bytes.';
    END IF;
    RETURN COALESCE(NULLIF(coldfront._iceberg_view_cast_type(v_override), ''), v_observed);
END;
$$;

-- coldfront.adopt_iceberg_table: bring an existing Iceberg table under a PG
-- wrapper view for reads, optionally enabling writes. Nothing is created in the
-- catalog and no data is moved: releasing it later leaves the table untouched.
--
--   p_schema     PG schema to put the wrapper view in.
--   p_table      the view's name, and the Iceberg table's name.
--   p_namespace  the Iceberg namespace the table lives in, or NULL for p_schema.
--                It need not exist as a PG schema; p_schema must.
--   p_writable   false (the default) registers the read path alone; true arms the
--                INSERT/UPDATE/DELETE rewrite.
--   p_types      {"column": "pg_type"} overrides, accepted only where the override
--                maps to the type the catalog already stores.
--
-- The schema is read from the catalog rather than declared, which is what makes
-- one call enough, and it is lossier than declaring it: Iceberg records no PG
-- type, so a jsonb column created by coldfront adopts as text and data->>'k'
-- stops working until p_types says otherwise.
--
-- Adoption binds a name once. A second call under a registered name is refused
-- whatever its arguments; to arm writes or change an override, release the table
-- and adopt it again. In a mesh one node adopts: the registry row and the wrapper
-- view replicate, so every peer reads and writes the table through them, and a
-- peer's own adopt is refused as already registered. A writer outside coldfront
-- (Spark, or another tool on the same catalog) is outside the bakery and can
-- still collide at Lakekeeper; _claim_iceberg_external is how an in-house tool
-- joins, as the Go compactor does.
CREATE FUNCTION coldfront.adopt_iceberg_table(
    p_schema    text,
    p_table     text,
    p_namespace text    DEFAULT NULL,
    p_writable  boolean DEFAULT false,
    p_types     jsonb   DEFAULT NULL
) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
    v_ice       text;
    v_prefix    text := coldfront._vec_list_col('');
    v_cols      jsonb := '[]'::jsonb;
    v_vec_cols  text[] := '{}';
    v_n         int := 0;
    v_unknown   text;
    r           record;
BEGIN
    IF p_schema IS NULL OR p_table IS NULL THEN
        RAISE EXCEPTION 'coldfront.adopt_iceberg_table: p_schema and p_table are required';
    END IF;
    IF p_writable IS NULL THEN
        RAISE EXCEPTION 'coldfront.adopt_iceberg_table: p_writable must be true or false'
            USING HINT = 'Omit it to adopt read-only.';
    END IF;

    -- Refused before the claim below, so a standby stays out of the bakery.
    PERFORM coldfront._reject_on_standby('adopt an Iceberg table');

    v_ice := coldfront._iceberg_ref(COALESCE(p_namespace, p_schema), p_table);

    -- The preflight and the registry INSERT run under the table's bakery claim,
    -- so two nodes adopting one Iceberg table are serialised rather than both
    -- passing a preflight that reads only its own node's registry. The claim is
    -- released by the COMMIT callback, which runs after the registry row is
    -- committed and before the ack that frees the waiter, so the second node
    -- reads the first node's row and refuses. Without it the two rows replicate
    -- into each other and the second violates UNIQUE (iceberg_table) in the apply
    -- worker. Modelled in docs/formal/Bakery.tla: Bakery_adopt_race.cfg
    -- violates NoDoubleRegistration, Bakery_adopt.cfg holds it.
    PERFORM coldfront._take_iceberg_claim(v_ice);

    -- Every refusal runs before anything is written, PG side or catalog side.
    PERFORM coldfront._adopt_preflight(p_schema, p_table, v_ice);

    -- Reading the schema is a DuckDB read and the registration is a PG write, the
    -- pattern pg_duckdb blocks by default; the same XactCallback ties the two, so
    -- ROLLBACK still undoes both. The read runs inside this function, which
    -- pg_duckdb also refuses by default.
    SET LOCAL duckdb.unsafe_allow_mixed_transactions = on;
    SET LOCAL duckdb.unsafe_allow_execution_inside_functions = on;
    PERFORM coldfront.ensure_attached();

    -- DESCRIBE binds as a LogicalColumnDataGet over the table's metadata, so this
    -- reads the schema without scanning a single Parquet file, and it answers on a
    -- table nothing has ever written to. Its rows arrive in Iceberg schema order,
    -- which is the only place the cluster columns' order can come from.
    --
    -- Through EXECUTE, which is what makes a dynamic table name work here: a bare
    -- duckdb.query(format(...)) is not a constant at plan time and pg_duckdb
    -- refuses it. Built as dynamic SQL, the argument is a literal again.
    FOR r IN EXECUTE format(
        'SELECT t.r[%L]::text AS col_name, t.r[%L]::text AS duckdb_type '
        'FROM duckdb.query(%L) AS t(r)',
        'column_name', 'column_type', format('DESCRIBE %s', v_ice))
    LOOP
        -- A cluster column belongs to the column it names and to no query written
        -- against the view, so it is recorded and skipped rather than projected.
        IF starts_with(r.col_name, v_prefix) THEN
            v_vec_cols := v_vec_cols || substr(r.col_name, length(v_prefix) + 1);
            CONTINUE;
        END IF;

        v_cols := v_cols || jsonb_build_object(
                      'name', r.col_name,
                      'cast', coldfront._adopt_column_type(r.col_name, r.duckdb_type, p_types));
        v_n := v_n + 1;
    END LOOP;

    IF v_n = 0 THEN
        RAISE EXCEPTION 'coldfront.adopt_iceberg_table: % has no adoptable columns', v_ice;
    END IF;

    -- An override names a column the catalog reports. A key that matches none is
    -- a misspelling, and leaving it unsaid would adopt the column it was meant
    -- for as its unoverridden type, which is the failure p_types exists to
    -- prevent.
    IF p_types IS NOT NULL THEN
        SELECT string_agg('"' || t.k || '"', ', ' ORDER BY t.k) INTO v_unknown
          FROM jsonb_object_keys(p_types) AS t(k)
         WHERE NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_cols) AS u(c)
                            WHERE c->>'name' = t.k);
        IF v_unknown IS NOT NULL THEN
            RAISE EXCEPTION 'coldfront.adopt_iceberg_table: p_types names %, which % does not have',
                v_unknown, v_ice
                USING HINT = 'An override applies to a column the catalog reports. Check the spelling against the table''s schema.';
        END IF;
    END IF;

    -- A clustered vector is compared with <=> through the view's real[] columns,
    -- and nothing else here guarantees pgvector is present.
    IF cardinality(v_vec_cols) > 0 THEN
        PERFORM coldfront.install_vector_ops();
    END IF;

    PERFORM coldfront._register_iceberg_view(p_schema, p_table, v_ice,
                                             v_cols, v_vec_cols, p_writable);

    RAISE NOTICE 'coldfront: adopted % as %.% (% columns, %)%',
        v_ice, p_schema, p_table, v_n,
        CASE WHEN p_writable THEN 'writable' ELSE 'read-only' END,
        CASE WHEN cardinality(v_vec_cols) > 0
             THEN format('; clustered vector columns: %s', array_to_string(v_vec_cols, ', '))
             ELSE '' END;
END;
$$;

-- coldfront.release_iceberg_table: the inverse of adopt_iceberg_table. The
-- wrapper view and the registry row go; the Iceberg table keeps every row,
-- because no Iceberg I/O happens here at all.
--
-- This is what makes adoption safe to try. Without it the only exit would be
-- drop_iceberg_table, which destroys the catalog entry, and plain DROP VIEW stays
-- blocked by the DDL hook.
--
-- A tiered registration is refused: releasing one would leave its cold rows
-- unreachable while the hot table returned under the relation's name.
CREATE FUNCTION coldfront.release_iceberg_table(p_schema text, p_table text)
RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
    v_iceberg_only boolean;
    v_ice          text;
BEGIN
    SELECT is_iceberg_only, iceberg_table
      INTO v_iceberg_only, v_ice
      FROM coldfront.tiered_views
     WHERE schema_name = p_schema AND relname = p_table;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'coldfront.release_iceberg_table: "%.%" is not a registered Iceberg table', p_schema, p_table
            USING HINT = 'Only tables registered in coldfront.tiered_views can be released.';
    END IF;

    IF NOT v_iceberg_only THEN
        RAISE EXCEPTION 'coldfront.release_iceberg_table: "%.%" is tiered, not adopted', p_schema, p_table
            USING HINT = 'Releasing it would leave its cold rows unreachable while the hot table returned under that name. Use coldfront.drop_iceberg_table() to remove the cold tier.';
    END IF;

    PERFORM coldfront._unregister_iceberg(p_schema, p_table);

    RAISE NOTICE 'coldfront: released "%.%"; % keeps every row and stays in the catalog',
        p_schema, p_table, v_ice;
END;
$$;

-- The PARTITIONED BY clause a decoupled table is created with, or '' for none.
-- Each element of p_partition_cols is one term as DuckDB takes it: a column name,
-- year|month|day|hour(col), bucket(N, col) or truncate(W, col), joined as given.
-- The engine judges them at CREATE TABLE: an unknown transform, a bad argument or
-- a column not in the schema is refused there. The one check it leaves to the
-- first INSERT is made here instead, while the table does not exist yet: a time
-- transform on a column that is not a timestamp or date (for hour, a timestamp)
-- binds against the wrong type and fails every write to the table. The column is
-- matched the way the engine matches it, case-insensitively, quoted or not.
CREATE OR REPLACE FUNCTION coldfront._partition_clause(p_columns jsonb, p_partition_cols text[])
RETURNS text
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
    term      text;
    m         text[];
    transform text;
    col_name  text;
    col_type  text;
    storage   text;
BEGIN
    IF p_partition_cols IS NULL OR cardinality(p_partition_cols) = 0 THEN
        RETURN '';
    END IF;
    FOREACH term IN ARRAY p_partition_cols LOOP
        m := regexp_match(term, '^\s*(year|month|day|hour)\s*\(\s*("(?:[^"]|"")*"|[^\s()"]+)\s*\)\s*$', 'i');
        CONTINUE WHEN m IS NULL;
        transform := lower(m[1]);
        col_name  := CASE WHEN m[2] LIKE '"%'
                          THEN replace(substr(m[2], 2, length(m[2]) - 2), '""', '"')
                          ELSE m[2] END;
        SELECT c->>'type' INTO col_type
          FROM jsonb_array_elements(p_columns) AS c
         WHERE lower(c->>'name') = lower(col_name);
        CONTINUE WHEN col_type IS NULL;
        storage := coldfront._iceberg_storage_type(col_type);
        IF NOT (storage IN ('TIMESTAMPTZ', 'TIMESTAMP') OR (storage = 'DATE' AND transform <> 'hour')) THEN
            RAISE EXCEPTION 'coldfront.create_iceberg_table: p_partition_cols term % needs a % column; "%" is %',
                term, CASE WHEN transform = 'hour' THEN 'timestamp' ELSE 'timestamp or date' END,
                col_name, col_type;
        END IF;
    END LOOP;
    RETURN ' PARTITIONED BY (' || array_to_string(p_partition_cols, ', ') || ')';
END;
$$;

-- create_iceberg_table: provision an iceberg-only table end-to-end.
--
--   p_schema         PG schema for the wrapper view (e.g. 'public').
--   p_table          relation/view name (e.g. 'events'). Iceberg table is
--                    created at ice.<p_schema>.<p_table>.
--   p_columns        jsonb array of {name, type} entries. Type is a PG type
--                    name from the supported set; see _iceberg_storage_type.
--   p_partition_cols Iceberg partitioning, one PARTITIONED BY term per element as
--                    DuckDB takes it (a column name, year|month|day|hour(col),
--                    bucket(N, col), truncate(W, col)); see _partition_clause.
--                    NULL or empty creates the table unpartitioned.
--
-- Effects:
--   1. Creates the Iceberg table via duckdb.raw_query('CREATE TABLE ice...').
--   2. Creates the PG wrapper view and the registry row through
--      _register_iceberg_view, which arms the C post_parse_analyze hook to
--      rewrite INSERT/UPDATE/DELETE on the view into cold-path DML.
CREATE OR REPLACE FUNCTION coldfront.create_iceberg_table(
    p_schema         text,
    p_table          text,
    p_columns        jsonb,
    p_partition_cols text[] DEFAULT NULL
) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
    ice_ref          text := coldfront._iceberg_ref(p_schema, p_table);
    iceberg_cols     text := '';
    v_view_cols      jsonb := '[]'::jsonb;
    v_vec_cols       text[] := '{}';
    v_cluster_cols   text;
    v_part           text;
    v_props          text := '';
    n                int  := 0;
    col              jsonb;
    col_name         text;
    pg_type          text;
    storage_type     text;
BEGIN
    -- The Iceberg CREATE SCHEMA / CREATE TABLE below precede this function's PG
    -- writes, so this guard is the one that keeps catalog writes off a replica.
    PERFORM coldfront._reject_on_standby('create an Iceberg table');

    IF p_columns IS NULL OR jsonb_array_length(p_columns) = 0 THEN
        RAISE EXCEPTION 'coldfront.create_iceberg_table: p_columns must be a non-empty jsonb array of {name,type}';
    END IF;

    -- Provisioning combines DuckDB writes (CREATE TABLE on Iceberg) with PG
    -- writes (CREATE VIEW, INSERT INTO coldfront.tiered_views). pg_duckdb
    -- blocks that pattern by default; same XactCallback ties the two so
    -- ROLLBACK still undoes both, just bypassing the pre-commit guard.
    SET LOCAL duckdb.unsafe_allow_mixed_transactions = on;

    FOR col IN SELECT * FROM jsonb_array_elements(p_columns) LOOP
        col_name     := col->>'name';
        pg_type      := col->>'type';
        IF col_name IS NULL OR pg_type IS NULL THEN
            RAISE EXCEPTION 'coldfront.create_iceberg_table: each p_columns element needs both "name" and "type"';
        END IF;
        -- A declared vector needs pgvector present before the view exposes real[]
        -- columns a caller compares with <=>, and nothing else here guarantees it:
        -- a decoupled table names its types, it does not hold the type.
        IF coldfront._is_vector_type(pg_type) THEN
            PERFORM coldfront.install_vector_ops();
            v_vec_cols := v_vec_cols || col_name;
        END IF;
        storage_type := coldfront._iceberg_storage_type(pg_type, col_name);

        IF n > 0 THEN
            iceberg_cols := iceberg_cols || ', ';
        END IF;
        n := n + 1;

        iceberg_cols := iceberg_cols || quote_ident(col_name) || ' ' || storage_type;
        -- The view casts to the surface type where the storage type is not one
        -- PG parses (json, bytea, real[]), else to the storage type itself.
        v_view_cols := v_view_cols || jsonb_build_object(
                           'name', col_name,
                           'cast', COALESCE(NULLIF(coldfront._iceberg_view_cast_type(pg_type), ''),
                                            storage_type));
    END LOOP;

    v_part := coldfront._partition_clause(p_columns, p_partition_cols);

    -- The cluster columns lead the Iceberg schema, one per vector column and in the
    -- order they were declared; the view projection deliberately skips them. A
    -- decoupled INSERT is rewritten in C, which is where their values come from.
    -- Only the first gets the sort order, so only its probe prunes.
    IF cardinality(v_vec_cols) > 0 THEN
        SELECT string_agg(quote_ident(coldfront._vec_list_col(c)) || ' INTEGER, ', ''
                          ORDER BY ord)
          INTO v_cluster_cols
          FROM unnest(v_vec_cols) WITH ORDINALITY AS u(c, ord);
        iceberg_cols := v_cluster_cols || iceberg_cols;
        -- No primary key is declared in this mode, so the cluster column alone.
        v_props := coldfront._vec_layout_props(
                       coldfront._vec_sort_key(v_vec_cols[1], NULL), v_part <> '');
    END IF;

    -- 1. Iceberg table on the attached catalog (create namespace first;
    -- CREATE SCHEMA IF NOT EXISTS is idempotent and cheap on Lakekeeper).
    -- IF NOT EXISTS on the table itself makes the helper safe to call again
    -- against an existing table — useful for distributed setups where each
    -- node registers the same shared Iceberg table independently. PARTITIONED BY
    -- precedes WITH, as DuckDB parses the statement.
    PERFORM coldfront.ensure_attached();
    PERFORM duckdb.raw_query(format('CREATE SCHEMA IF NOT EXISTS ice.%I', p_schema));
    PERFORM duckdb.raw_query(format(
        'CREATE TABLE IF NOT EXISTS %s (%s)%s%s', ice_ref, iceberg_cols, v_part, v_props));

    -- 2. PG wrapper view + registry row. From here the C post_parse_analyze hook
    --    intercepts INSERT INTO the view (see coldfront.c emit_cold /
    --    prefix_pg_tables_with_pglocal) and rewrites it into a single bulk
    --    duckdb.raw_query('INSERT INTO ice.… VALUES/SELECT …'): one Iceberg
    --    snapshot for the whole statement regardless of row count, so a multi-row
    --    or parallel INSERT cannot incur per-row 409 CatalogCommitConflicts.
    --    INSERT … SELECT FROM <pg_source> gets each PG-table reference prefixed
    --    with `pglocal.` so DuckDB's postgres extension streams source rows over
    --    libpq with no local materialisation.
    PERFORM coldfront._register_iceberg_view(p_schema, p_table, ice_ref,
                                             v_view_cols, v_vec_cols, true);
END;
$$;

-- ============================================================================
-- Multi-writer commit serialisation (bakery protocol) — runtime requirements.
--
-- The bakery is only invoked on iceberg-only writes against multi-node
-- meshes. Tiered-only single-node deployments don't need the snowflake
-- extension or the snowflake.node GUC at all. So we WARN at extension
-- load instead of failing — the bakery functions themselves error
-- clearly at first call if either prerequisite is missing.
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'snowflake') THEN
        RAISE NOTICE 'coldfront: snowflake extension not installed — iceberg-only multi-writer mode (the bakery protocol) will be unavailable. Run CREATE EXTENSION snowflake on each cluster node to enable it.';
    ELSIF NULLIF(current_setting('snowflake.node', true), '') IS NULL THEN
        RAISE NOTICE 'coldfront: snowflake.node GUC unset — iceberg-only multi-writer mode (the bakery protocol) will be unavailable. Set snowflake.node to a per-node integer (1..1023) in postgresql.conf.';
    END IF;
END $$;

-- Convenience accessor for the local node's snowflake id.
CREATE FUNCTION coldfront.node_id() RETURNS int
LANGUAGE sql STABLE AS
$$ SELECT current_setting('snowflake.node')::int $$;

-- The local node's spock node name — the bakery's cross-node identity (acks are
-- keyed by it). spock.local_node has only node_id + node_local_interface (no
-- node_name column), and an unqualified node_name in a subquery against it
-- silently resolves to an OUTER query's column, so we join to spock.node to read
-- the local name explicitly. plpgsql (not sql) so the spock references resolve at
-- call time: CREATE EXTENSION succeeds on a vanilla (spock-absent) install, where
-- the bakery is never armed and this is never called.
CREATE FUNCTION coldfront._my_spock_node_name() RETURNS name
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_name name;
BEGIN
    -- STRICT: fail clearly here if the local spock node is not configured
    -- (no row) or ambiguous (more than one), rather than returning NULL and
    -- surfacing later as an opaque claim_acks NOT NULL violation. No EXCEPTION
    -- block, so no subtransaction (pg_duckdb rejects those).
    SELECT ln.node_name INTO STRICT v_name
      FROM spock.local_node l
      JOIN spock.node ln ON ln.node_id = l.node_id;
    RETURN v_name;
END $$;

-- ============================================================================
-- Multi-writer commit serialisation (bakery protocol).
--
-- Background. With three executor PG nodes all writing to the same Iceberg
-- table via pg_duckdb, every iceberg commit posts to Lakekeeper which does CAS
-- on metadata_location. Concurrent writers that prepared their commit body
-- against the same parent snapshot lose the race; whichever lands second
-- gets HTTP 409 CatalogCommitConflicts, which duckdb-iceberg (5edc45f0) raises
-- as "Failed to commit Iceberg transaction" and pg_duckdb turns into an ERROR
-- at PRE_COMMIT: the losing transaction aborts and the batch has to be retried.
--
-- Architecture. Coordinate cluster-wide via:
--  • coldfront.claims: one row per active claim, keyed by its ticket, the
--    coordination state. Replicated by Spock so every node sees every other
--    node's current claim.
--  • snowflake.nextval(): the ticket. Its high bits are the issuing node's
--    clock in milliseconds, so tickets from different nodes order by those
--    clocks (see coldfront.claims below).
--  • coldfront.claim_acks: each peer's ack of a claim, replicated back to the
--    claimant. coldfront.deferred_acks is each node's local queue of the acks
--    it owes until its own smaller-ticket claim is released.
--  • the loopback (coldfront._loopback): required because the claim row INSERT
--    must commit BEFORE the user's iceberg INSERT happens (else peers don't see our
--    claim until our PG xact ends, defeating the bakery). pg_duckdb forbids
--    SAVEPOINT, plpgsql can't COMMIT inside a function, and pg_duckdb's
--    pglocal-attached postgres database is read-only — so an autonomous
--    transaction via a separate libpq connection is the only path.
--
-- Bakery rule (Ricart-Agrawala). Each writer:
--   1. Takes the node-local advisory xact lock for the table, then INSERTs
--      its claim in the loopback's own transaction (_insert_claim). Spock
--      replicates it.
--   2. Each peer acks the claim at once, or defers the ack while it holds a
--      smaller-ticket claim on the same table (_on_claim_apply).
--   3. Polls locally until no smaller same-node ticket remains and every
--      alive peer has acked.
--   4. Runs the actual iceberg INSERT (in user's PG transaction). Sole
--      writer to Lakekeeper at this moment, no CAS race.
--   5. The C xact callback (coldfront_xact_callback) DELETEs the claim at
--      XACT_EVENT_COMMIT, after pg_duckdb committed the Iceberg transaction at
--      XACT_EVENT_PRE_COMMIT (and at ABORT), over the same loopback; the
--      DELETE trigger (_on_claim_release) forwards the acks deferred behind it.
--
-- Complexity is in the four primitives above. The body of each helper is
-- small.
-- ============================================================================

-- Active claims only. A row exists iff that ticket-owning node is currently
-- mid-claim on this iceberg_table. Released claims DELETE the row, so the
-- table is empty whenever no writers are mid-commit. Bakery rule picks the
-- smallest ticket per iceberg_table.
--
-- ticket is a snowflake int8 generated by the pgEdge snowflake extension
-- (https://github.com/pgEdge/snowflake). The extension is shipped with
-- Spock; expects `snowflake.node` GUC set in postgresql.conf.
-- Helpers used: snowflake.nextval() (default db-wide seq snowflake.id_seq),
-- snowflake.get_node(ticket), snowflake.get_epoch(ticket).
-- ticket is the PK — snowflakes are globally unique by construction. PK
-- is also required by Spock's default replication set (which replicates
-- DELETEs, and Spock refuses no-PK tables for delete-replicating repsets).
CREATE TABLE coldfront.claims (
    iceberg_table text   NOT NULL,
    ticket        bigint PRIMARY KEY
);

-- Acks for the bakery's Ricart-Agrawala layer.  A row here means
-- "peer ack_from_name (its spock node name) has acknowledged ticket on
-- iceberg_table."  The
-- originator polls this table waiting for one row per live peer before
-- entering the iceberg-commit phase.  Spock-replicated so peers'
-- ack-INSERTs (from the peer-side trigger on coldfront.claims) reach
-- the originator.
CREATE TABLE coldfront.claim_acks (
    ticket          bigint NOT NULL,
    ack_from_name   name   NOT NULL,
    iceberg_table   text   NOT NULL,
    PRIMARY KEY (ticket, ack_from_name)
);

-- Deferred acks queue, LOCAL to each node (NOT replicated).  When a peer
-- receives an originator's claim while peer has its own smaller-ticket
-- claim pending on the same iceberg_table, the peer-side trigger queues
-- the ack here instead of inserting into coldfront.claim_acks
-- immediately (Ricart-Agrawala's defer rule).  At peer's claim release
-- (DELETE on coldfront.claims), the release trigger drains the queue,
-- inserting the queued acks into coldfront.claim_acks which then
-- replicate to the original originator(s).
CREATE TABLE coldfront.deferred_acks (
    pending_ticket  bigint NOT NULL,
    ack_for_ticket  bigint NOT NULL,
    iceberg_table   text   NOT NULL,
    PRIMARY KEY (pending_ticket, ack_for_ticket)
);

-- Configuration: the libpq connection string of the loopback that runs the
-- bakery's autonomous transactions (see coldfront._loopback). It must name a
-- unix socket: every onboarded role can read it, so it must never need a
-- password. Set once per node in postgresql.conf:
--    coldfront.loopback_dsn = 'host=/var/run/postgresql dbname=coldfront user=coldfront'
-- Empty on a node outside a mesh; _take_iceberg_claim refuses a cold write on
-- a node that runs Spock without it.
CREATE FUNCTION coldfront._loopback_dsn() RETURNS text
LANGUAGE sql STABLE AS
$$ SELECT current_setting('coldfront.loopback_dsn') $$;

-- coldfront._loopback runs one statement on this node's loopback: a libpq
-- connection the extension's C code opens from coldfront.loopback_dsn and keeps
-- for the backend's lifetime. The statement commits on its own and is tagged
-- with this node as its origin, so Spock replicates it everywhere. Returns the
-- first column of the first row as text, or NULL. A statement that fails
-- because the connection broke runs once more on a new connection, so every
-- statement sent here is safe to repeat. It runs SQL as the loopback's user,
-- so PUBLIC cannot execute it: the bakery calls it from SECURITY DEFINER code
-- and from the replica-only apply trigger.
CREATE FUNCTION coldfront._loopback(p_sql text) RETURNS text
LANGUAGE c STRICT AS 'coldfront', 'coldfront_loopback';
REVOKE EXECUTE ON FUNCTION coldfront._loopback(text) FROM PUBLIC;

-- Peer-side trigger: fires when spock applies an originator's claim INSERT or
-- poke UPDATE to this node's coldfront.claims (REPLICA-only, not on the
-- originator). Reaps orphaned local claims before applying Ricart-Agrawala's
-- defer rule; an UPDATE without a reap keeps the earlier ack/defer decision:
--   * If this node has its own pending claim with SMALLER ticket on the
--     same iceberg_table → DEFER (queue in coldfront.deferred_acks).
--   * Otherwise → ack immediately (INSERT into coldfront.claim_acks,
--     which replicates back to originator).
-- See docs/formal/Bakery.tla, the Applier process.
CREATE FUNCTION coldfront._on_claim_apply() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    my_node         int    := current_setting('snowflake.node')::int;
    my_name         name   := coldfront._my_spock_node_name();
    -- Per-table advisory lock key. Pairs with the exclusive lock that
    -- _insert_claim takes, in the loopback's transaction, before the ticket.
    -- Shared mode here so concurrent apply-worker triggers don't serialise
    -- against each other; they only serialise against an in-flight local claim.
    my_lock_key     int    := hashtext('coldfront_claim:'||NEW.iceberg_table)::int;
    smaller_pending bigint;
    v_reaped        boolean := false;
BEGIN
    IF snowflake.get_node(NEW.ticket) = my_node THEN
        RETURN NULL;
    END IF;

    -- Close the "in-flight local claim" visibility race: if this node's
    -- loopback is between snowflake.nextval() and the commit of its claim
    -- INSERT (the claim chosen but not yet committed visibly), it holds the
    -- exclusive key until that transaction ends. The SELECT below then sees
    -- the in-flight local claim and defers correctly. The shared key is
    -- transaction-level, so it ends with the apply transaction however that
    -- transaction ends.
    --
    -- FOR UPDATE closes the defer/drain race: it locks the smaller-ticket
    -- CLAIM ROW we are about to defer behind. The release path's `DELETE FROM
    -- coldfront.claims` (which fires _on_claim_release's forward+delete drain)
    -- locks/removes that SAME row, so the two serialize on it:
    --   • we lock first  -> our deferred_acks INSERT below commits before the
    --     drain, which then forwards it (the ack reaches the requester);
    --   • release wins    -> this FOR UPDATE re-read returns NULL (claim gone)
    --     so smaller_pending IS NULL and we ACK immediately (R-A's own rule,
    --     re-evaluated) instead of deferring into an already-drained bucket.
    -- Without FOR UPDATE the deferral can be written behind a released claim and
    -- deleted-unforwarded (or orphaned) — a silently dropped ack that strands the
    -- min-ticket holder at the WaitAcks barrier forever (the bakery wedge).
    -- It MUST lock the claim row, NOT deferred_acks: at the drain's forward-SELECT
    -- the lost deferral row does not exist yet (a phantom), so FOR UPDATE there
    -- cannot lock it. Modelled + proven in docs/formal/Bakery.tla (SafeAcks):
    -- SafeAcks=FALSE violates EventualProgress (the wedge); SafeAcks=TRUE holds it
    -- while every safety invariant still holds.
    -- Reaper, apply path. A smaller same-node claim means we are about to defer
    -- behind it. First ask whether it can have a live owner: a live local writer
    -- holds the table xact lock from its claim INSERT until its transaction ends
    -- (the release runs in the COMMIT callback, before the lock drops). If the
    -- try succeeds no such writer exists, so every same-node claim for this table
    -- is an orphan: delete them and their acks through the loopback, which fires
    -- _on_claim_release on the origin side and forwards what was deferred behind
    -- them. Done before the FOR UPDATE below so we hold no row lock the loopback
    -- session would wait on. Fires for the arriving claim and for the waiter's
    -- poke UPDATE alike. Modelled in docs/formal/Bakery.tla (Reaper, Applier,
    -- Poker).
    IF EXISTS (SELECT 1 FROM coldfront.claims
                WHERE snowflake.get_node(ticket) = my_node
                  AND iceberg_table = NEW.iceberg_table
                  AND ticket < NEW.ticket)
       AND pg_try_advisory_xact_lock(hashtext('coldfront_iceberg:' || NEW.iceberg_table)) THEN
        PERFORM coldfront._loopback(format(
            'WITH orphan AS ('
            '  DELETE FROM coldfront.claims'
            '   WHERE snowflake.get_node(ticket) = %s AND iceberg_table = %L'
            '  RETURNING ticket'
            ') DELETE FROM coldfront.claim_acks a USING orphan o WHERE a.ticket = o.ticket',
            my_node, NEW.iceberg_table));
        v_reaped := true;
    END IF;

    -- A poke (UPDATE) that reaped nothing changes nothing: the INSERT-time
    -- decision stands, acked or deferred behind a live holder. A fresh ack here
    -- could land after the waiter's release and outlive its claim.
    IF TG_OP = 'UPDATE' AND NOT v_reaped THEN
        RETURN NULL;
    END IF;

    PERFORM pg_advisory_xact_lock_shared(my_lock_key);
    SELECT ticket INTO smaller_pending
      FROM coldfront.claims
     WHERE snowflake.get_node(ticket) = my_node
       AND iceberg_table = NEW.iceberg_table
       AND ticket < NEW.ticket
     ORDER BY ticket
     LIMIT 1
     FOR UPDATE;

    IF smaller_pending IS NOT NULL THEN
        -- Defer locally: drain (and the eventual ack via the loopback) fires
        -- on our own claim's release.  coldfront.deferred_acks is
        -- intentionally local-only (not in any spock repset).
        INSERT INTO coldfront.deferred_acks
            (pending_ticket, ack_for_ticket, iceberg_table)
        VALUES (smaller_pending, NEW.ticket, NEW.iceberg_table)
        ON CONFLICT DO NOTHING;
    ELSE
        -- Route the ack INSERT through the loopback.  The trigger fires
        -- inside spock's apply worker (session_replication_role = 'replica',
        -- pg_replication_origin set to the publisher we're applying).
        -- A direct INSERT here would inherit that origin tag and spock's
        -- loop-prevention would filter the row out of the stream back to
        -- the originator, so they'd never see our ack.  The loopback is a
        -- separate libpq session with no replication origin set up, so the
        -- INSERT is tagged with THIS node as origin and replicates normally
        -- cluster-wide, including back to the originator.
        PERFORM coldfront._loopback(format(
            'INSERT INTO coldfront.claim_acks (ticket, ack_from_name, iceberg_table) '
            'VALUES (%s, %L, %L) ON CONFLICT DO NOTHING',
            NEW.ticket, my_name, NEW.iceberg_table));
    END IF;
    RETURN NULL;
END $$;

CREATE TRIGGER coldfront_claim_apply
    AFTER INSERT OR UPDATE ON coldfront.claims
    FOR EACH ROW EXECUTE FUNCTION coldfront._on_claim_apply();
ALTER TABLE coldfront.claims ENABLE REPLICA TRIGGER coldfront_claim_apply;

-- Origin-side trigger: fires when this node's loopback DELETEs a row in
-- coldfront.claims, which is how the C XactCallback releases a claim we held
-- and how the reaper removes an orphan. Drains coldfront.deferred_acks: every ack
-- we had queued for our own pending claim now gets INSERTed into
-- coldfront.claim_acks (replicating to the original originator).
-- Default trigger mode: fires on origin only, NOT on spock-apply of a
-- peer's DELETE.
CREATE FUNCTION coldfront._on_claim_release() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    my_node int := current_setting('snowflake.node')::int;
    my_name name := coldfront._my_spock_node_name();
BEGIN
    -- A deleted claim's acks are dead whoever deleted it (tickets are never
    -- reused), so drop them before the owner check below: an operator's manual
    -- DELETE, or a ticket the node id does not resolve, must not leave them
    -- behind. Only the originator's own wait loop ever read them, and it has
    -- exited.
    DELETE FROM coldfront.claim_acks WHERE ticket = OLD.ticket;

    IF snowflake.get_node(OLD.ticket) <> my_node THEN
        RETURN NULL;
    END IF;

    INSERT INTO coldfront.claim_acks (ticket, ack_from_name, iceberg_table)
    SELECT ack_for_ticket, my_name, iceberg_table
      FROM coldfront.deferred_acks
     WHERE pending_ticket = OLD.ticket
    ON CONFLICT DO NOTHING;

    DELETE FROM coldfront.deferred_acks WHERE pending_ticket = OLD.ticket;
    RETURN NULL;
END $$;

CREATE TRIGGER coldfront_claim_release
    AFTER DELETE ON coldfront.claims
    FOR EACH ROW EXECUTE FUNCTION coldfront._on_claim_release();

-- coldfront._insert_claim is the claim's own transaction: _claim_iceberg_lock
-- runs it on the loopback, and every lock taken here ends with that
-- transaction, on commit or error alike. It returns the new ticket.
--
-- The table's claim key is taken before the ticket and held to the commit.
-- Paired with the shared key in _on_claim_apply, it closes the "we have a
-- ticket but the row isn't visible yet" window where a peer trigger could
-- otherwise ack us prematurely. A peer claim that arrives before the key is
-- taken meets no ticket of ours, and snowflake's monotonic timestamp
-- guarantees any future ticket of ours is larger than the peer's, so acking
-- the peer is the correct R-A choice.
--
-- The reap runs after the key, so its snapshot sees every claim committed
-- before it. The caller holds the table's xact lock, which proves no live local
-- writer is in the bakery for this table, so any same-node claim row for it has
-- no owner (_take_iceberg_claim keeps a transaction to one claim per table, so
-- none of them is the caller's own). A same-node claim on another table is
-- reaped only when this session can take that table's lock: a live writer holds
-- it, the caller included when its transaction claimed that table earlier. The
-- epoch arm covers claims from before a restart. The orphan DELETE fires
-- _on_claim_release, which forwards whatever peers deferred behind the orphan,
-- and the acks CTE drops the orphan's own acks. It runs before our INSERT, so
-- it cannot reap us. Modelled in docs/formal/Bakery.tla (Reaper, BeginClaim).
CREATE FUNCTION coldfront._insert_claim(p_iceberg_table text) RETURNS bigint
LANGUAGE plpgsql AS $$
DECLARE
    my_node  int    := current_setting('snowflake.node')::int;
    v_other  text[] := '{}';
    v_tbl    text;
    v_ticket bigint;
BEGIN
    PERFORM pg_advisory_xact_lock(hashtext('coldfront_claim:' || p_iceberg_table));
    FOR v_tbl IN SELECT DISTINCT c.iceberg_table FROM coldfront.claims c
                  WHERE snowflake.get_node(c.ticket) = my_node
                    AND c.iceberg_table <> p_iceberg_table LOOP
        IF pg_try_advisory_xact_lock(hashtext('coldfront_iceberg:' || v_tbl)) THEN
            v_other := v_other || v_tbl;
        END IF;
    END LOOP;
    WITH orphan AS (
        DELETE FROM coldfront.claims
         WHERE snowflake.get_node(ticket) = my_node
           AND (iceberg_table = p_iceberg_table
                OR iceberg_table = ANY(v_other)
                OR snowflake.get_epoch(ticket) < extract(epoch FROM pg_postmaster_start_time()))
        RETURNING ticket
    ), acks AS (
        DELETE FROM coldfront.claim_acks a USING orphan o WHERE a.ticket = o.ticket
    )
    INSERT INTO coldfront.claims (iceberg_table, ticket)
    VALUES (p_iceberg_table, snowflake.nextval())
    RETURNING ticket INTO v_ticket;
    RETURN v_ticket;
END $$;

-- Acquire the bakery for one iceberg table. Returns the caller's
-- snowflake ticket; release deletes by ticket only.
--
-- Protocol: Lamport's 1978 distributed mutual exclusion algorithm with
-- the Ricart-Agrawala (1981) deferred-reply optimisation.
-- Modelled in docs/formal/Bakery.tla.
-- SECURITY DEFINER (search_path pinned; body is fully schema-qualified) so a
-- NON-superuser writer drives the R-A bakery with superuser privilege: the
-- pg_stat_replication alive-check sees every walsender (an INVOKER non-superuser
-- would see none → rule all peers dead → skip acks → the race this serializer
-- exists to prevent), and the spock.* reads + loopback claim-INSERT succeed. This
-- only changes the PG execution privilege, not the claim/ack/lock/ticket protocol
-- (TLA+-verified protocol-neutral; see docs/formal/Bakery.tla). The cold DML
-- itself still runs as the caller — _exec_iceberg_with_claim stays INVOKER.
CREATE FUNCTION coldfront._claim_iceberg_lock(
    p_iceberg_table text
) RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $$
DECLARE
    connstr           text     := coldfront._loopback_dsn();
    my_node           int      := current_setting('snowflake.node')::int;
    -- Local spock node name, used for the ack-wait join and the liveness
    -- slot-name computation (see coldfront._my_spock_node_name).
    my_node_name      name     := coldfront._my_spock_node_name();
    my_ticket         bigint;
    v_poll            int      := 0;
    -- coldfront.peer_alive_window_ms (superuser-only): a peer whose walsender
    -- has not replied within this window is treated as already acked (the
    -- R-A dead-peer escape); raise it on slow or lossy links, together with
    -- wal_sender_timeout. Read once per claim, so a change applies to the
    -- next claim.
    peer_alive_window_ms int := current_setting('coldfront.peer_alive_window_ms')::int;
    peer_alive_window interval := make_interval(secs => peer_alive_window_ms / 1000.0);
    -- The server's wal_sender_timeout in ms (reset_val, which a session SET
    -- cannot hide). The walsender asks a peer for a reply every half of it,
    -- so it must not be 0 and half of it must be below the window, or an
    -- idle live peer would be ruled dead.
    wal_sender_timeout_ms int := (SELECT reset_val::int FROM pg_settings
                                   WHERE name = 'wal_sender_timeout');
BEGIN
    IF connstr IS NULL OR connstr = '' THEN
        RAISE EXCEPTION 'coldfront: configure coldfront.loopback_dsn with this server''s unix-socket DSN (e.g. ''host=/var/run/postgresql dbname=coldfront user=coldfront'')';
    END IF;
    IF wal_sender_timeout_ms = 0 OR wal_sender_timeout_ms / 2 >= peer_alive_window_ms THEN
        RAISE EXCEPTION 'coldfront: wal_sender_timeout is % ms and coldfront.peer_alive_window_ms is % ms: the walsender asks a peer for a reply every wal_sender_timeout/2, so an idle live peer would be ruled dead',
            wal_sender_timeout_ms, peer_alive_window_ms
            USING HINT = 'Set wal_sender_timeout above 0 and below twice the window on every node, as the image does: ALTER SYSTEM SET wal_sender_timeout = ''15s''; SELECT pg_reload_conf();';
    END IF;

    -- Same-node serialization: hold a node-local advisory xact lock for this
    -- iceberg table across the whole claim+commit, so at most ONE cold writer
    -- per node is in the bakery at once. That keeps per-node concurrency at 1
    -- (the topology Bakery proves safe), so the cross-node Ricart-Agrawala
    -- ack/defer only ever arbitrates a single same-node claim. Cross-node
    -- writers are unaffected (advisory locks are instance-local); in the async
    -- path this runs after the parquet upload, so same-node uploads pipeline.
    PERFORM pg_advisory_xact_lock(hashtext('coldfront_iceberg:' || p_iceberg_table));

    -- Reap, then claim, in the loopback's own transaction (_insert_claim). Every
    -- lock taken there ends with that transaction, on commit or error alike, and
    -- the loopback session only touches coldfront.claims and coldfront.claim_acks
    -- (never a tiered view), so the lazy 'ice' attach never fires in it. No
    -- sync-rep: R-A's ack barrier replaces it.
    my_ticket := coldfront._loopback(format('SELECT coldfront._insert_claim(%L)', p_iceberg_table))::bigint;

    -- Wait phase — pure Ricart-Agrawala, NO timeout:
    --   (a) Same-node-min: I must be the minimum-ticket holder among
    --       same-node writers on this iceberg_table. Snowflake tickets
    --       are per-node monotonic + timestamped, so a smaller ticket
    --       means nextval was called earlier on this node.
    --   (b) Peer-ack: every ALIVE peer must have acked my ticket.
    --       "Alive" = a walsender row in pg_stat_replication for the peer
    --       with reply_time within coldfront.peer_alive_window_ms, whatever
    --       its state: a peer that has just reconnected is catching up and
    --       still alive. reply_time is the peer's apply-worker feedback:
    --       sent after it applies, every spock.feedback_frequency messages,
    --       and in answer to the walsender's keepalive, every
    --       wal_sender_timeout/2 on an idle link, which the check above
    --       keeps inside the window. A peer whose last reply is older
    --       than the window is implicitly treated as already-acked: this
    --       is R-A's dead-peer escape, the only way out of waiting
    --       indefinitely. There is no separate timeout: a peer that
    --       hasn't acked while alive is either deferring (legitimate per
    --       R-A's defer rule) or going to ack imminently. A same-node
    --       claim is released by the C XactCallback in coldfront.c at
    --       commit or abort, and one whose owner is gone is removed by
    --       the reaper.
    LOOP
        EXIT WHEN NOT EXISTS (
            SELECT 1 FROM coldfront.claims c
             WHERE c.iceberg_table = p_iceberg_table
               AND snowflake.get_node(c.ticket) = my_node
               AND c.ticket < my_ticket
        ) AND NOT EXISTS (
            SELECT 1 FROM spock.node n
             WHERE n.node_id <> (SELECT node_id FROM spock.local_node)
               AND NOT EXISTS (
                 SELECT 1 FROM coldfront.claim_acks a
                  WHERE a.ticket = my_ticket
                    AND a.ack_from_name = n.node_name
               )
               AND EXISTS (
                 -- Per-peer alive check: match the walsender on us serving
                 -- this peer's apply worker by computing the EXACT slot
                 -- name spock uses for the peer's subscription from us.
                 -- spock.spock_gen_slot_name replicates spock's
                 -- gen_slot_name + shorten_hash logic, so this handles
                 -- both the non-hashed form (sub name ≤16 chars) and the
                 -- 8-prefix+7-hex-hash form (sub name >16 chars, e.g. db10+).
                 -- IMMUTABLE so PG caches the call. No LIKE, no regex, no
                 -- node-name ambiguity (db1 vs db10).
                 SELECT 1 FROM pg_stat_replication r
                  WHERE r.reply_time > now() - peer_alive_window
                    AND r.application_name = spock.spock_gen_slot_name(
                          current_database()::name,
                          my_node_name,
                          ('sub_' || n.node_name || '_from_' || my_node_name)::name
                        )
               )
        );
        -- Waiter's poke: every ~1 s, re-touch our own claim row. The no-op UPDATE
        -- replicates and re-fires _on_claim_apply on every peer for our ticket, so
        -- a peer that deferred us behind a claim whose holder has since gone reaps
        -- it and acks. Nothing else would ever reach that peer. Modelled as the
        -- Poker process in docs/formal/Bakery.tla.
        v_poll := v_poll + 1;
        IF v_poll % 200 = 0 THEN
            PERFORM coldfront._loopback(format(
                'UPDATE coldfront.claims SET iceberg_table = iceberg_table WHERE ticket = %s',
                my_ticket));
        END IF;
        PERFORM pg_sleep(0.005);
    END LOOP;

    RETURN my_ticket;
END;
$$;

-- Wrapper called by the coldfront C hook for iceberg-only INSERT statements.
-- Acquires the bakery, runs the rewritten DML through duckdb.raw_query,
-- releases the bakery.
--
-- No EXCEPTION wrapper: pg_duckdb forbids subtransactions, so we cannot
-- catch errors here. If duckdb.raw_query raises, the user's PG xact aborts
-- (pg_duckdb's XactCallback rolls back the iceberg side too) and our claim
-- row may be left in coldfront.claims (a hard backend crash; an ERROR takes
-- the ABORT callback, which releases). An ownerless claim blocks its own node's
-- later writers and any peer that deferred behind it, until the reaper removes
-- it: on this node's next cold write to any table, on a peer claim's arrival,
-- or on the waiting peer's poke (see _insert_claim and _on_claim_apply).
-- C-bridge: enqueues a ticket for release at outer-tx-end. Drained by
-- the coldfront XactCallback registered in _PG_init (coldfront.c), which
-- fires at XACT_EVENT_COMMIT, after pg_duckdb's XACT_EVENT_PRE_COMMIT commit
-- of the Iceberg transaction, so the snapshot has landed by the time we DELETE
-- the claim (and at ABORT, where nothing landed).
CREATE FUNCTION coldfront._enqueue_release(p_ticket bigint)
RETURNS void
LANGUAGE c AS 'coldfront', 'coldfront_enqueue_release';

-- coldfront._reject_on_standby: refuse a cold-tier mutation on a physical standby.
-- PostgreSQL's read-only enforcement covers only its own writes; a cold write leaves
-- PG entirely (DuckDB to object storage), so the cold tier relies on this explicit
-- check to keep a replica out of the writer set. p_action names the attempted
-- operation in the error text. Callers invoke this before taking a claim, so a
-- standby stays outside the serialization protocol.
CREATE FUNCTION coldfront._reject_on_standby(p_action text) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
    IF pg_is_in_recovery() THEN
        RAISE EXCEPTION 'coldfront: cannot % on a read-only standby', p_action
            USING HINT = 'Standbys serve reads only; run this on the primary.';
    END IF;
END;
$$;

-- coldfront._bakery_armed: TRUE when this node is configured for the multi-writer
-- Ricart-Agrawala bakery (both GUCs the protocol needs are set). FALSE means a
-- node without them: a vanilla single node, which serializes cold writes with a
-- local advisory xact lock, or a node that runs Spock, which _take_iceberg_claim
-- refuses. The single source of truth for the gate.
CREATE FUNCTION coldfront._bakery_armed() RETURNS boolean
LANGUAGE sql STABLE AS $$
    SELECT NULLIF(current_setting('snowflake.node', true), '') IS NOT NULL
       AND NULLIF(current_setting('coldfront.loopback_dsn'), '') IS NOT NULL
$$;

-- coldfront._take_iceberg_claim: acquire the per-iceberg-table cold-write mutex,
-- held to transaction end. Mesh (_bakery_armed): take the R-A bakery claim and
-- enqueue its release for the C XactCallback. Vanilla (no Spock): a transaction-
-- scoped local advisory lock (auto-released at xact end); a node that runs Spock
-- without the bakery's settings is refused. Callers decide WHEN to call it
-- relative to their own work; it deliberately omits the standby
-- (pg_is_in_recovery) guard and any lock ordering, which stay in callers.
-- A transaction holds one claim per table: the claim lasts until commit, so a
-- later cold write to the same table is already covered, and a second claim
-- would reap the first (see _insert_claim). coldfront._claimed lists the
-- tables claimed so far; set_config with is_local reverts it when the
-- transaction ends.
CREATE FUNCTION coldfront._take_iceberg_claim(p_iceberg_ref text) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
    IF coldfront._bakery_armed() THEN
        IF p_iceberg_ref = ANY(string_to_array(current_setting('coldfront._claimed'), E'\n')) THEN
            RETURN;
        END IF;
        PERFORM coldfront._enqueue_release(coldfront._claim_iceberg_lock(p_iceberg_ref));
        PERFORM set_config('coldfront._claimed',
                           concat_ws(E'\n', NULLIF(current_setting('coldfront._claimed'), ''), p_iceberg_ref),
                           true);
    ELSE
        -- A node that runs Spock is a mesh node, and a mesh node serializes cold
        -- writes through the bakery alone: without its settings, refuse rather
        -- than take the node-local lock, which peers cannot see.
        IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'spock') THEN
            RAISE EXCEPTION 'coldfront: this node runs Spock, so a cold write needs the bakery, and % is not set',
                CASE WHEN NULLIF(current_setting('coldfront.loopback_dsn'), '') IS NULL
                     THEN 'coldfront.loopback_dsn' ELSE 'snowflake.node' END
                USING HINT = 'Set coldfront.loopback_dsn to this server''s unix-socket DSN (e.g. ''host=/var/run/postgresql dbname=coldfront user=coldfront'') and snowflake.node to this node''s id.';
        END IF;
        PERFORM pg_advisory_xact_lock(hashtext('coldfront_iceberg:' || p_iceberg_ref));
    END IF;
END;
$$;

-- Is the async-parquet upload ordering BOTH requested AND safe to use?
-- coldfront.iceberg_async_parquet asks to stage parquet OUTSIDE the bakery claim
-- (writers overlap on S3); that is correct ONLY when the loaded duckdb-iceberg
-- carries the bakery-aware-commit-refresh patch, which re-stamps
-- parent_snapshot_id at the commit POST under the claim. coldfront.iceberg_bakery_patch
-- asserts that patched binary is present — the coldfront patched images set BOTH
-- GUCs together in postgresql.conf (see docker/entrypoint.sh). Async requested
-- WITHOUT the patch asserted returns FALSE here, so _exec_iceberg_with_claim
-- falls back to the always-safe stock ordering instead of silently risking a
-- Lakekeeper 409 / commit loss. Formal basis: docs/formal — Bakery_race.cfg
-- (async WITHOUT the patch) violates NoLakekeeperConflict; Bakery_async.cfg
-- (async WITH the patch) is safe. STABLE so the planner can fold it.
CREATE FUNCTION coldfront._iceberg_async_active() RETURNS boolean
LANGUAGE sql STABLE AS $$
  SELECT current_setting('coldfront.iceberg_async_parquet')::boolean
     AND current_setting('coldfront.iceberg_bakery_patch')::boolean
$$;

-- Serialise one cold-tier Iceberg write so concurrent committers never hit a
-- Lakekeeper 409 CatalogCommitConflict (duckdb-iceberg does not rebase: the
-- losing transaction aborts and its batch has to be retried). This is THE
-- chokepoint every cold write
-- routes through, in every deployment.
--
-- The serializer is fundamentally a per-Iceberg-table mutex that scales by
-- deployment, chosen by the v_armed gate:
--
--   * Multi-node mesh (v_armed): the Ricart-Agrawala bakery. The upload ordering
--     adapts to the loaded duckdb-iceberg via coldfront.iceberg_async_parquet —
--     NEVER a 409 either way, only overlap-vs-serialized upload:
--       - patched iceberg (coldfront.iceberg_async_parquet ON AND the build
--         marker coldfront.iceberg_bakery_patch ON): stage the parquet FIRST
--         (writers overlap freely on S3), then claim the bakery only to wrap
--         pg_duckdb's deferred commit POST — the patch re-stamps parent_snapshot_id
--         at that POST, so the overlap is safe.
--       - stock iceberg (the default — OR async REQUESTED without the
--         iceberg_bakery_patch marker, which fails safe to here): claim the bakery
--         FIRST, then stage+commit inside the held ticket — stock stamps
--         parent_snapshot_id at stage time, so the upload must be serialized or a
--         peer captures a stale parent and 409s. _iceberg_async_active() gates the
--         async path on BOTH GUCs, so an unpatched deployment that flips only the
--         async flag can never silently 409 — it lands here and warns once.
--     The release is enqueued for the C XactCallback (fires on COMMIT and ABORT),
--     so an in-ticket staging failure can't orphan the claim.
--
--   * Vanilla single-node / no mesh (NOT v_armed): a transaction-scoped LOCAL
--     advisory lock is the same mutex without any Spock/snowflake/loopback
--     dependency. Taken BEFORE staging so a second backend on this node blocks
--     before it captures parent_snapshot_id (no stale-parent 409); auto-released
--     at commit. This is the path for plain PostgreSQL tiered deployments, which
--     have no snowflake.node / loopback_dsn configured.
--
-- _bakery_armed() probes the two GUCs the R-A bakery requires. current_setting(...,true)
-- returns NULL for an unrecognised GUC, so the probe is safe with no snowflake
-- extension loaded.
CREATE FUNCTION coldfront._exec_iceberg_with_claim(
    p_iceberg_table text,
    p_sql           text
) RETURNS void LANGUAGE plpgsql AS $$
DECLARE
    -- v_armed drives BOTH the acquire (via _take_iceberg_claim) and the async
    -- vs stock upload ordering below, so it stays a local here.
    v_armed   boolean := coldfront._bakery_armed();
    -- Async-parquet upload ordering: stage the parquet OUTSIDE the claim (writers
    -- overlap on S3), then take the claim only to wrap pg_duckdb's deferred commit
    -- POST. Correct ONLY on the bakery-aware duckdb-iceberg build (it re-stamps
    -- parent_snapshot_id at the POST, under the claim). _iceberg_async_active() is
    -- TRUE only when BOTH coldfront.iceberg_async_parquet AND the build marker
    -- coldfront.iceberg_bakery_patch are on; otherwise the stock ordering below is
    -- used (always safe). Never a 409 either way.
    v_async   boolean := coldfront._iceberg_async_active();
BEGIN
    -- A cluster assignment reads the centroids over pglocal, so a statement that
    -- names it needs pglocal attached in this backend. Tested on the statement
    -- rather than the table: this wrapper is the one chokepoint every C-generated
    -- cold write passes through, and only the ones carrying a lookup pay for it.
    IF strpos(p_sql, 'pglocal.') > 0 THEN
        PERFORM coldfront.ensure_pg_attached();
    END IF;
    -- This wrapper is the single-statement cold path; the cold sink
    -- (_cold_sink_step) and _cross_tier_move issue their own cold writes and
    -- carry the same guard. A hot write hits a PG heap, which PG rejects natively.
    PERFORM coldfront._reject_on_standby('execute a cold (Iceberg) write');
    -- Fail-safe, not fail-silent: if async was REQUESTED but the bakery-aware
    -- patch is not asserted, we use the stock ordering (always safe) and note it
    -- ONCE per session. Running async on stock iceberg would let a peer capture a
    -- stale parent and conflict: a 409 that aborts the losing transaction
    -- (docs/formal Bakery_race.cfg).
    -- RAISE LOG, not WARNING: this is a deployment-config advisory that belongs in
    -- the server log; it must NOT reach the client (a per-statement client message
    -- here would pollute output and break tools that scan write output for errors).
    IF NOT v_async
       AND current_setting('coldfront.iceberg_async_parquet')::boolean
       AND NOT current_setting('coldfront._async_downgrade_warned')::boolean THEN
        RAISE LOG 'coldfront: iceberg_async_parquet is on but iceberg_bakery_patch is not set — the loaded duckdb-iceberg is not the bakery-aware build; using the SAFE stock upload ordering instead of async. Set coldfront.iceberg_bakery_patch=on ONLY where duckdb-iceberg carries the bakery-aware-commit-refresh patch (the coldfront patched images set both GUCs).';
        PERFORM set_config('coldfront._async_downgrade_warned', 'on', false);
    END IF;
    IF v_armed AND v_async THEN
        -- Patched iceberg: upload parquet in the background, then take the claim
        -- only to wrap pg_duckdb's deferred commit POST.
        PERFORM duckdb.raw_query(p_sql);
        PERFORM coldfront._take_iceberg_claim(p_iceberg_table);
    ELSE
        -- Stock (armed) or vanilla: acquire FIRST (mesh R-A claim or local
        -- advisory, chosen inside the helper), then upload+commit inside it so no
        -- peer can capture a stale parent_snapshot_id.
        PERFORM coldfront._take_iceberg_claim(p_iceberg_table);
        PERFORM duckdb.raw_query(p_sql);
    END IF;
END;
$$;

-- _claim_iceberg_external acquires the bakery claim for an EXTERNAL committer —
-- the Go compactor (cmd/compactor), which rewrites small Iceberg data files into
-- fewer large ones and commits straight to Lakekeeper via apache/iceberg-go,
-- NOT through duckdb.raw_query. It takes the SAME claim _exec_iceberg_with_claim
-- takes — Ricart-Agrawala on a mesh (then arms the deferred release), or a local
-- advisory xact lock on vanilla — but runs no SQL: the caller performs its
-- iceberg-go RewriteDataFiles + commit WHILE the claim is held, then COMMITs its
-- PG transaction, which fires coldfront's C XactCallback to release the claim
-- (vanilla: the advisory lock auto-releases at xact end). The claim is thus held
-- across the whole external read->rewrite->commit. There is intentionally NO
-- async branch: iceberg-go has no bakery-aware re-stamp patch, so the compactor
-- must use the stock ordering (parent stamped under the claim). Formally cleared
-- in docs/formal — the compactor maps onto the stock-ordering writer
-- (Bakery.cfg); the patchless-async shortcut it must avoid is Bakery_race.
CREATE FUNCTION coldfront._claim_iceberg_external(p_iceberg_table text)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    PERFORM coldfront._reject_on_standby('compact (Iceberg write)');
    PERFORM coldfront._take_iceberg_claim(p_iceberg_table);
END;
$$;

-- coldfront._iceberg_drop_sql builds the DuckDB statements that drop one Iceberg
-- table from the catalog.
--
-- duckdb-iceberg takes the purge decision as an ATTACH option
-- (PURGE_REQUESTED), not a statement clause. The long-lived 'ice' attachment is
-- never purge-armed, which is precisely what a keep-files drop wants, so that
-- case goes straight through it and needs nothing of its own.
--
-- Only a purging drop needs its own attachment, and that one is not detached
-- afterwards: DuckDB refuses to detach a database while the transaction still
-- has staged work on it, and the drop stays staged until commit. A fixed alias
-- keeps reuse safe, because ice_drop_purge is armed identically on every call.
--
-- The reference is the stored iceberg_table string, which is the only thing that
-- names the right catalog table: an adopted relation's namespace is whatever it
-- was adopted from, unrelated to its PG schema.
CREATE FUNCTION coldfront._iceberg_drop_sql(
    p_ice_ref text,
    p_purge   boolean
) RETURNS text LANGUAGE sql STABLE AS $$
    SELECT CASE WHEN p_purge THEN
        format(
            'ATTACH IF NOT EXISTS %L AS ice_drop_purge (TYPE ICEBERG, ENDPOINT %L, '
            'AUTHORIZATION_TYPE NONE, ACCESS_DELEGATION_MODE %s, PURGE_REQUESTED true); '
            'DROP TABLE ice_drop_purge.%I.%I',
            current_setting('coldfront.warehouse', true),
            current_setting('coldfront.lakekeeper_endpoint', true),
            coldfront._attach_delegation_mode(),
            parts[2], parts[3])
    ELSE
        format('DROP TABLE %s', p_ice_ref)
    END
    FROM (SELECT parse_ident(p_ice_ref)) AS s(parts);
$$;

-- coldfront._unregister_iceberg removes the PostgreSQL side of a registered
-- Iceberg relation: the registry rows and the wrapper view, plus, for a tiered
-- table, the archiver's configuration and the rename that put the view in the
-- hot table's place. It performs no Iceberg I/O, so it is the entire
-- PG-visible effect of a drop and is exercisable without a catalog.
--
-- Order matters. The tiered_views DELETE also disarms the C DDL hook for these
-- relations, which is what permits the view drop that follows. For a tiered
-- table partition_config must go as well: the archiver resolves its work from
-- that table, so a surviving row would re-tier into a catalog entry that no
-- longer exists.
CREATE FUNCTION coldfront._unregister_iceberg(p_schema text, p_table text)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
    v_hot          text;
    v_iceberg_only boolean;
    v_hot_reg      regclass;
    v_companion    name;
    v_guard        name;
BEGIN
    SELECT hot_table, is_iceberg_only
      INTO v_hot, v_iceberg_only
      FROM coldfront.tiered_views
     WHERE schema_name = p_schema AND relname = p_table;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'coldfront: "%.%" is not a registered Iceberg table', p_schema, p_table
            USING HINT = 'Only tables registered in coldfront.tiered_views can be unregistered.';
    END IF;

    DELETE FROM coldfront.tiered_views
     WHERE schema_name = p_schema AND relname = p_table;

    -- The registration's vector layout goes with it: the centroids and the
    -- configuration describe the table this registration named, and a relation
    -- registered later under the same name must not inherit them.
    DELETE FROM coldfront.vector_centroids
     WHERE schema_name = p_schema AND table_name = p_table;
    DELETE FROM coldfront.vector_config
     WHERE schema_name = p_schema AND table_name = p_table;

    IF NOT v_iceberg_only THEN
        DELETE FROM coldfront.partition_config
         WHERE schema_name = p_schema AND table_name = p_table;
        DELETE FROM coldfront.archive_watermark
         WHERE schema_name = p_schema AND table_name = p_table;
    END IF;

    EXECUTE format('DROP VIEW IF EXISTS %I.%I', p_schema, p_table);

    -- Reverse the archiver's first-run rename so the hot table is addressable
    -- under its original name again. to_regclass resolves either quoting form
    -- of the stored hot_table, and yields NULL if it is already gone.
    IF NOT v_iceberg_only AND v_hot IS NOT NULL THEN
        v_hot_reg := to_regclass(v_hot);
        IF v_hot_reg IS NOT NULL THEN
            -- The generated companions exist only to make a vector scannable
            -- through the view, and the guards only to keep the view's readers
            -- and the cold tier exact. With the view gone the table is a plain
            -- table again, so it goes back the shape its owner gave it.
            FOR v_companion IN
                SELECT a.attname FROM pg_attribute a
                WHERE a.attrelid = v_hot_reg AND a.attnum > 0 AND NOT a.attisdropped
                  AND coldfront._is_vec_companion(a.attname, a.attgenerated)
            LOOP
                EXECUTE format('ALTER TABLE %s DROP COLUMN %I', v_hot_reg::text, v_companion);
            END LOOP;
            FOR v_guard IN
                SELECT c.conname FROM pg_constraint c
                WHERE c.conrelid = v_hot_reg AND c.contype = 'c'
                  AND starts_with(c.conname::text, coldfront._hot_guard_name(''))
            LOOP
                EXECUTE format('ALTER TABLE %s DROP CONSTRAINT %I', v_hot_reg::text, v_guard);
            END LOOP;
            EXECUTE format('ALTER TABLE %s RENAME TO %I', v_hot_reg::text, p_table);
        END IF;
    END IF;
END;
$$;

-- coldfront.drop_iceberg_table drops the Iceberg table backing a registered
-- relation. It is the inverse of coldfront.create_iceberg_table for an
-- iceberg-only table, and the inverse of tiering for a tiered one. What that
-- means for PostgreSQL differs because the modes differ:
--
--   * iceberg-only: the Iceberg table IS the relation, so nothing remains.
--   * tiered:       the Iceberg table is the cold tier, so the cold tier goes
--                   and the hot table returns under the relation's own name.
--
-- Both end states are announced with a NOTICE, because one call yielding two
-- outcomes is worth stating out loud rather than leaving to documentation.
-- An adopted read-only relation cannot be dropped; release it instead to leave
-- its Iceberg table intact.
--
-- p_purge has no default because both choices are irreversible in opposite
-- directions: true deletes the data and metadata objects, which for the cold
-- tier are the only copy of that data, while false drops the catalog entry and
-- leaves those objects in the object store where nothing reclaims them. The
-- caller states which one they mean.
--
-- Plain DROP TABLE / DROP VIEW stays blocked by the C DDL hook; this is the
-- sanctioned path. Reversible work runs first, and the catalog drop, the one
-- step whose effect outlives a ROLLBACK, runs last under the same per-table
-- claim every other cold write takes. A protected table (a Lakekeeper hold) is
-- refused by the catalog itself, and this path cannot override it: the drop
-- carries PURGE_REQUESTED but never force.
CREATE FUNCTION coldfront.drop_iceberg_table(
    p_schema text,
    p_table  text,
    p_purge  boolean
) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
    v_ice_ref      text;
    v_iceberg_only boolean;
    v_writable     boolean;
BEGIN
    IF p_purge IS NULL THEN
        RAISE EXCEPTION 'coldfront.drop_iceberg_table: p_purge is required (true or false)'
            USING HINT = 'true also deletes the Iceberg data and metadata objects; false drops only the catalog entry and leaves the objects in the object store.';
    END IF;

    SELECT iceberg_table, is_iceberg_only, is_writable
      INTO v_ice_ref, v_iceberg_only, v_writable
      FROM coldfront.tiered_views
     WHERE schema_name = p_schema AND relname = p_table;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'coldfront.drop_iceberg_table: "%.%" is not a registered Iceberg table', p_schema, p_table
            USING HINT = 'Only tables registered in coldfront.tiered_views can be dropped through this function.';
    END IF;

    -- Read access carries no authority to destroy. Handing the relation back is
    -- the exit a read-only registration has.
    IF NOT v_writable THEN
        RAISE EXCEPTION 'coldfront.drop_iceberg_table: "%.%" is adopted read-only', p_schema, p_table
            USING HINT = 'Use coldfront.release_iceberg_table() to hand it back, which leaves the Iceberg table untouched.';
    END IF;

    PERFORM coldfront._reject_on_standby('drop an Iceberg table');

    -- Combines PG writes (registry DELETEs, DROP VIEW, the rename) with a DuckDB
    -- write in one transaction, the same pattern create_iceberg_table needs.
    SET LOCAL duckdb.unsafe_allow_mixed_transactions = on;
    PERFORM coldfront.ensure_attached();

    -- GLOBAL LOCK ORDER, step 1: the bakery claim (resource B) before any
    -- ACCESS EXCLUSIVE (resource A), which is the order cutover_archive takes
    -- (see its comment). Dropping the view and renaming the hot table below both
    -- take A, so acquiring B first is what keeps a drop racing a cutover on the
    -- same table deadlock-free instead of inverting the order.
    PERFORM coldfront._take_iceberg_claim(v_ice_ref);

    -- GLOBAL LOCK ORDER, step 2: A, with the same circuit breaker and the same
    -- 100ms as cutover_archive, for the same reasons. A pending ACCESS EXCLUSIVE
    -- request queues ahead of new conflicting lockers, so every millisecond
    -- spent waiting is a millisecond the table is unavailable to new queries,
    -- and the bakery claim is held throughout, which stalls cold writes to this
    -- table on every node. Under deadlock_timeout so contention always yields
    -- lock_not_available rather than making this the deadlock victim. An
    -- operator who would rather wait sets their own lock_timeout, which is kept.
    IF current_setting('lock_timeout') IN ('0', '0ms') THEN
        SET LOCAL lock_timeout = '100ms';
    END IF;

    PERFORM coldfront._unregister_iceberg(p_schema, p_table);
    PERFORM duckdb.raw_query(coldfront._iceberg_drop_sql(v_ice_ref, p_purge));

    IF v_iceberg_only THEN
        RAISE NOTICE 'coldfront: dropped iceberg-only table "%.%" (purge=%); nothing remains in PostgreSQL',
            p_schema, p_table, p_purge;
    ELSE
        RAISE NOTICE 'coldfront: dropped the cold tier of "%.%" (purge=%); the hot table is retained as a plain table under that name',
            p_schema, p_table, p_purge;
    END IF;
END;
$$;

-- ============================================================================
-- DDL synchronization for tiered tables.
--
-- The coldfront C extension's ProcessUtility_hook intercepts DDL on a
-- registered tiered table's HOT heap / transparent view. The hook:
--   1. resolves the DDL target's OID and matches it against the registry
--      (by resolving tiered_views.hot_table / the view to OIDs — never by
--      string match, so it is schema-agnostic);
--   2. BLOCKS, with an actionable error: DROP TABLE / DROP VIEW / TRUNCATE
--      (would orphan/hide the cold tier) and column changes whose type has
--      no Iceberg mapping;
--   3. MIRRORS column-shape changes - ADD/DROP COLUMN, ALTER COLUMN TYPE,
--      RENAME COLUMN - onto the cold Iceberg tier through the bakery
--      (_mirror_iceberg_alter), so both tiers evolve together;
--   4. SUPPORTS RENAME TABLE (hot heap) and RENAME VIEW - neither touches the
--      Iceberg schema. It updates the registry and rebuilds the transparent
--      view + INSERT trigger from the current catalog state.
--
-- The helpers below are the SQL side of that hook. They are driven entirely
-- from pg_catalog, so they never assume a schema name and never hardcode a
-- column list. No plpgsql EXCEPTION blocks — pg_duckdb hard-rejects subtxns.
-- ============================================================================

-- Update the registry's hot_table after an ALTER TABLE ... RENAME of the hot
-- heap. p_new_hot_table is the new quoted qualified name (built by the C hook
-- from the post-rename catalog state). Keyed on the view's (schema, relname),
-- which a hot-table rename does not change.
CREATE FUNCTION coldfront._update_tiered_hot_table(
    p_schema text, p_view_name text, p_new_hot_table text
) RETURNS void LANGUAGE sql AS $$
    UPDATE coldfront.tiered_views
       SET hot_table = p_new_hot_table
     WHERE schema_name = p_schema AND relname = p_view_name;
$$;

-- Migrate the name-keyed registry + watermark rows when the transparent VIEW is
-- renamed. coldfront.tiered_views (keyed on schema+relname) and archive_watermark
-- (keyed on schema + bare view name == archiver SourceTable) both follow the new name.
-- _rebuild_tiered_view + the regenerated INSERT trigger look the registry/cutoff
-- up by the NEW name; without this migration the rebuild would not find the row,
-- v_has_cutoff would be false, and the rebuilt view would drop its cold (Iceberg)
-- UNION branch entirely — silently hiding all archived data. Called by the DDL
-- hook's view-rename branch BEFORE the rebuild so it reads the migrated rows.
-- Idempotent (no-op for whichever row does not exist yet).
CREATE FUNCTION coldfront._rename_tiered_view(
    p_schema text, p_old_view_name text, p_new_view_name text
) RETURNS void LANGUAGE sql AS $$
    UPDATE coldfront.tiered_views
       SET relname = p_new_view_name
     WHERE schema_name = p_schema AND relname = p_old_view_name;
    UPDATE coldfront.archive_watermark
       SET table_name = p_new_view_name
     WHERE schema_name = p_schema AND table_name = p_old_view_name;
$$;

-- coldfront._rebuild_tiered_view: regenerate the transparent UNION-ALL view
-- after a RENAME TABLE (hot heap) or RENAME VIEW. Driven entirely from
-- pg_catalog; the view projection is the runtime equivalent of
-- internal/view/view.go's GenerateViewSQL. (Also rebuilt after a mirrored
-- column-shape change, so the view's column set follows the hot heap.)
--
-- Called by the coldfront DDL hook for tiered views (rows with a non-NULL
-- hot_table). Iceberg-only views (is_iceberg_only = true, hot_table NULL) are
-- OUT OF SCOPE and short-circuit to a no-op: their column shape is owned by
-- create_iceberg_table(), not by a PG hot heap.
--
-- View strategy: DROP VIEW IF EXISTS ... CASCADE then CREATE VIEW (never
-- CREATE OR REPLACE). PG only lets CREATE OR REPLACE VIEW append columns at
-- the end; a DDL that drops/renames/reorders/retypes a column would fail it.
-- DROP changes the view OID, but the registry is keyed by (schema, relname),
-- which the DROP+CREATE leaves unchanged, so there is no row to re-point. On a
-- VIEW rename the hook migrates the registry key (old→new name) BEFORE calling
-- this, so p_view_name is always the current (post-rename) view name.
CREATE FUNCTION coldfront._rebuild_tiered_view(
    p_schema     text,
    p_view_name  text
)
RETURNS void
LANGUAGE plpgsql
SET client_min_messages = warning AS $$
DECLARE
    v_schema        text;
    v_view_name     text;          -- bare relname == archiver SourceTable == watermark table_name
    v_hot_table     text;          -- stored quoted, e.g. "public"."_events"
    v_iceberg       text;          -- DuckDB ref, e.g. ice.myapp.events
    v_partcol       text;
    v_is_ice_only   boolean;
    v_hot_schema    text;
    v_hot_relname   text;
    v_cutoff        timestamptz;
    v_cutoff_lit    text;          -- UTC text literal of the cutoff (matches view.go)
    v_has_cutoff    boolean;

    v_hot_proj      text := '';     -- hot SELECT list
    v_cold_proj     text := '';     -- cold SELECT list
    v_view_sql      text;

    r               record;
    n               int := 0;       -- live-column counter for projections
    cast_type       text;
    cold_type       text;
BEGIN
    -- 1. View identity IS the registry key (schema, relname). Resolve the
    -- registry columns by it; the row persists across the DROP+CREATE below
    -- because the name does not change.
    v_schema    := p_schema;
    v_view_name := p_view_name;

    SELECT tv.hot_table, tv.iceberg_table, tv.partition_col, tv.is_iceberg_only
    INTO v_hot_table, v_iceberg, v_partcol, v_is_ice_only
    FROM coldfront.tiered_views tv
    WHERE tv.schema_name = p_schema AND tv.relname = p_view_name;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'coldfront._rebuild_tiered_view: view %.% not registered', p_schema, p_view_name;
    END IF;

    -- Iceberg-only views have no hot table to read columns from: NO-OP.
    IF v_is_ice_only OR v_hot_table IS NULL OR v_partcol IS NULL THEN
        RETURN;
    END IF;

    -- hot_table is stored as a quoted identifier ("public"."_events").
    -- parse_ident handles the quoting/escaping (same pattern as
    -- _cold_sink_step). No EXCEPTION wrapper: pg_duckdb forbids subtxns.
    v_hot_schema  := (parse_ident(v_hot_table))[1];
    v_hot_relname := (parse_ident(v_hot_table))[2];

    -- 2. Watermark cutoff, keyed on (schema, bare view name == SourceTable).
    SELECT cutoff_time INTO v_cutoff
    FROM coldfront.archive_watermark
    WHERE schema_name = v_schema AND table_name = v_view_name;
    v_has_cutoff := (v_cutoff IS NOT NULL);
    IF v_has_cutoff THEN
        -- UTC text literal, matching internal/view/view.go cutoffLiteral().
        v_cutoff_lit := to_char(v_cutoff AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI:SS+00');
    END IF;

    -- 3. Post-DDL column list from the HOT table, attnum order, live columns.
    --    Build the hot/cold projections.
    FOR r IN
        SELECT a.attname,
               format_type(a.atttypid, a.atttypmod) AS pg_type,
               a.attidentity
        FROM pg_attribute a
        JOIN pg_class c      ON c.oid = a.attrelid
        JOIN pg_namespace nn ON nn.oid = c.relnamespace
        WHERE nn.nspname = v_hot_schema
          AND c.relname  = v_hot_relname
          AND a.attnum > 0
          AND NOT a.attisdropped
          AND NOT coldfront._is_vec_companion(a.attname, a.attgenerated)
        ORDER BY a.attnum
    LOOP
        cast_type := coldfront._iceberg_view_cast_type(r.pg_type);
        cold_type := coldfront._iceberg_storage_type(r.pg_type, r.attname);  -- Iceberg storage (BLOB, INTEGER, …)

        -- VIEW PROJECTIONS (view.go GenerateViewSQL).
        IF n > 0 THEN
            v_hot_proj  := v_hot_proj  || ', ';
            v_cold_proj := v_cold_proj || ', ';
        END IF;

        IF coldfront._is_vector_type(r.pg_type) THEN
            -- The hot branch reads the generated companion, aliased to the user's
            -- column name, so the pgvector column is never scanned.
            v_hot_proj  := v_hot_proj  || format('%I::%s AS %I',
                                                 coldfront._vec_companion(r.attname),
                                                 cast_type, r.attname);
            v_cold_proj := v_cold_proj || format('r[%L]::%s', r.attname, cast_type);
        ELSIF cast_type <> '' THEN
            -- VARCHAR-backed rich types (json/interval): cast both branches to
            -- the surface type so bootstrap and post-cutover views agree.
            v_hot_proj  := v_hot_proj  || quote_ident(r.attname) || '::' || cast_type;
            v_cold_proj := v_cold_proj || format('r[%L]::%s', r.attname, cast_type);
        ELSE
            -- No surface cast: the Iceberg storage type IS the surface. Cast
            -- BOTH branches to it (not just cold) so a native typmod like
            -- varchar(8) on the hot side does not survive bootstrap and then
            -- get dropped by the UNION at cutover ("cannot change data type of
            -- view column"). Storage types here are all PG-parseable.
            v_hot_proj  := v_hot_proj  || quote_ident(r.attname) || '::' || cold_type;
            v_cold_proj := v_cold_proj || format('r[%L]::%s', r.attname, cold_type);
        END IF;
        n := n + 1;
    END LOOP;

    IF n = 0 THEN
        RAISE EXCEPTION 'coldfront._rebuild_tiered_view: hot table %.% has no live columns',
            v_hot_schema, v_hot_relname;
    END IF;

    -- 4. Build the view DDL (DROP + CREATE; see header).
    IF NOT v_has_cutoff THEN
        v_view_sql := format(
            'CREATE VIEW %I.%I AS%s  SELECT %s FROM %I.%I',
            v_schema, v_view_name, E'\n', v_hot_proj, v_hot_schema, v_hot_relname);
    ELSE
        v_view_sql := format(
$ddl$CREATE VIEW %I.%I AS
  SELECT %s FROM %I.%I
  WHERE %I >= %L::timestamptz
  UNION ALL
  SELECT %s
  FROM duckdb.query(%L) AS t(r)
  WHERE r[%L] < %L::timestamptz$ddl$,
            v_schema, v_view_name,
            v_hot_proj, v_hot_schema, v_hot_relname,
            v_partcol, v_cutoff_lit,
            v_cold_proj,
            format('SELECT * FROM %s', v_iceberg),
            v_partcol, v_cutoff_lit);
    END IF;

    EXECUTE format('DROP VIEW IF EXISTS %I.%I CASCADE', v_schema, v_view_name);
    EXECUTE v_view_sql;

    -- 5. The registry key (schema, relname) is unchanged by the DROP+CREATE
    --    above (the view name is stable), so there is nothing to re-point. The
    --    cross-tier-move path is the post_parse_analyze hook + coldfront._cross_tier_move;
    --    it needs no per-view object here.

    -- 6. A column the DDL added gets the guard its type needs, on every node,
    --    since every node rebuilds its own view. The guard is validated as it
    --    is added, so the ALTER fails if a row breaks it, such as a default the
    --    guard refuses. A guard the archiver added and has not validated yet is
    --    left to the archiver.
    PERFORM coldfront._guard_hot_table(format('%I.%I', v_hot_schema, v_hot_relname)::regclass, true);
END;
$$;

-- coldfront._mirror_iceberg_alter: mirror a hot-table column DDL onto the cold
-- Iceberg tier — the ProcessUtility hook's write-side counterpart to
-- _rebuild_tiered_view. Called AFTER PG has executed the ALTER on the hot heap,
-- so ADD/ALTER-TYPE columns are already in pg_catalog and we read their
-- post-change type there (one source of truth, the same lookup
-- _rebuild_tiered_view uses). p_actions is a jsonb array of {op, col [, newcol]}
-- with op in 'add' | 'drop' | 'type' | 'rename'. Every type name maps through
-- coldfront._iceberg_storage_type, so hot and cold stay in correspondence
-- (smallint->INTEGER, jsonb->VARCHAR, numeric(P,S)->DECIMAL(P,S), bytea->BLOB,
-- inet -> rejected up front, …) — identical to create_iceberg_table.
--
-- The change serialises through the bakery via _exec_iceberg_with_claim with the
-- async-parquet ordering forced OFF: an ALTER is a metadata-only catalog CAS with
-- no parquet to overlap, so the claim-first (stock) ordering — the configuration
-- the TLA+ model proves safe — is both sufficient and the conservative choice.
--
-- On a Spock apply worker (session_replication_role = replica) the SHARED Iceberg
-- table was already evolved by the originator, so this is a NO-OP; the caller
-- still rebuilds the per-node view.
CREATE FUNCTION coldfront._mirror_iceberg_alter(
    p_iceberg_table text,
    p_hot_table     text,
    p_actions       jsonb
) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
    v_hot_schema  text := (parse_ident(p_hot_table))[1];
    v_hot_relname text := (parse_ident(p_hot_table))[2];
    act           jsonb;
    op            text;
    col           text;
    pg_type       text;
    ddl           text := '';
BEGIN
    -- Apply worker: the shared catalog was already evolved by the originator.
    IF current_setting('session_replication_role') = 'replica' THEN
        RETURN;
    END IF;

    FOR act IN SELECT * FROM jsonb_array_elements(p_actions) LOOP
        op  := act->>'op';
        col := act->>'col';
        IF ddl <> '' THEN ddl := ddl || '; '; END IF;

        IF op IN ('add', 'type') THEN
            -- Post-ALTER column type from the hot heap (the same pg_catalog
            -- lookup _rebuild_tiered_view uses), mapped to its Iceberg storage
            -- type. _iceberg_storage_type RAISES for any unsupported PG type,
            -- which rolls the whole ALTER back atomically (hot tier included).
            SELECT format_type(a.atttypid, a.atttypmod) INTO pg_type
            FROM pg_attribute a
            JOIN pg_class c      ON c.oid = a.attrelid
            JOIN pg_namespace nn ON nn.oid = c.relnamespace
            WHERE nn.nspname = v_hot_schema AND c.relname = v_hot_relname
              AND a.attname = col AND a.attnum > 0 AND NOT a.attisdropped;
            IF pg_type IS NULL THEN
                RAISE EXCEPTION 'coldfront: column "%" not found on hot table % after ALTER', col, p_hot_table;
            END IF;
            IF op = 'add' THEN
                ddl := ddl || format('ALTER TABLE %s ADD COLUMN IF NOT EXISTS %I %s',
                    p_iceberg_table, col, coldfront._iceberg_storage_type(pg_type, col));
            ELSE
                ddl := ddl || format('ALTER TABLE %s ALTER COLUMN %I TYPE %s',
                    p_iceberg_table, col, coldfront._iceberg_storage_type(pg_type, col));
            END IF;
        ELSIF op = 'drop' THEN
            ddl := ddl || format('ALTER TABLE %s DROP COLUMN IF EXISTS %I', p_iceberg_table, col);
        ELSIF op = 'rename' THEN
            ddl := ddl || format('ALTER TABLE %s RENAME COLUMN %I TO %I',
                p_iceberg_table, col, act->>'newcol');
        ELSE
            RAISE EXCEPTION 'coldfront._mirror_iceberg_alter: unknown op "%"', op;
        END IF;
    END LOOP;

    IF ddl = '' THEN RETURN; END IF;

    -- Mixed PG (the hot ALTER already ran) + DuckDB (this Iceberg ALTER) tx, the
    -- same allowance create_iceberg_table needs. Force the proven claim-first
    -- bakery ordering: metadata-only, nothing to overlap.
    SET LOCAL duckdb.unsafe_allow_mixed_transactions = on;
    SET LOCAL coldfront.iceberg_async_parquet = off;
    -- Attach the Iceberg catalog in THIS backend before the ALTER references it.
    -- A pure-DDL backend may not have 'ice' attached yet; create_iceberg_table and
    -- the INSERT trigger ensure_attached() before their duckdb.raw_query likewise.
    PERFORM coldfront.ensure_attached();
    PERFORM coldfront._exec_iceberg_with_claim(p_iceberg_table, ddl);
END;
$$;

-- ── Catalog documentation ────────────────────────────────────────────────────
-- Schema-level docs so `\d+ coldfront.*` / pg_description carry the same intent
-- the inline comments above describe. Tables exist by now (created above), so
-- these run cleanly at CREATE EXTENSION.
COMMENT ON SCHEMA coldfront IS 'pgEdge ColdFront: transparent PostgreSQL to Apache Iceberg tiering, plus decoupled iceberg-only tables.';
COMMENT ON TABLE coldfront.tiered_views IS 'Registry (keyed by schema, relname) of views the coldfront DML hook handles — tiered (hot+cold) and decoupled (iceberg-only).';
COMMENT ON TABLE coldfront.archive_watermark IS 'Per-tiered-table (schema, table) hot/cold cutoff: ts >= cutoff is hot (PG), ts < cutoff is cold (Iceberg).';
COMMENT ON TABLE coldfront.storage_secret IS 'Cold-store credential; materialized as a DuckDB PERSISTENT SECRET, replicated by value across a Spock mesh, excluded from pg_dump. A vended row stores no credential and materializes nothing: Lakekeeper issues per-table creds and ensure_attached uses ACCESS_DELEGATION_MODE VENDED_CREDENTIALS.';
COMMENT ON TABLE coldfront.partition_config IS 'Name-keyed per-table partition/tiering lifecycle config (period, hot_period, retention); replicates by value so every mesh node reads identical config.';
COMMENT ON TABLE coldfront.claims IS 'Ricart-Agrawala bakery: a writer''s outstanding iceberg-commit claim (iceberg_table, snowflake ticket); deleted on release.';
COMMENT ON TABLE coldfront.claim_acks IS 'Ricart-Agrawala bakery: per-peer acknowledgements of a claim, replicated back to the originating writer.';
COMMENT ON TABLE coldfront.deferred_acks IS 'Ricart-Agrawala bakery: acks a peer defers (it holds a smaller-ticket claim) until it releases its own.';
COMMENT ON TABLE coldfront._dummy_dml_target IS 'Internal: anchor relation for the DML rewrite hook; holds no user data.';
