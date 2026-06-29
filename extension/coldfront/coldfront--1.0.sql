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
    iceberg_table   text    NOT NULL,                  -- DuckDB ref: 'ice.default.events'
    partition_col   text,                              -- 'ts' (tiered) or NULL (iceberg-only)
    is_iceberg_only boolean NOT NULL DEFAULT false,
    PRIMARY KEY (schema_name, relname)
);

-- Archive watermark: one row per managed table, recording the cutoff time
-- that divides the hot tier (rows with partition_col >= cutoff_time, living
-- in the PG heap as _<table>) from the cold tier (rows older than cutoff,
-- living in Iceberg as ice.default.<table>). Written by the archiver at the
-- end of each archive cycle; read by the generated tiered view's hot/cold
-- UNION (internal/view/view.go) and by the coldfront rewriter's tier
-- classifier when deciding whether a predicate proves hot-only or cold-only.
--
-- PK on table_name because the archiver upserts this row every cycle via
-- ON CONFLICT (table_name) DO UPDATE (internal/watermark/watermark.go:Set).
-- Created with IF NOT EXISTS because the archiver can also materialize it
-- on first run before CREATE EXTENSION runs against the DB.
CREATE TABLE IF NOT EXISTS coldfront.archive_watermark (
    table_name  text        PRIMARY KEY,
    cutoff_time timestamptz NOT NULL
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
-- carried by pg_dump (no pg_extension_config_dump), and it is added to the
-- Spock repset so the row replicates by value to every mesh node — unlike an
-- FDW user-mapping (which pg_dump DOES dump and which does not replicate).
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
    CONSTRAINT ss_type_enum  CHECK (storage_type IN ('s3','azure')),
    CONSTRAINT ss_s3_creds   CHECK (storage_type <> 's3'
                                     OR (key_id IS NOT NULL AND secret IS NOT NULL)),
    CONSTRAINT ss_azure_conn CHECK (storage_type <> 'azure'
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
  wh text := current_setting('coldfront.warehouse', true);
  ep text := current_setting('coldfront.lakekeeper_endpoint', true);
BEGIN
  IF wh IS NOT NULL AND wh <> '' AND ep IS NOT NULL AND ep <> '' THEN
    -- iceberg (and avro transitively) are auto-installed/auto-loaded by
    -- pg_duckdb when this ATTACH (TYPE ICEBERG, ...) fires, gated by
    -- duckdb.autoinstall_known_extensions / autoload_known_extensions. No
    -- explicit install or per-session LOAD needed.
    PERFORM duckdb.raw_query(format(
      'ATTACH IF NOT EXISTS %L AS ice (TYPE ICEBERG, ENDPOINT %L, '
      'AUTHORIZATION_TYPE NONE, ACCESS_DELEGATION_MODE NONE)',
      wh, ep
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
    -- httpfs (s3) already loaded as a side-effect of the ATTACH above; azure does
    -- not, so its lazy autoload would otherwise fire later as the non-superuser
    -- app role and hit pg_duckdb's LocalFileSystem block (issue #17). Pre-load it
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
-- READ_ONLY on the ATTACH is deliberate: this connection is for *reading*
-- PG tables to feed Iceberg writes; coldfront never wants writes flowing
-- back through pglocal into PG.
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
-- _exec_iceberg_with_claim/_tiered_insert_cold emitted into rewrites,
-- _enqueue_release + the R-A bakery _claim/_release_iceberg_lock on the cold-write
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
                        '_exec_iceberg_with_claim', '_tiered_insert_cold',
                        -- cross-tier move: the hook rewrites a partition-column
                        -- UPDATE to SELECT _cross_tier_move(...), which serialises
                        -- cold rows via _move_row_literal.
                        '_cross_tier_move', '_move_row_literal', '_move_pg_row_literal',
                        '_enqueue_release',
                        -- R-A bakery coordination (mesh cold writes); SECURITY
                        -- DEFINER, so the app role just needs EXECUTE — the
                        -- spock/dblink/pg_stat_replication access happens as owner.
                        '_claim_iceberg_lock', '_release_iceberg_lock')
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
  -- INSERT path (coldfront._tiered_insert_cold) shares the hot side's sequence
  -- via nextval() AS THE INVOKER, so the app role needs USAGE on it. Derived from
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
  r coldfront.storage_secret;
BEGIN
  SELECT * INTO r FROM coldfront.storage_secret LIMIT 1;
  IF NOT FOUND THEN RETURN; END IF;
  PERFORM duckdb.raw_query(format('CREATE OR REPLACE PERSISTENT SECRET %I (%s)',
                                  r.name, coldfront._build_storage_secret_opts(r)));
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
       (name, storage_type, key_id, secret, endpoint, region, url_style, use_ssl, connection_string)
       VALUES (p.name, p.storage_type, p.key_id, p.secret, p.endpoint,
               p.region, p.url_style, p.use_ssl, p.connection_string)
  ON CONFLICT (name) DO UPDATE SET
       storage_type      = EXCLUDED.storage_type,
       key_id            = EXCLUDED.key_id,
       secret            = EXCLUDED.secret,
       endpoint          = EXCLUDED.endpoint,
       region            = EXCLUDED.region,
       url_style         = EXCLUDED.url_style,
       use_ssl           = EXCLUDED.use_ssl,
       connection_string = EXCLUDED.connection_string;
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
    p_region, p_url_style, p_use_ssl, NULL
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
    'us-east-1', 'path', false, p_connection_string
  )::coldfront.storage_secret);
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
      AND a.attnum > 0 AND NOT a.attisdropped;

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

-- _tiered_insert_cold: cold-side handler for a tiered-view INSERT.
--
-- The C hook splits the user's INSERT into two SQL halves wrapped in a
-- CTE: the hot half is a plain `INSERT INTO _events SELECT … FROM
-- (source) WHERE partition_col >= cutoff` (PG-native, set-based, IDENTITY
-- auto-fills); the cold half is `SELECT coldfront._tiered_insert_cold(…)`.
--
-- This function opens a cursor on `<source> WHERE partition_col < cutoff`
-- and walks rows one at a time. Per row, it calls nextval() on the
-- IDENTITY sequence (advancing the same shared sequence the hot
-- side uses, so the two tiers' ids never collide) and accumulates a
-- VALUES tuple. Every batch_size rows it flushes one duckdb.raw_query
-- with the accumulated VALUES — one Iceberg snapshot per batch.
--
-- Source is read once on the cold side via the cursor; the hot side
-- reads source independently via PG. Two scans over the same table; no
-- staging.
--
-- IDENTITY handling: when the user's target list omits the IDENTITY
-- column, nextval(seq) is injected positionally for that column. When
-- the user supplied it, their value flows through unchanged (and
-- nextval is not called).
CREATE OR REPLACE FUNCTION coldfront._tiered_insert_cold(
    p_view_schema text,
    p_view_name   text,
    p_target_cols text[],
    p_source_sql  text
) RETURNS bigint
LANGUAGE plpgsql AS $$
DECLARE
    v_hot_table     text;
    v_iceberg       text;
    v_partcol       text;
    v_cutoff        timestamptz;
    v_hot_schema    text;
    v_hot_relname   text;
    v_identity_col  text;
    v_identity_seq  text;
    full_cols       text[];
    full_types      text[];
    full_defaults   text[];
    cursor_proj     text;
    target_csv      text;
    cur             refcursor;
    rec             record;
    payload         jsonb;
    row_lit         text;
    val_text        text;
    cold_buf        text := '';
    cold_count      int  := 0;
    total           bigint := 0;
    -- Rows accumulated per Iceberg append (one snapshot / Parquet file per flush).
    -- Larger ⇒ far fewer, larger files; the only cost is the in-memory VALUES
    -- string per flush. The sub-threshold remainder is always flushed after the
    -- loop (see below), so a small write is one file and is never lost.
    batch_size      int  := current_setting('coldfront.cold_write_batch_size')::int;  -- GUC, default 10000
    i               int;
    col             text;
    my_ticket       bigint;
    v_armed         boolean := NULLIF(current_setting('snowflake.node', true), '') IS NOT NULL
                           AND NULLIF(current_setting('coldfront.dblink_self', true), '') IS NOT NULL;
BEGIN
    -- Mixed-tier writes inside one PG tx (PG hot INSERT plus DuckDB
    -- raw_query writes for cold) need pg_duckdb's mixed-write guard
    -- relaxed.
    SET LOCAL duckdb.unsafe_allow_mixed_transactions = on;
    -- Pin bytea text output to hex so to_jsonb(rec)->>bytea_col is a stable
    -- '\xHEX' string that the per-row serialiser below rebuilds via from_hex().
    SET LOCAL bytea_output = 'hex';

    -- Lookup view registry + watermark.
    SELECT tv.hot_table, tv.iceberg_table, tv.partition_col,
           COALESCE(aw.cutoff_time, '-infinity'::timestamptz)
    INTO v_hot_table, v_iceberg, v_partcol, v_cutoff
    FROM coldfront.tiered_views tv
    LEFT JOIN coldfront.archive_watermark aw ON aw.table_name = p_view_name
    WHERE tv.schema_name = p_view_schema AND tv.relname = p_view_name;

    IF v_hot_table IS NULL THEN
        RAISE EXCEPTION 'coldfront._tiered_insert_cold: view % is not registered or is iceberg-only',
            p_view_name;
    END IF;

    -- hot_table is stored quoted ("public"."_events"); parse_ident
    -- handles the quoting/escaping that simple split_part wouldn't.
    -- No EXCEPTION wrapper — pg_duckdb forbids plpgsql subtransactions
    -- (SAVEPOINT) under its tx callback. parse_ident raises a clear
    -- error of its own if the input is malformed.
    v_hot_schema  := (parse_ident(v_hot_table))[1];
    v_hot_relname := (parse_ident(v_hot_table))[2];

    -- Serialise the whole cold-insert loop ONCE (it issues many batched
    -- raw_query INSERTs in this single transaction; all commit together at
    -- xact end). Same v_armed gate as _exec_iceberg_with_claim: multi-node →
    -- one R-A claim (released by the C XactCallback at commit); single-node →
    -- one local advisory xact lock. Taken before the loop so the whole batch
    -- sequence commits under one serialization.
    IF v_armed THEN
        my_ticket := coldfront._claim_iceberg_lock(v_iceberg);
        PERFORM coldfront._enqueue_release(my_ticket);
    ELSE
        PERFORM pg_advisory_xact_lock(hashtext('coldfront_iceberg:' || v_iceberg));
    END IF;

    -- Identity column + its sequence (NULL if no IDENTITY column).
    SELECT a.attname,
           pg_get_serial_sequence(format('%I.%I', v_hot_schema, v_hot_relname),
                                  a.attname)
    INTO v_identity_col, v_identity_seq
    FROM pg_attribute a
    JOIN pg_class c     ON c.oid = a.attrelid
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = v_hot_schema AND c.relname = v_hot_relname
      AND a.attidentity IN ('a', 'd')
      AND a.attnum > 0 AND NOT a.attisdropped
    LIMIT 1;

    -- Full underlying column list + types + DEFAULT expressions, in
    -- attnum order. The cold INSERT VALUES tuple must match this layout
    -- positionally (DuckDB-iceberg has no DEFAULT/IDENTITY, no targeted
    -- col-list). Defaults are picked up so omitted-with-DEFAULT columns
    -- can be evaluated PG-side per row by including them in the cursor's
    -- projection — same semantics as a hot-side INSERT.
    SELECT array_agg(a.attname                                ORDER BY a.attnum),
           array_agg(format_type(a.atttypid, a.atttypmod)      ORDER BY a.attnum),
           array_agg(pg_get_expr(d.adbin, d.adrelid)           ORDER BY a.attnum)
    INTO full_cols, full_types, full_defaults
    FROM pg_attribute a
    JOIN pg_class c     ON c.oid = a.attrelid
    JOIN pg_namespace n ON n.oid = c.relnamespace
    LEFT JOIN pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
    WHERE n.nspname = v_hot_schema AND c.relname = v_hot_relname
      AND a.attnum > 0 AND NOT a.attisdropped;

    target_csv := array_to_string(
        ARRAY(SELECT quote_ident(c) FROM unnest(p_target_cols) c), ', ');

    -- Cursor SELECT list: every underlying column in attnum order,
    -- sourced from coldfront_src for user-targeted cols, IDENTITY-stub
    -- for the IDENTITY column we'll override per row, DEFAULT
    -- expression for omitted-with-DEFAULT, NULL otherwise.
    cursor_proj := '';
    FOR i IN 1 .. array_length(full_cols, 1) LOOP
        col := full_cols[i];
        IF i > 1 THEN cursor_proj := cursor_proj || ', '; END IF;
        IF col = ANY(p_target_cols) THEN
            cursor_proj := cursor_proj || format(
                'coldfront_src.%I AS %I', col, col);
        ELSIF v_identity_col IS NOT NULL AND col = v_identity_col THEN
            cursor_proj := cursor_proj || format(
                'NULL::%s AS %I', full_types[i], col);
        ELSIF full_defaults[i] IS NOT NULL THEN
            cursor_proj := cursor_proj || format(
                '(%s) AS %I', full_defaults[i], col);
        ELSE
            cursor_proj := cursor_proj || format(
                'NULL::%s AS %I', full_types[i], col);
        END IF;
    END LOOP;

    OPEN cur FOR EXECUTE format(
        'SELECT %s FROM (%s) AS coldfront_src(%s) WHERE %I < %L',
        cursor_proj, p_source_sql, target_csv, v_partcol, v_cutoff);

    LOOP
        FETCH cur INTO rec;
        EXIT WHEN NOT FOUND;

        payload := to_jsonb(rec);
        row_lit := '';

        -- The cursor already projected every underlying column with the
        -- right value (user-supplied / DEFAULT / NULL stub for IDENTITY),
        -- so per row we just emit literals from `rec`. The one override
        -- is the IDENTITY column when the user omitted it: substitute
        -- nextval() so cold ids share the hot side's sequence.
        FOR i IN 1 .. array_length(full_cols, 1) LOOP
            col := full_cols[i];
            IF i > 1 THEN row_lit := row_lit || ', '; END IF;

            IF v_identity_col IS NOT NULL
               AND col = v_identity_col
               AND NOT (v_identity_col = ANY(p_target_cols)) THEN
                row_lit := row_lit || nextval(v_identity_seq)::text;
            ELSIF payload ? col AND (payload->col) IS NOT NULL
                  AND jsonb_typeof(payload->col) <> 'null' THEN
                val_text := payload->>col;
                IF full_types[i] = 'bytea' THEN
                    -- val_text is PG bytea text '\xHEX' (bytea_output pinned to
                    -- hex above). DuckDB stores a BLOB, so rebuild the exact
                    -- bytes from the hex digits via from_hex(). Passing the
                    -- '\xHEX' string straight to a BLOB column would make DuckDB
                    -- mis-parse the \x escapes and corrupt the value.
                    row_lit := row_lit || format('from_hex(%L)', substr(val_text, 3));
                ELSE
                    row_lit := row_lit || quote_literal(val_text);
                END IF;
            ELSE
                row_lit := row_lit || 'NULL';
            END IF;
        END LOOP;

        cold_buf := cold_buf
                 || (CASE WHEN cold_count = 0 THEN '' ELSE ', ' END)
                 || '(' || row_lit || ')';
        cold_count := cold_count + 1;
        total      := total + 1;

        IF cold_count >= batch_size THEN
            PERFORM duckdb.raw_query(format(
                'INSERT INTO %s VALUES %s', v_iceberg, cold_buf));
            cold_buf   := '';
            cold_count := 0;
        END IF;
    END LOOP;
    CLOSE cur;

    IF cold_count > 0 THEN
        PERFORM duckdb.raw_query(format(
            'INSERT INTO %s VALUES %s', v_iceberg, cold_buf));
    END IF;

    RETURN total;
END;
$$;

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
--   cold→hot  cold, e>=cut : the row is read from Iceberg into the heap (INSERT
--                            … FROM iceberg_scan) and removed from Iceberg.
--   stay-cold cold, e<cut  : removed from Iceberg and re-added with the new ts.
-- Same-tier changes are in-place; crossings write the OTHER tier and remove from
-- the origin (different relations) — no same-relation overlap.
--
-- Cold tier: ONE raw_query (DELETE-set + INSERT-set = one MetaTransaction = one
-- snapshot, the replay_archive_delta idiom; the single delete-bearing op pg_duckdb
-- allows per table per tx) under ONE claim (never per-row tickets). cold→hot reads
-- Iceberg with iceberg_scan, which pg_duckdb permits inside a function only with
-- duckdb.unsafe_allow_execution_inside_functions — the move needs it because the
-- legs are deparsed and run together here. The cold rows destined to stay/return
-- cold are serialised by VALUE from an iceberg_scan cursor (so no uncommitted-
-- staging visibility problem and no second claim); hot→cold rows are serialised
-- from a heap cursor. DELETE is by the OLD primary key; old/new keys differ (the
-- partition column changed) so it never hits a just-inserted row.
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
    v_cold_read   text;          -- iceberg_scan surface projection: r[col]::cast AS col
    v_has_ident   boolean;
    v_inner       text;          -- "SELECT v_cold_read FROM iceberg_scan(ice) r WHERE r[pc] < cut"
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
    my_ticket     bigint;
    v_armed       boolean := NULLIF(current_setting('snowflake.node', true), '') IS NOT NULL
                         AND NULLIF(current_setting('coldfront.dblink_self', true), '') IS NOT NULL;
BEGIN
    SET LOCAL duckdb.unsafe_allow_execution_inside_functions = on;
    SET LOCAL duckdb.unsafe_allow_mixed_transactions = on;
    SET LOCAL coldfront.iceberg_async_parquet = off;
    SET LOCAL bytea_output = 'hex';

    SELECT tv.hot_table, tv.iceberg_table, tv.partition_col, aw.cutoff_time
    INTO v_hot_table, v_iceberg, v_partcol, v_cutoff
    FROM coldfront.tiered_views tv
    LEFT JOIN coldfront.archive_watermark aw ON aw.table_name = p_view_name
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
    -- (the iceberg_scan surface projection r[col]::cast AS col) derive from the
    -- arrays, mirroring _rebuild_tiered_view's casts (one source of truth via
    -- _iceberg_view_cast_type / _iceberg_storage_type; view cast, else storage).
    SELECT array_agg(a.attname ORDER BY a.attnum),
           array_agg(format_type(a.atttypid, a.atttypmod) ORDER BY a.attnum),
           bool_or(a.attidentity <> '')
    INTO full_cols, full_types, v_has_ident
    FROM pg_attribute a JOIN pg_class c ON c.oid = a.attrelid
    JOIN pg_namespace nn ON nn.oid = c.relnamespace
    WHERE nn.nspname = v_hot_schema AND c.relname = v_hot_relname
      AND a.attnum > 0 AND NOT a.attisdropped;
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

    v_inner := format('SELECT %s FROM iceberg_scan(%L) r WHERE r[%L] < %s',
                      v_cold_read, v_iceberg, v_partcol, v_cut_lit);
    PERFORM coldfront.ensure_attached();

    -- Reject a cold→hot target with no covering hot partition, naming the VIEW
    -- (never the internal heap name): the heap is RANGE-partitioned with no default
    -- partition, so a row LANDING hot (cold→hot, or stay-hot whose new ts crosses a
    -- hot-partition boundary) would otherwise raise PG's "no partition of relation
    -- _events". Collect the distinct new-ts values of all hot-landing rows from both
    -- tiers — cold via iceberg_scan, hot via the heap — kept in SEPARATE queries so
    -- one never mixes iceberg_scan (DuckDB) with pg_catalog (which pg_duckdb cannot
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
    -- mesh → R-A bakery, vanilla → local advisory xact lock.
    IF v_armed THEN
        my_ticket := coldfront._claim_iceberg_lock(v_iceberg);
        PERFORM coldfront._enqueue_release(my_ticket);
    ELSE
        PERFORM pg_advisory_xact_lock(hashtext('coldfront_iceberg:' || v_iceberg));
    END IF;

    -- ── Capture the moved rows by VALUE (no iceberg_scan in any modifying stmt) ──
    -- Affected COLD rows are read with a SELECT cursor over iceberg_scan (a pure
    -- read, which pg_duckdb runs in DuckDB — a modifying INSERT…FROM iceberg_scan
    -- would instead trip pg_duckdb's "cannot modify a Postgres table" path). Each
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
            ins_arr := ins_arr || ('(' || coldfront._move_row_literal(payload, full_cols, full_types, v_partcol) || ')');
        ELSE
            -- cold→hot: add to the heap (PG literal tuple, partition column = e).
            heap_arr := heap_arr || ('(' || coldfront._move_pg_row_literal(payload, full_cols, v_partcol) || ')');
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
        ins_arr := ins_arr || ('(' || coldfront._move_row_literal(payload, full_cols, full_types, v_partcol) || ')');
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
-- cf_new_ts) as a DuckDB positional VALUES tuple for the Iceberg INSERT, in attnum
-- order: the partition column takes cf_new_ts; bytea is rebuilt with from_hex on the
-- hex text (bytea_output is pinned to hex by the caller); a NULL is NULL; everything
-- else is a quoted literal DuckDB coerces to the storage type. Mirrors
-- _tiered_insert_cold's per-row serialiser.
CREATE FUNCTION coldfront._move_row_literal(
    p_payload jsonb, p_cols text[], p_types text[], p_partcol text
) RETURNS text
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
    row_lit  text := '';
    col      text;
    val_text text;
    i        int;
BEGIN
    FOR i IN 1 .. array_length(p_cols, 1) LOOP
        col := p_cols[i];
        IF i > 1 THEN row_lit := row_lit || ', '; END IF;
        IF col = p_partcol THEN
            row_lit := row_lit || quote_literal(p_payload->>'cf_new_ts');
        ELSIF p_payload ? col AND jsonb_typeof(p_payload->col) <> 'null' THEN
            val_text := p_payload->>col;
            IF p_types[i] = 'bytea' THEN
                row_lit := row_lit || format('from_hex(%L)', substr(val_text, 3));
            ELSE
                row_lit := row_lit || quote_literal(val_text);
            END IF;
        ELSE
            row_lit := row_lit || 'NULL';
        END IF;
    END LOOP;
    RETURN row_lit;
END;
$$;

-- coldfront._move_pg_row_literal: the cold→hot counterpart of _move_row_literal —
-- render a captured row as a positional VALUES tuple for the PG heap INSERT. The
-- partition column takes cf_new_ts; every other value is an unknown-typed literal
-- (quote_nullable) that PG coerces to the heap column type on INSERT (so bytea hex
-- and jsonb text round-trip with no per-type handling). NULL stays NULL.
CREATE FUNCTION coldfront._move_pg_row_literal(
    p_payload jsonb, p_cols text[], p_partcol text
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
    visibility    text;
    scratch_tbl   text;
    scratch_qual  text;
    n_applied     bigint;
    total_applied bigint := 0;
BEGIN
    -- Resolve column / PK order ONCE per procedure call (stable for the
    -- lifetime of the partition's archive cycle).
    SELECT array_agg(a.attname ORDER BY a.attnum)
    INTO col_names
    FROM pg_attribute a
    JOIN pg_class c ON c.oid = a.attrelid
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = p_schema AND c.relname = p_part
      AND a.attnum > 0 AND NOT a.attisdropped;

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
    SELECT string_agg(quote_ident(name), ', ' ORDER BY ord) INTO col_list
    FROM unnest(col_names) WITH ORDINALITY AS u(name, ord);

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
             SELECT * FROM %s WHERE %s LIMIT %s',
            scratch_qual, delta_tbl, visibility, batch_size);

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
    my_ticket    bigint;
    -- Same gate the cold WRITE path uses (_exec_iceberg_with_claim): mesh takes
    -- the R-A bakery claim, vanilla a local xact advisory lock — on the SAME
    -- per-iceberg-table key. Acquiring it here serializes the cutover against
    -- concurrent cold writers through their own mutex.
    v_armed   boolean := NULLIF(current_setting('snowflake.node', true), '') IS NOT NULL
                     AND NULLIF(current_setting('coldfront.dblink_self', true), '') IS NOT NULL;
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
     WHERE table_name = p_source;
    IF NOT FOUND THEN
        INSERT INTO coldfront.archive_watermark (table_name, cutoff_time)
        VALUES (p_source, p_new_cutoff);
    END IF;

    -- GLOBAL LOCK ORDER, step 1 — take the bakery (resource B) BEFORE any
    -- partition ACCESS EXCLUSIVE (resource A). Every path that holds both
    -- acquires B before A, so no wait-for cycle can form. Held to this proc's
    -- COMMIT: mesh release is enqueued for the C XactCallback (fires after
    -- pg_duckdb's, so the iceberg side is settled), vanilla advisory is
    -- xact-scoped. Deliberately NO lock_timeout on this acquire — we WANT to
    -- wait out an in-flight cold writer's full commit so its RowExclusive on the
    -- partition is gone before we ask for ACCESS EXCLUSIVE.
    IF v_armed THEN
        my_ticket := coldfront._claim_iceberg_lock(p_iceberg_ref);
        PERFORM coldfront._enqueue_release(my_ticket);
    ELSE
        PERFORM pg_advisory_xact_lock(hashtext('coldfront_iceberg:' || p_iceberg_ref));
    END IF;

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
-- Iceberg from row 1 — no PG heap, no hot tier, no archiver. The PG side is
-- a thin wrapper view that projects iceberg_scan() into PG-typed columns
-- plus an INSTEAD OF INSERT trigger that routes writes to
-- duckdb.raw_query('INSERT INTO ice...'). UPDATE/DELETE on the wrapper view
-- are intercepted by the coldfront post_parse_analyze hook (which short-
-- circuits to TIER_COLD when the registry row has is_iceberg_only=true).
--
-- The supported column types match the canonical map in
-- cmd/archiver/main.go pgFormatTypeToDuckDB. Anything outside the set is
-- rejected at create time. See ARCHITECTURE_DECOUPLED.md for the full table.
-- ============================================================================

-- Map a PG type name (canonical or common alias) to the DuckDB/Iceberg
-- storage type used in CREATE TABLE on the attached catalog. Raises on any
-- type that cannot round-trip cleanly — silent VARCHAR fallback would lose
-- data identity at write time, so we refuse it.
CREATE OR REPLACE FUNCTION coldfront._iceberg_storage_type(p_pg_type text)
RETURNS text
LANGUAGE plpgsql IMMUTABLE STRICT AS $$
DECLARE
    t text := lower(trim(p_pg_type));
BEGIN
    -- Numeric / boolean
    IF t IN ('bigint', 'int8')             THEN RETURN 'BIGINT';   END IF;
    IF t IN ('integer', 'int', 'int4')     THEN RETURN 'INTEGER';  END IF;
    -- Iceberg has no 16-bit integer; widen smallint to INTEGER (lossless,
    -- same principle as oid → BIGINT). duckdb-iceberg rejects SMALLINT outright.
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
    IF t = 'oid'   THEN RETURN 'BIGINT';  END IF;  -- 4-byte unsigned safe-widen
    -- Variable-precision strings
    IF t LIKE 'character varying%' OR t LIKE 'varchar%'
       OR t LIKE 'character(%' OR t LIKE 'char(%' OR t = 'character'
    THEN RETURN 'VARCHAR'; END IF;
    -- Bounded numeric
    IF t ~ '^numeric\(\d+\s*,\s*\d+\)$' OR t ~ '^decimal\(\d+\s*,\s*\d+\)$' THEN
        RETURN 'DECIMAL' || substring(t FROM '\(.*\)');
    END IF;
    IF t IN ('numeric', 'decimal') THEN
        RAISE EXCEPTION 'coldfront: unbounded numeric not supported in iceberg; use numeric(P,S) with P<=38';
    END IF;
    -- View-cast types: stored as VARCHAR, surfaced via wrapper view as native PG type
    IF t IN ('jsonb', 'json', 'interval') THEN RETURN 'VARCHAR'; END IF;
    -- inet/cidr are NOT supported: pg_duckdb rejects PG inet (Oid 869) in any
    -- query it plans, and every Iceberg-backed view read is planned by
    -- pg_duckdb, so there is no cast that makes them readable. Store IP data
    -- as text instead.

    RAISE EXCEPTION 'coldfront: PG type % has no Iceberg-compatible mapping. Supported: bigint, integer, smallint, real, double precision, boolean, timestamptz, timestamp, date, time, uuid, text, varchar(N), char(N), bytea, oid, numeric(P,S), jsonb, json, interval. inet/cidr unsupported (store IP data as text)', p_pg_type;
END;
$$;

-- For PG types that Iceberg can't represent natively (jsonb, interval, …)
-- the wrapper view casts the cold-side VARCHAR back to the rich PG type so
-- applications see it natively. Returns '' when storage already matches the
-- surface type.
CREATE OR REPLACE FUNCTION coldfront._iceberg_view_cast_type(p_pg_type text)
RETURNS text
LANGUAGE sql IMMUTABLE STRICT AS $$
    SELECT CASE lower(trim(p_pg_type))
        WHEN 'jsonb'            THEN 'json'      -- DuckDB has no jsonb, surface as json
        WHEN 'json'             THEN 'json'
        WHEN 'interval'         THEN 'interval'
        -- PG has no bare "double" type, so the view's cold cast r['col']::DOUBLE
        -- (the Iceberg storage name) won't parse. Surface via "double precision".
        WHEN 'double precision' THEN 'double precision'
        WHEN 'float8'           THEN 'double precision'
        -- BLOB is not a PG-parseable cast name; surface bytea via "bytea".
        WHEN 'bytea'            THEN 'bytea'
        -- Everything else (incl. smallint→INTEGER, oid→BIGINT widening) has a
        -- storage type that is itself a PG-parseable surface; the view casts
        -- BOTH branches to that storage type, so no separate surface cast is
        -- needed and bootstrap/post-cutover view column types still agree.
        ELSE ''
    END;
$$;

-- create_iceberg_table: provision an iceberg-only table end-to-end.
--
--   p_schema         PG schema for the wrapper view (e.g. 'public').
--   p_table          relation/view name (e.g. 'events'). Iceberg table is
--                    created at ice.default.<p_table>.
--   p_columns        jsonb array of {name, type} entries. Type is a PG type
--                    name from the supported set; see _iceberg_storage_type.
--   p_partition_cols array of column names for Iceberg partitioning, or NULL.
--
-- Effects:
--   1. Creates the Iceberg table via duckdb.raw_query('CREATE TABLE ice...').
--   2. Creates a PG view <p_schema>.<p_table> that wraps iceberg_scan() with
--      proper column projections (and view-cast for jsonb/interval).
--   3. Creates an INSTEAD OF INSERT trigger on the view that routes writes to
--      duckdb.raw_query('INSERT INTO ice...').
--   4. Registers the view in coldfront.tiered_views with is_iceberg_only=true,
--      so the post_parse_analyze hook routes UPDATE/DELETE to the cold path.
CREATE OR REPLACE FUNCTION coldfront.create_iceberg_table(
    p_schema         text,
    p_table          text,
    p_columns        jsonb,
    p_partition_cols text[] DEFAULT NULL
) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
    ice_ref          text := format('ice."default".%I', p_table);
    iceberg_cols     text := '';
    view_proj        text := '';
    placeholders     text := '';
    new_refs         text := '';
    partition_clause text := '';
    insert_fmt       text;
    trig_fn          text;
    n                int  := 0;
    col              jsonb;
    col_name         text;
    pg_type          text;
    storage_type     text;
    cast_type        text;
BEGIN
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
        storage_type := coldfront._iceberg_storage_type(pg_type);
        cast_type    := coldfront._iceberg_view_cast_type(pg_type);

        IF n > 0 THEN
            iceberg_cols := iceberg_cols || ', ';
            view_proj    := view_proj    || ', ';
            placeholders := placeholders || ', ';
            new_refs     := new_refs     || ', ';
        END IF;
        n := n + 1;

        iceberg_cols := iceberg_cols || quote_ident(col_name) || ' ' || storage_type;

        -- View projection: r['col']::<surface> AS col, where surface =
        -- cast_type (json/interval/…) else the Iceberg storage type. Using the
        -- storage type (not the raw pg_type) keeps this consistent with the
        -- tiered generators (view.go / _rebuild_tiered_view) and matches the
        -- actual Iceberg column type (e.g. smallint→INTEGER, char(10)→VARCHAR).
        IF cast_type <> '' THEN
            view_proj := view_proj || format('r[%L]::%s AS %I', col_name, cast_type, col_name);
        ELSE
            view_proj := view_proj || format('r[%L]::%s AS %I', col_name, storage_type, col_name);
        END IF;

        -- INSERT trigger: format('INSERT INTO ice... VALUES (<placeholders>)', <new_refs>).
        --  * json/interval (VARCHAR-backed): NEW.col::text.
        --  * bytea (BLOB): from_hex(%L) + encode(NEW.col,'hex') — %L renders a
        --    bytea as PG's '\xcafe' text which DuckDB mis-parses into a BLOB;
        --    round-tripping the hex through from_hex() rebuilds the exact bytes.
        --  * everything else (incl. double, '2.5' text round-trips): NEW.col.
        -- Mirrors _rebuild_tiered_view and the archiver export.
        IF storage_type = 'BLOB' THEN
            placeholders := placeholders || 'from_hex(%L)';
            new_refs     := new_refs || format('encode(NEW.%I,%L)', col_name, 'hex');
        ELSIF cast_type IN ('json', 'interval') THEN
            placeholders := placeholders || '%L';
            new_refs     := new_refs || format('NEW.%I::text', col_name);
        ELSE
            placeholders := placeholders || '%L';
            new_refs     := new_refs || format('NEW.%I', col_name);
        END IF;
    END LOOP;

    -- TODO: pg_duckdb v1.1.1 + duckdb-iceberg do not accept PARTITIONED BY
    -- in CREATE TABLE for attached Iceberg catalogs. The Iceberg spec
    -- supports partition specs, but the DuckDB SQL surface for declaring
    -- them at CREATE time is not yet wired up. For now p_partition_cols
    -- is accepted but ignored; predicate pushdown still works via Parquet
    -- row-group min/max statistics. Revisit once upstream support lands.
    IF p_partition_cols IS NOT NULL AND array_length(p_partition_cols, 1) > 0 THEN
        RAISE NOTICE 'coldfront.create_iceberg_table: p_partition_cols=% accepted but currently ignored (no upstream syntax to declare Iceberg partition specs at CREATE)', p_partition_cols;
    END IF;

    -- 1. Iceberg table on the attached catalog (create namespace first;
    -- CREATE SCHEMA IF NOT EXISTS is idempotent and cheap on Lakekeeper).
    -- IF NOT EXISTS on the table itself makes the helper safe to call again
    -- against an existing table — useful for distributed setups where each
    -- node registers the same shared Iceberg table independently.
    PERFORM coldfront.ensure_attached();
    PERFORM duckdb.raw_query('CREATE SCHEMA IF NOT EXISTS ice."default"');
    PERFORM duckdb.raw_query(format(
        'CREATE TABLE IF NOT EXISTS %s (%s)',
        ice_ref, iceberg_cols
    ));

    -- 2. PG-side wrapper view. Source is duckdb.query('SELECT * FROM ice...')
    -- rather than iceberg_scan('ice...'). The pg_duckdb planner folds both
    -- forms into the same iceberg_scan execution plan with predicate
    -- pushdown into Parquet row groups, but they differ in transactional
    -- visibility: iceberg_scan re-resolves the table from Lakekeeper each
    -- call (always reads the committed snapshot, blind to the same DuckDB
    -- session's pending tx writes), while duckdb.query goes through the
    -- session's planner and sees in-progress tx state. Using duckdb.query
    -- means SELECTs inside an explicit BEGIN block see the same
    -- transaction's prior INSERT/UPDATE/DELETE — i.e. read-your-own-write
    -- works correctly in iceberg-only mode.
    EXECUTE format(
        'CREATE OR REPLACE VIEW %I.%I AS SELECT %s FROM duckdb.query(%L) AS t(r)',
        p_schema, p_table, view_proj,
        format('SELECT * FROM ice.default.%s', p_table)
    );

    -- 3. No INSTEAD OF INSERT trigger: the C post_parse_analyze hook intercepts
    --    INSERT INTO <iceberg-only-view> (see coldfront.c emit_cold /
    --    prefix_pg_tables_with_pglocal) and rewrites it into a single bulk
    --    SELECT duckdb.raw_query('INSERT INTO ice.… VALUES/SELECT …') — one
    --    Iceberg snapshot for the whole statement regardless of row count, so a
    --    multi-row or parallel INSERT cannot incur per-row 409
    --    CatalogCommitConflicts. INSERT … SELECT FROM <pg_source> gets each
    --    PG-table reference prefixed with `pglocal.` so DuckDB's postgres
    --    extension streams source rows over libpq with no local materialisation.

    -- Drop a per-row insert trigger if one is present (e.g. left by an upgrade);
    -- this view uses the hook-rewrite path above, not a trigger.
    EXECUTE format(
        'DROP TRIGGER IF EXISTS coldfront_iceonly_insert ON %I.%I',
        p_schema, p_table);

    -- 4. Registry row — is_iceberg_only=true tells the C hook to short-circuit
    --    classify_tier to TIER_COLD for any INSERT/UPDATE/DELETE on this view.
    INSERT INTO coldfront.tiered_views (schema_name, relname, hot_table, iceberg_table, partition_col, is_iceberg_only)
    VALUES (p_schema, p_table, NULL, format('ice.default.%s', p_table), NULL, true)
    ON CONFLICT (schema_name, relname) DO UPDATE SET
        hot_table       = NULL,
        iceberg_table   = EXCLUDED.iceberg_table,
        partition_col   = NULL,
        is_iceberg_only = true;

    -- 5. Prime the table so current-snapshot-id is non-null. Without this,
    --    the first concurrent N writers against an empty Iceberg table can
    --    each commit a "first snapshot" without conflict — Lakekeeper's
    --    assert-ref-snapshot-id precondition holds for all of them when
    --    the prior ref is null — and the last writer's snapshot wins,
    --    silently overwriting the others. Two committed snapshots in one
    --    DuckDB transaction (one INSERT of NULLs + one DELETE) lift the
    --    table off the null-snapshot state and keep it semantically empty.
    --
    --    NULL works for every column today because the Iceberg DDL we emit
    --    in step 1 has no NOT NULL constraints. TODO: when the helper is
    --    extended to honour NOT NULL (via a `not_null` field on p_columns),
    --    swap this for a per-type non-null literal lookup keyed on
    --    storage_type, since NULL won't be acceptable for required columns.
    PERFORM duckdb.raw_query(format(
        'INSERT INTO %s VALUES (%s); DELETE FROM %s',
        ice_ref,
        array_to_string(array_fill('NULL'::text, ARRAY[n]), ', '),
        ice_ref));

    -- 6. Ensure claims is in Spock's default replication set so
    --    cross-node bakery coordination (see below) works. Idempotent.
    --    Claim rows themselves come and go on demand — INSERT in
    --    _claim_iceberg_lock, DELETE in _release_iceberg_lock — so the
    --    table stays empty when no writers are mid-commit.
    PERFORM coldfront._ensure_claims_replicated();
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

-- ============================================================================
-- Multi-writer commit serialisation (bakery protocol).
--
-- Background. With three executor PG nodes all writing to the same Iceberg
-- table via pg_duckdb, every iceberg commit posts to Lakekeeper which does CAS
-- on metadata_location. Concurrent writers that prepared their commit body
-- against the same parent snapshot lose the race; whichever lands second
-- gets HTTP 409 CatalogCommitConflicts, and DuckDB-iceberg v1.4.x has no
-- writer-side rebase loop, so the loser's batch is silently dropped.
--
-- Architecture. Coordinate cluster-wide via:
--  • coldfront.claims — one row per (node_id, iceberg_table), the
--    coordination state. Replicated by Spock so every node sees every other
--    node's current claim.
--  • spock's logical_commit_clock patch — every PG commit cluster-wide gets
--    a globally-monotonic xact_time, so pg_current_wal_lsn() is unique and
--    ordered across the mesh. We use it as the bakery ticket source.
--  • spock.read_peer_progress() — local readback of how far each peer has
--    applied from our origin, so a writer can confirm peers have seen its
--    claim before checking the bakery.
--  • dblink-to-self — required because the claim row UPDATE must commit
--    BEFORE the user's iceberg INSERT happens (else peers don't see our
--    claim until our PG xact ends, defeating the bakery). pg_duckdb forbids
--    SAVEPOINT, plpgsql can't COMMIT inside a function, and pg_duckdb's
--    pglocal-attached postgres database is read-only — so an autonomous
--    transaction via a separate libpq connection is the only path.
--
-- Bakery rule. Each writer:
--   1. Updates its claims row (held=true, ticket=current LSN)
--      via dblink, autonomous-commit. Visible to peers via Spock immediately.
--   2. Polls spock.read_peer_progress() until every peer has applied
--      our origin past our claim's LSN.
--   3. Polls coldfront.claims locally until our ticket is the
--      smallest pending ticket for this iceberg table.
--   4. Runs the actual iceberg INSERT (in user's PG transaction). Sole
--      writer to Lakekeeper at this moment, no CAS race.
--   5. C-level xact callback fires after pg_duckdb's at PG commit/abort
--      and releases the claim (UPDATE held=false via dblink). See the
--      coldfront C extension (TODO: hook); release-in-trigger is the
--      bootstrap implementation but races with pg_duckdb's iceberg POST.
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
-- "peer ack_from_node has acknowledged ticket on iceberg_table."  The
-- originator polls this table waiting for one row per live peer before
-- entering the iceberg-commit phase.  Spock-replicated so peers'
-- ack-INSERTs (from the peer-side trigger on coldfront.claims) reach
-- the originator.
CREATE TABLE coldfront.claim_acks (
    ticket          bigint NOT NULL,
    ack_from_node   int    NOT NULL,
    iceberg_table   text   NOT NULL,
    PRIMARY KEY (ticket, ack_from_node)
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

-- Configuration: dblink connection string for autonomous-tx claims.
-- Operator sets this once per database (typically in postgresql.conf or
-- via ALTER DATABASE):
--    SET coldfront.dblink_self = 'host=/var/run/postgresql dbname=coldfront user=coldfront';
-- Default is empty; helpers raise a clear error if unset.
-- current_setting(name, missing_ok=true) returns NULL when the GUC isn't
-- defined; no EXCEPTION block needed (which would create a subtxn that
-- pg_duckdb's SubXactCallback hard-rejects).
CREATE FUNCTION coldfront._dblink_self_connstr() RETURNS text
LANGUAGE sql STABLE AS
$$ SELECT current_setting('coldfront.dblink_self', true) $$;

-- One-time setup: ensure claims is in Spock's default replication set so
-- peer nodes see our INSERT/DELETE on it. Idempotent via existence check.
-- No EXCEPTION block: pg_duckdb's SubXactCallback hard-rejects every
-- subtransaction in the session, even ones that don't touch DuckDB.
-- Called from coldfront.create_iceberg_table() on whichever node first
-- declares an iceberg table.
CREATE FUNCTION coldfront._ensure_claims_replicated()
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    -- Claims replication is a Spock-mesh concern only. In a vanilla single-node
    -- deployment there is no spock extension (and the bakery uses a local
    -- advisory lock, not cross-node claim rows), so this is a no-op. Gating on
    -- the spock extension's presence keeps create_iceberg_table working
    -- identically in vanilla and mesh (single shared path).
    IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'spock') THEN
        RETURN;
    END IF;

    -- coldfront.claims is replicated cluster-wide.
    PERFORM spock.repset_add_table('default', 'coldfront.claims'::regclass, false)
    WHERE NOT EXISTS (
        SELECT 1 FROM spock.replication_set rs
          JOIN spock.replication_set_table rst ON rst.set_id = rs.set_id
         WHERE rs.set_name = 'default'
           AND rst.set_reloid = 'coldfront.claims'::regclass
    );
    -- coldfront.claim_acks too — originator needs to see peers' acks.
    PERFORM spock.repset_add_table('default', 'coldfront.claim_acks'::regclass, false)
    WHERE NOT EXISTS (
        SELECT 1 FROM spock.replication_set rs
          JOIN spock.replication_set_table rst ON rst.set_id = rs.set_id
         WHERE rs.set_name = 'default'
           AND rst.set_reloid = 'coldfront.claim_acks'::regclass
    );
    -- coldfront.deferred_acks is INTENTIONALLY local-only (each node's
    -- queue of acks-it-owes-to-others-once-it-releases).
END;
$$;

-- Peer-side trigger: fires when spock applies an originator's claim
-- INSERT into this node's local coldfront.claims (REPLICA-only — does
-- NOT fire on the originator's own local INSERT). Runs Ricart-Agrawala's
-- defer rule:
--   * If this node has its own pending claim with SMALLER ticket on the
--     same iceberg_table → DEFER (queue in coldfront.deferred_acks).
--   * Otherwise → ack immediately (INSERT into coldfront.claim_acks,
--     which replicates back to originator).
-- See docs/formal/Bakery_v2.tla, the Applier process.
CREATE FUNCTION coldfront._on_claim_apply() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    my_node         int    := current_setting('snowflake.node')::int;
    connstr         text   := coldfront._dblink_self_connstr();
    -- Per-table advisory lock key. Pairs with the exclusive lock that
    -- _claim_iceberg_lock takes around its dblink-INSERT. Shared mode
    -- here so concurrent apply-worker triggers don't serialise against
    -- each other; they only serialise against an in-flight local INSERT.
    my_lock_key     int    := hashtext('coldfront_claim:'||NEW.iceberg_table)::int;
    smaller_pending bigint;
BEGIN
    IF snowflake.get_node(NEW.ticket) = my_node THEN
        RETURN NULL;
    END IF;

    -- Close the "in-flight local claim" visibility race: if this node's
    -- main session is between snowflake.nextval() and dblink_exec INSERT
    -- (the claim chosen but not yet committed visibly), pg_advisory_lock
    -- holds the exclusive key until that INSERT commits and unlocks.
    -- The SELECT below then sees the in-flight local claim and defers
    -- correctly. Held only across the SELECT so the trigger doesn't
    -- block other apply work needlessly.
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
    -- cannot lock it. Modelled + proven in docs/formal/Bakery_v2.tla (SafeAcks):
    -- SafeAcks=FALSE violates EventualProgress (the wedge); SafeAcks=TRUE holds it
    -- while every safety invariant still holds.
    PERFORM pg_advisory_lock_shared(my_lock_key);
    SELECT ticket INTO smaller_pending
      FROM coldfront.claims
     WHERE snowflake.get_node(ticket) = my_node
       AND iceberg_table = NEW.iceberg_table
       AND ticket < NEW.ticket
     ORDER BY ticket
     LIMIT 1
     FOR UPDATE;
    PERFORM pg_advisory_unlock_shared(my_lock_key);

    IF smaller_pending IS NOT NULL THEN
        -- Defer locally — drain (and the eventual ack via dblink) fires
        -- on our own claim's release.  coldfront.deferred_acks is
        -- intentionally local-only (not in any spock repset).
        INSERT INTO coldfront.deferred_acks
            (pending_ticket, ack_for_ticket, iceberg_table)
        VALUES (smaller_pending, NEW.ticket, NEW.iceberg_table)
        ON CONFLICT DO NOTHING;
    ELSE
        -- Route the ack INSERT through dblink_self.  The trigger fires
        -- inside spock's apply worker (session_replication_role = 'replica',
        -- pg_replication_origin set to the publisher we're applying).
        -- A direct INSERT here would inherit that origin tag and spock's
        -- loop-prevention would filter the row out of the stream back to
        -- the originator — they'd never see our ack.  dblink_self opens
        -- a fresh libpq session (its own connection, no replication origin
        -- set up) so the INSERT is tagged with
        -- THIS node as origin and replicates normally cluster-wide
        -- including back to the originator.  Verified empirically — see
        -- the test in transcript/README.
        IF NOT 'coldfront_self' = ANY(COALESCE(public.dblink_get_connections(), '{}'::text[])) THEN
            PERFORM public.dblink_connect('coldfront_self', connstr);
        END IF;
        PERFORM public.dblink_exec('coldfront_self', format(
            'INSERT INTO coldfront.claim_acks (ticket, ack_from_node, iceberg_table) '
            'VALUES (%s, %s, %L) ON CONFLICT DO NOTHING',
            NEW.ticket, my_node, NEW.iceberg_table));
    END IF;
    RETURN NULL;
END $$;

CREATE TRIGGER coldfront_claim_apply
    AFTER INSERT ON coldfront.claims
    FOR EACH ROW EXECUTE FUNCTION coldfront._on_claim_apply();
ALTER TABLE coldfront.claims ENABLE REPLICA TRIGGER coldfront_claim_apply;

-- Origin-side trigger: fires when our own backend (or our local C
-- XactCallback session) DELETEs a row in coldfront.claims — i.e., when
-- we release a claim we held. Drains coldfront.deferred_acks: every ack
-- we had queued for our own pending claim now gets INSERTed into
-- coldfront.claim_acks (replicating to the original originator).
-- Default trigger mode: fires on origin only, NOT on spock-apply of a
-- peer's DELETE.
CREATE FUNCTION coldfront._on_claim_release() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    my_node int := current_setting('snowflake.node')::int;
BEGIN
    IF snowflake.get_node(OLD.ticket) <> my_node THEN
        RETURN NULL;
    END IF;

    INSERT INTO coldfront.claim_acks (ticket, ack_from_node, iceberg_table)
    SELECT ack_for_ticket, my_node, iceberg_table
      FROM coldfront.deferred_acks
     WHERE pending_ticket = OLD.ticket
    ON CONFLICT DO NOTHING;

    DELETE FROM coldfront.deferred_acks WHERE pending_ticket = OLD.ticket;
    RETURN NULL;
END $$;

CREATE TRIGGER coldfront_claim_release
    AFTER DELETE ON coldfront.claims
    FOR EACH ROW EXECUTE FUNCTION coldfront._on_claim_release();

-- Acquire the bakery for one iceberg table. Returns the caller's
-- snowflake ticket; release deletes by ticket only.
--
-- Protocol: Lamport's 1978 distributed mutual exclusion algorithm with
-- the Ricart-Agrawala (1981) deferred-reply optimisation.
-- Modelled in docs/formal/Bakery_v2.tla.
-- SECURITY DEFINER (search_path pinned; body is fully schema-qualified) so a
-- NON-superuser writer drives the R-A bakery with superuser privilege: the
-- pg_stat_replication alive-check sees every walsender (an INVOKER non-superuser
-- would see none → rule all peers dead → skip acks → the race this serializer
-- exists to prevent), and the spock.* reads + dblink claim-INSERT succeed. This
-- only changes the PG execution privilege, not the claim/ack/lock/ticket protocol
-- (TLA+-verified protocol-neutral; see docs/formal/Bakery_v2.tla). The cold DML
-- itself still runs as the caller — _exec_iceberg_with_claim stays INVOKER.
CREATE FUNCTION coldfront._claim_iceberg_lock(
    p_iceberg_table text
) RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $$
DECLARE
    connstr           text     := coldfront._dblink_self_connstr();
    my_node           int      := current_setting('snowflake.node')::int;
    -- Real local spock node name. spock.local_node has only node_id +
    -- node_local_interface (no node_name column) — an unqualified
    -- node_name in a subquery against it silently resolves to the
    -- OUTER query's column (e.g. n.node_name in the alive-check below),
    -- so we explicitly join to spock.node to read the local name.
    -- Without this fix the alive-check generates slot names with the
    -- peer's node as "local", never matching any walsender, and every
    -- peer is treated as dead → bakery skips required acks → race.
    my_node_name      name     := (
        SELECT ln.node_name FROM spock.local_node l
          JOIN spock.node ln ON ln.node_id = l.node_id
    );
    my_ticket         bigint;
    -- Per-table advisory lock key (pairs with the shared lock taken in
    -- _on_claim_apply). Held EXCLUSIVELY in THIS session ONLY across
    -- nextval() + the dblink INSERT (~1–2 ms). The preamble above
    -- runs unlocked because, while it executes, we don't yet have a
    -- ticket — and snowflake's monotonic timestamps mean any peer
    -- whose claim arrives during our preamble has a smaller ticket
    -- than the one we'll eventually take, so the trigger acking them
    -- is correct R-A behavior.
    my_lock_key       int      := hashtext('coldfront_claim:'||p_iceberg_table)::int;
    -- coldfront.peer_alive_window_ms: a peer whose walsender hasn't
    -- heartbeated within this window is treated as already-acked (R-A
    -- dead-peer escape). Default 5000 ms matches spock's default
    -- heartbeat cadence; raise it on slow/lossy WAN links if false-
    -- positive dead-peer rulings become a problem. Read once per
    -- claim — GUC changes take effect on the next claim.
    peer_alive_window interval := make_interval(secs =>
        COALESCE(NULLIF(current_setting('coldfront.peer_alive_window_ms', true), '')::int, 5000) / 1000.0);
BEGIN
    IF connstr IS NULL OR connstr = '' THEN
        RAISE EXCEPTION 'coldfront: configure GUC coldfront.dblink_self with a libpq connstr (e.g. ''host=/var/run/postgresql dbname=coldfront user=coldfront'')';
    END IF;

    -- Persistent named dblink connection (sessionful, opened once).
    -- The dblink session only touches coldfront.claims (never a tiered view),
    -- so the lazy 'ice' attach never fires and it never enters DuckDB territory.
    -- No sync-rep — R-A's ack barrier replaces it; statement_timeout is the only
    -- safety net.
    IF NOT 'coldfront_self' = ANY(COALESCE(public.dblink_get_connections(), '{}'::text[])) THEN
        PERFORM public.dblink_connect('coldfront_self', connstr);
        PERFORM public.dblink_exec('coldfront_self',
            'SET statement_timeout = ''30s''');
    END IF;

    -- Alignment precondition: snowflake.node = hashtext(spock node name)
    -- & 1023.  Needed because the dead-peer detection in the ack-wait
    -- loop maps each peer's snowflake.node back to a spock.node_name
    -- via the same hash.  Cached per-session.
    IF current_setting('coldfront._snowflake_aligned', true) IS DISTINCT FROM 'true' THEN
        PERFORM 1
           FROM spock.local_node l JOIN spock.node n ON n.node_id = l.node_id
          WHERE (hashtext(n.node_name::text) & 1023) = my_node;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'coldfront: snowflake.node = % does not match hashtext(local spock node name) & 1023; reconfigure snowflake.node in postgresql.conf and restart',
                            my_node;
        END IF;
        PERFORM set_config('coldfront._snowflake_aligned', 'true', false);
    END IF;

    -- NodeStartup self-cleanup of pre-restart orphans.  Cheap when no
    -- orphans exist (gated on a local EXISTS).
    IF EXISTS (
        SELECT 1 FROM coldfront.claims
         WHERE snowflake.get_node(ticket) = my_node
           AND snowflake.get_epoch(ticket) < extract(epoch FROM pg_postmaster_start_time())
    ) THEN
        PERFORM public.dblink_exec('coldfront_self', format(
            'DELETE FROM coldfront.claims WHERE snowflake.get_node(ticket) = %s AND snowflake.get_epoch(ticket) < extract(epoch FROM pg_postmaster_start_time())',
            my_node));
    END IF;

    -- INSERT my claim.  Async replication via spock — no sync_commit
    -- = remote_apply.  Peers will fire coldfront._on_claim_apply()
    -- when they apply this INSERT, inserting either an ack row (into
    -- coldfront.claim_acks) or a deferred-ack row (into
    -- coldfront.deferred_acks) per R-A's defer rule.
    --
    -- Per-table exclusive advisory lock, held ONLY across nextval() +
    -- dblink INSERT (~1–2 ms). Paired with the shared lock in
    -- _on_claim_apply, this closes the "we have a ticket but the row
    -- isn't visible yet" window where a peer trigger could otherwise
    -- ack us prematurely. The preamble above doesn't need the lock —
    -- if a peer claim arrives during it, we don't yet have a ticket,
    -- and snowflake's monotonic timestamp guarantees any future ticket
    -- of ours will be larger than the peer's (whose nextval already
    -- happened) — so acking the peer is the correct R-A choice anyway.
    PERFORM pg_advisory_lock(my_lock_key);
    my_ticket := snowflake.nextval();
    PERFORM public.dblink_exec('coldfront_self', format(
        'INSERT INTO coldfront.claims (iceberg_table, ticket) VALUES (%L, %s)',
        p_iceberg_table, my_ticket));
    PERFORM pg_advisory_unlock(my_lock_key);

    -- Wait phase — pure Ricart-Agrawala, NO timeout:
    --   (a) Same-node-min: I must be the minimum-ticket holder among
    --       same-node writers on this iceberg_table. Snowflake tickets
    --       are per-node monotonic + timestamped, so a smaller ticket
    --       means nextval was called earlier on this node.
    --   (b) Peer-ack: every ALIVE peer must have acked my ticket.
    --       "Alive" = walsender row in pg_stat_replication is
    --       state='streaming' with reply_time within
    --       coldfront.peer_alive_window_ms (default 5 s). A peer that
    --       is stale (heartbeat gone past the window) is implicitly
    --       treated as already-acked — this is R-A's dead-peer escape,
    --       the only way out of waiting indefinitely. There is no
    --       separate timeout: a peer that hasn't acked while alive is
    --       either deferring (legitimate per R-A's defer rule) or
    --       going to ack imminently. Local backends are trusted (PG's
    --       xact rollback releases a crashed claim via the C
    --       XactCallback in coldfront.c).
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
                    AND a.ack_from_node = (hashtext(n.node_name) & 1023)
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
                  WHERE r.state = 'streaming'
                    AND r.reply_time > now() - peer_alive_window
                    AND r.application_name = spock.spock_gen_slot_name(
                          current_database()::name,
                          my_node_name,
                          ('sub_' || n.node_name || '_from_' || my_node_name)::name
                        )
               )
        );
        PERFORM pg_sleep(0.005);
    END LOOP;

    RETURN my_ticket;
END;
$$;

-- Release the bakery for one iceberg table. Autonomous-commit via dblink.
-- Called from a C-level xact callback registered by the coldfront extension
-- so it runs AFTER pg_duckdb's xact callback at PG xact end — that is, after
-- the iceberg POST has either succeeded or failed. (Bootstrap implementation
-- can call this from the trigger before the iceberg POST, with the documented
-- race that the next writer may briefly proceed while our iceberg commit is
-- still in flight.)
-- SECURITY DEFINER for the same reason as _claim_iceberg_lock (dblink DELETE of
-- the claim row; fully schema-qualified, search_path pinned). In production this
-- runs from the C XactCallback's libpq loopback as the coldfront owner already;
-- SD also covers any synchronous (bootstrap) caller so a non-superuser release
-- never fails. Protocol-neutral (docs/formal/Bakery_v2.tla).
CREATE FUNCTION coldfront._release_iceberg_lock(p_ticket bigint)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $$
DECLARE
    connstr text := coldfront._dblink_self_connstr();
BEGIN
    IF connstr IS NULL OR connstr = '' THEN
        RAISE EXCEPTION 'coldfront: configure GUC coldfront.dblink_self';
    END IF;

    -- DELETE only OUR specific ticket (returned by _claim_iceberg_lock).
    -- Reuses the named persistent connection opened by claim.
    IF NOT 'coldfront_self' = ANY(COALESCE(public.dblink_get_connections(), '{}'::text[])) THEN
        PERFORM public.dblink_connect('coldfront_self', connstr);
    END IF;
    PERFORM public.dblink_exec('coldfront_self', format(
        'DELETE FROM coldfront.claims WHERE ticket = %s', p_ticket));
END;
$$;

-- Wrapper called by the coldfront C hook for iceberg-only INSERT statements.
-- Acquires the bakery, runs the rewritten DML through duckdb.raw_query,
-- releases the bakery.
--
-- No EXCEPTION wrapper: pg_duckdb forbids subtransactions, so we cannot
-- catch errors here. If duckdb.raw_query raises, the user's PG xact aborts
-- (pg_duckdb's XactCallback rolls back the iceberg side too) and our claim
-- row may be left in coldfront.claims. Stale claims block the bakery for
-- everyone (a stuck minimum ticket nobody owns). Operators clean them up
-- with `DELETE FROM coldfront.claims WHERE ticket = <orphan>` after
-- diagnosing the failed writer; an automated TTL-based reaper is on the
-- todo list.
-- C-bridge: enqueues a ticket for release at outer-tx-end. Drained by
-- the coldfront XactCallback registered in _PG_init (coldfront.c), which
-- fires after pg_duckdb's XactCallback so the iceberg snapshot has
-- already committed (or rolled back) by the time we DELETE the claim.
CREATE FUNCTION coldfront._enqueue_release(p_ticket bigint)
RETURNS void
LANGUAGE c AS 'coldfront', 'coldfront_enqueue_release';

-- Is the async-parquet upload ordering BOTH requested AND safe to use?
-- coldfront.iceberg_async_parquet asks to stage parquet OUTSIDE the bakery claim
-- (writers overlap on S3); that is correct ONLY when the loaded duckdb-iceberg
-- carries the bakery-aware-commit-refresh patch, which re-stamps
-- parent_snapshot_id at the commit POST under the claim. coldfront.iceberg_bakery_patch
-- asserts that patched binary is present — the coldfront patched images set BOTH
-- GUCs together in postgresql.conf (see docker/entrypoint.sh). Async requested
-- WITHOUT the patch asserted returns FALSE here, so _exec_iceberg_with_claim
-- falls back to the always-safe stock ordering instead of silently risking a
-- Lakekeeper 409 / commit loss. Formal basis: docs/formal — Bakery_v2_race.cfg
-- (async WITHOUT the patch) violates NoLakekeeperConflict; Bakery_v2_async.cfg
-- (async WITH the patch) is safe. STABLE so the planner can fold it.
CREATE FUNCTION coldfront._iceberg_async_active() RETURNS boolean
LANGUAGE sql STABLE AS $$
  SELECT COALESCE(NULLIF(current_setting('coldfront.iceberg_async_parquet', true), '')::boolean, false)
     AND COALESCE(NULLIF(current_setting('coldfront.iceberg_bakery_patch',   true), '')::boolean, false)
$$;

-- Serialise one cold-tier Iceberg write so concurrent committers never hit a
-- Lakekeeper 409 CatalogCommitConflict (duckdb-iceberg does not rebase → the
-- loser's data is silently dropped). This is THE chokepoint every cold write
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
--     advisory lock is the same mutex without any Spock/snowflake/dblink
--     dependency. Taken BEFORE staging so a second backend on this node blocks
--     before it captures parent_snapshot_id (no stale-parent 409); auto-released
--     at commit. This is the path for plain PostgreSQL tiered deployments, which
--     have no snowflake.node / dblink_self configured.
--
-- v_armed probes the two GUCs the R-A bakery requires. current_setting(...,true)
-- returns NULL for an unrecognised GUC, so the probe is safe with no snowflake
-- extension loaded.
CREATE FUNCTION coldfront._exec_iceberg_with_claim(
    p_iceberg_table text,
    p_sql           text
) RETURNS void LANGUAGE plpgsql AS $$
DECLARE
    my_ticket bigint;
    v_armed   boolean := NULLIF(current_setting('snowflake.node', true), '') IS NOT NULL
                     AND NULLIF(current_setting('coldfront.dblink_self', true), '') IS NOT NULL;
    -- Async-parquet upload ordering: stage the parquet OUTSIDE the claim (writers
    -- overlap on S3), then take the claim only to wrap pg_duckdb's deferred commit
    -- POST. Correct ONLY on the bakery-aware duckdb-iceberg build (it re-stamps
    -- parent_snapshot_id at the POST, under the claim). _iceberg_async_active() is
    -- TRUE only when BOTH coldfront.iceberg_async_parquet AND the build marker
    -- coldfront.iceberg_bakery_patch are on; otherwise the stock ordering below is
    -- used (always safe). Never a 409 either way.
    v_async   boolean := coldfront._iceberg_async_active();
BEGIN
    -- A physical standby is read-only. The vanilla path below takes only an
    -- advisory lock (not a PG write), so without this guard a cold write on a
    -- read replica would slip past PG's read-only protection and attempt a
    -- DuckDB→S3 Iceberg write — an uncoordinated writer mutating the shared cold
    -- tier. Every cold write funnels through here, so one recovery check fences
    -- them all off cleanly. (A hot write hits a PG heap; PG rejects it natively.)
    IF pg_is_in_recovery() THEN
        RAISE EXCEPTION 'coldfront: cannot execute a cold (Iceberg) write on a read-only standby'
            USING HINT = 'Standbys serve reads only; route writes to the primary.';
    END IF;
    -- Fail-safe, not fail-silent: if async was REQUESTED but the bakery-aware
    -- patch is not asserted, we use the stock ordering (always safe) and note it
    -- ONCE per session. Running async on stock iceberg would let a peer capture a
    -- stale parent and conflict → silent commit loss (docs/formal Bakery_v2_race.cfg).
    -- RAISE LOG, not WARNING: this is a deployment-config advisory that belongs in
    -- the server log; it must NOT reach the client (a per-statement client message
    -- here would pollute output and break tools that scan write output for errors).
    IF NOT v_async
       AND COALESCE(NULLIF(current_setting('coldfront.iceberg_async_parquet', true), '')::boolean, false)
       AND current_setting('coldfront._async_downgrade_warned', true) IS DISTINCT FROM 'true' THEN
        RAISE LOG 'coldfront: iceberg_async_parquet is on but iceberg_bakery_patch is not set — the loaded duckdb-iceberg is not the bakery-aware build; using the SAFE stock upload ordering instead of async. Set coldfront.iceberg_bakery_patch=on ONLY where duckdb-iceberg carries the bakery-aware-commit-refresh patch (the coldfront patched images set both GUCs).';
        PERFORM set_config('coldfront._async_downgrade_warned', 'true', false);
    END IF;
    IF v_armed AND v_async THEN
        -- Patched iceberg: upload parquet in the background, then take the bakery
        -- only to wrap pg_duckdb's deferred commit POST.
        PERFORM duckdb.raw_query(p_sql);
        my_ticket := coldfront._claim_iceberg_lock(p_iceberg_table);
        PERFORM coldfront._enqueue_release(my_ticket);
    ELSIF v_armed THEN
        -- Stock iceberg: claim FIRST, then upload+commit inside the held ticket
        -- so no peer can capture a stale parent_snapshot_id.
        my_ticket := coldfront._claim_iceberg_lock(p_iceberg_table);
        PERFORM coldfront._enqueue_release(my_ticket);
        PERFORM duckdb.raw_query(p_sql);
    ELSE
        -- Vanilla single-node: local advisory lock, taken before staging.
        PERFORM pg_advisory_xact_lock(hashtext('coldfront_iceberg:' || p_iceberg_table));
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
-- (Bakery_v2.cfg); the patchless-async shortcut it must avoid is Bakery_v2_race.
CREATE FUNCTION coldfront._claim_iceberg_external(p_iceberg_table text)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
    my_ticket bigint;
    v_armed   boolean := NULLIF(current_setting('snowflake.node', true), '') IS NOT NULL
                     AND NULLIF(current_setting('coldfront.dblink_self', true), '') IS NOT NULL;
BEGIN
    IF pg_is_in_recovery() THEN
        RAISE EXCEPTION 'coldfront: cannot compact (Iceberg write) on a read-only standby'
            USING HINT = 'Standbys serve reads only; run the compactor against the primary.';
    END IF;
    IF v_armed THEN
        my_ticket := coldfront._claim_iceberg_lock(p_iceberg_table);
        PERFORM coldfront._enqueue_release(my_ticket);
    ELSE
        PERFORM pg_advisory_xact_lock(hashtext('coldfront_iceberg:' || p_iceberg_table));
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
--      (would orphan/hide the cold tier) and any column-shape change —
--      ADD/DROP COLUMN, ALTER COLUMN TYPE, RENAME COLUMN. Column DDL is
--      blocked because duckdb-iceberg (pg_duckdb v1.1.1) implements no Iceberg
--      ALTER TABLE, so the hot and cold tiers cannot be evolved together;
--   3. SUPPORTS RENAME TABLE (hot heap) and RENAME VIEW — neither touches the
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
-- (keyed on the bare view name == archiver SourceTable) both follow the new name.
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
     WHERE table_name = p_old_view_name;
$$;

-- coldfront._rebuild_tiered_view: regenerate the transparent UNION-ALL view
-- and its INSTEAD OF INSERT trigger after a RENAME TABLE (hot heap) or RENAME
-- VIEW. Driven entirely from pg_catalog so it is the runtime equivalent of
-- internal/view/view.go's GenerateViewSQL / GenerateTriggerFuncSQL /
-- GenerateTriggerSQL. (Also rebuilt after a mirrored column-shape change, so the
-- view's column set follows the hot heap; and after a hot-table or view rename.)
--
-- Called by the coldfront DDL hook for tiered views (rows with a non-NULL
-- hot_table). Iceberg-only views (is_iceberg_only = true, hot_table NULL) are
-- OUT OF SCOPE and short-circuit to a no-op: their column shape is owned by
-- create_iceberg_table(), not by a PG hot heap.
--
-- View strategy: DROP VIEW IF EXISTS ... CASCADE then CREATE VIEW (never
-- CREATE OR REPLACE). PG only lets CREATE OR REPLACE VIEW append columns at
-- the end; a DDL that drops/renames/reorders/retypes a column would fail it.
-- DROP also removes the INSTEAD OF trigger (recreated below) and changes the
-- view OID — but the registry is keyed by (schema, relname), which the
-- DROP+CREATE leaves unchanged, so there is no row to re-point. On a VIEW
-- rename the hook migrates the registry key (old→new name) BEFORE calling this,
-- so p_view_name is always the current (post-rename) view name.
CREATE FUNCTION coldfront._rebuild_tiered_view(
    p_schema     text,
    p_view_name  text
)
RETURNS void
LANGUAGE plpgsql
SET client_min_messages = warning AS $$
DECLARE
    v_schema        text;
    v_view_name     text;          -- bare relname == archiver SourceTable == watermark key
    v_hot_table     text;          -- stored quoted, e.g. "public"."_events"
    v_iceberg       text;          -- DuckDB ref, e.g. ice.default.events
    v_partcol       text;
    v_is_ice_only   boolean;
    v_hot_schema    text;
    v_hot_relname   text;
    v_cutoff        timestamptz;
    v_cutoff_lit    text;          -- UTC text literal of the cutoff (matches view.go)
    v_has_cutoff    boolean;

    v_hot_proj      text := '';     -- hot SELECT list
    v_cold_proj     text := '';     -- cold SELECT list
    v_col_list      text := '';     -- INSERT target columns (non-identity)
    v_hot_vals      text := '';     -- NEW."col" refs (non-identity)
    v_cold_vals     text := '';     -- NEW."col"[::text] refs (non-identity)
    v_placeholders  text := '';     -- %L / NULL per column, positional

    v_view_sql      text;
    v_func_sql      text;
    v_funcname      text;           -- coldfront."<view>_write"
    v_trigname      text;           -- "<view>_write_trigger"

    r               record;
    n               int := 0;       -- live-column counter for projections
    cast_type       text;
    cold_type       text;
    iter            int := 0;       -- raw attribute counter (placeholder ordering)
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
    -- _tiered_insert_cold). No EXCEPTION wrapper — pg_duckdb forbids subtxns.
    v_hot_schema  := (parse_ident(v_hot_table))[1];
    v_hot_relname := (parse_ident(v_hot_table))[2];

    -- 2. Watermark cutoff, keyed on the BARE view name (== SourceTable).
    SELECT cutoff_time INTO v_cutoff
    FROM coldfront.archive_watermark
    WHERE table_name = v_view_name;
    v_has_cutoff := (v_cutoff IS NOT NULL);
    IF v_has_cutoff THEN
        -- UTC text literal, matching internal/view/view.go cutoffLiteral().
        v_cutoff_lit := to_char(v_cutoff AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI:SS+00');
    END IF;

    -- 3. Post-DDL column list from the HOT table, attnum order, live columns.
    --    Build hot/cold projections and trigger lists in one pass — mirrors
    --    view.go's single loop over cfg.Columns.
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
        ORDER BY a.attnum
    LOOP
        cast_type := coldfront._iceberg_view_cast_type(r.pg_type);
        cold_type := coldfront._iceberg_storage_type(r.pg_type);  -- Iceberg storage (BLOB, INTEGER, …)

        -- VIEW PROJECTIONS (view.go ~184-203).
        IF n > 0 THEN
            v_hot_proj  := v_hot_proj  || ', ';
            v_cold_proj := v_cold_proj || ', ';
        END IF;

        IF cast_type <> '' THEN
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

        -- TRIGGER LISTS (view.go insertCols / coldInsertVals /
        -- coldInsertPlaceholders). Placeholders are positional over ALL
        -- columns incl. identity (NULL for identity, %L otherwise) because
        -- DuckDB/Iceberg has no targeted insert.
        IF iter > 0 THEN
            v_placeholders := v_placeholders || ', ';
        END IF;
        iter := iter + 1;

        IF r.attidentity = 'a' THEN
            v_placeholders := v_placeholders || 'NULL';
        ELSE
            IF v_col_list <> '' THEN
                v_col_list := v_col_list || ', ';
                v_hot_vals := v_hot_vals || ', ';
                v_cold_vals := v_cold_vals || ', ';
            END IF;
            v_col_list := v_col_list || quote_ident(r.attname);
            v_hot_vals := v_hot_vals || 'NEW.' || quote_ident(r.attname);
            -- Cold-INSERT value, serialised through format()'s %L:
            --  * json/interval (VARCHAR-backed): NEW.col::text.
            --  * bytea (BLOB): from_hex(%L) placeholder + encode(NEW.col,'hex')
            --    value. %L renders a bytea as PG's '\xcafe' text, which DuckDB
            --    MIS-parses into a BLOB; round-tripping the hex through DuckDB's
            --    from_hex() rebuilds the exact bytes. (double precision round-
            --    trips fine as '2.5' text, so it stays a plain %L.)
            --  * everything else: NEW.col as-is.
            -- Consistent with create_iceberg_table and the archiver export.
            IF cold_type = 'BLOB' THEN
                v_placeholders := v_placeholders || 'from_hex(%L)';
                v_cold_vals    := v_cold_vals || format('encode(NEW.%I,%L)', r.attname, 'hex');
            ELSIF cast_type IN ('json', 'interval') THEN
                v_placeholders := v_placeholders || '%L';
                v_cold_vals    := v_cold_vals || 'NEW.' || quote_ident(r.attname) || '::text';
            ELSE
                v_placeholders := v_placeholders || '%L';
                v_cold_vals    := v_cold_vals || 'NEW.' || quote_ident(r.attname);
            END IF;
        END IF;
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
  FROM iceberg_scan(%L) r
  WHERE r[%L] < %L::timestamptz$ddl$,
            v_schema, v_view_name,
            v_hot_proj, v_hot_schema, v_hot_relname,
            v_partcol, v_cutoff_lit,
            v_cold_proj,
            v_iceberg,
            v_partcol, v_cutoff_lit);
    END IF;

    EXECUTE format('DROP VIEW IF EXISTS %I.%I CASCADE', v_schema, v_view_name);
    EXECUTE v_view_sql;

    -- 5. Rebuild the INSTEAD OF INSERT trigger function + trigger.
    v_funcname := format('coldfront.%I', v_view_name || '_write');
    v_trigname := v_view_name || '_write_trigger';

    -- Double-formatted: the outer format() builds the function body; the body
    -- itself calls format(...) at trigger time to fill %L placeholders with
    -- NEW values. The INSERT template, placeholders, and iceberg ref must
    -- survive THIS format() literally — assembled by concatenation below.
    v_func_sql := format(
$fn$CREATE OR REPLACE FUNCTION %s() RETURNS trigger AS $body$
DECLARE
  cutoff timestamptz;
BEGIN
  SELECT cutoff_time INTO cutoff FROM coldfront.archive_watermark WHERE table_name = %L;
  IF cutoff IS NULL THEN
    cutoff := %s;
  END IF;

  IF TG_OP = 'INSERT' THEN
    IF NEW.%I < cutoff THEN
      PERFORM coldfront.ensure_attached();
      PERFORM duckdb.raw_query(format(
        %L,
        %s
      ));
      RETURN NEW;
    END IF;
    INSERT INTO %I.%I (%s) VALUES (%s);
    RETURN NEW;
  END IF;
  RETURN NULL;
END;
$body$ LANGUAGE plpgsql$fn$,
        v_funcname,
        v_view_name,                                            -- watermark key literal
        CASE WHEN v_has_cutoff
             THEN quote_literal(v_cutoff_lit) || '::timestamptz'
             ELSE '''-infinity''::timestamptz' END,             -- default cutoff
        v_partcol,                                              -- NEW.<partcol>
        'INSERT INTO ' || v_iceberg || ' VALUES (' || v_placeholders || ')',
        v_cold_vals,                                            -- args to inner format()
        v_hot_schema, v_hot_relname, v_col_list, v_hot_vals);   -- hot INSERT

    EXECUTE v_func_sql;

    -- The view was just dropped + recreated fresh above, so no stale trigger
    -- exists — create directly (no DROP TRIGGER IF EXISTS, which would only
    -- emit a spurious NOTICE).
    EXECUTE format(
        'CREATE TRIGGER %I INSTEAD OF INSERT ON %I.%I FOR EACH ROW EXECUTE FUNCTION %s()',
        v_trigname, v_schema, v_view_name, v_funcname);

    -- 6. The registry key (schema, relname) is unchanged by the DROP+CREATE
    --    above (the view name is stable), so there is nothing to re-point. The
    --    cross-tier-move path is the post_parse_analyze hook + coldfront._cross_tier_move;
    --    it needs no per-view object here.
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
                    p_iceberg_table, col, coldfront._iceberg_storage_type(pg_type));
            ELSE
                ddl := ddl || format('ALTER TABLE %s ALTER COLUMN %I TYPE %s',
                    p_iceberg_table, col, coldfront._iceberg_storage_type(pg_type));
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
COMMENT ON TABLE coldfront.archive_watermark IS 'Per-tiered-table hot/cold cutoff: ts >= cutoff is hot (PG), ts < cutoff is cold (Iceberg).';
COMMENT ON TABLE coldfront.storage_secret IS 'Cold-store credential; materialized as a DuckDB PERSISTENT SECRET, replicated by value across a Spock mesh, excluded from pg_dump.';
COMMENT ON TABLE coldfront.partition_config IS 'Name-keyed per-table partition/tiering lifecycle config (period, hot_period, retention); replicates by value so every mesh node reads identical config.';
COMMENT ON TABLE coldfront.claims IS 'Ricart-Agrawala bakery: a writer''s outstanding iceberg-commit claim (iceberg_table, snowflake ticket); deleted on release.';
COMMENT ON TABLE coldfront.claim_acks IS 'Ricart-Agrawala bakery: per-peer acknowledgements of a claim, replicated back to the originating writer.';
COMMENT ON TABLE coldfront.deferred_acks IS 'Ricart-Agrawala bakery: acks a peer defers (it holds a smaller-ticket claim) until it releases its own.';
COMMENT ON TABLE coldfront._dummy_dml_target IS 'Internal: anchor relation for the DML rewrite hook; holds no user data.';
