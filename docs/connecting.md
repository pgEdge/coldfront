# Connecting to ColdFront

An application connects to ColdFront as an ordinary PostgreSQL client; the
only ColdFront-specific step is onboarding its role using the principle of
least privilege.

## Least-Privilege Application Roles

Application roles need no superuser and no server-file access, yet they read
and write the cold tier through the same transparent view. Onboarding an
application role requires a single call:

```sql
SELECT coldfront.grant_app_access('alice');
```

grant_app_access grants only the minimum the cold path needs:

- membership in duckdb.postgres_role.
- SET on the duckdb.unsafe_allow_execution_inside_functions parameter.
- schema USAGE.
- `SELECT` on the registry and the watermark table.
- DML on the dual-write anchor table.
- DML on every registered view and the hot table behind it.
- USAGE and `SELECT` on the hot table's sequences.

The tables and views above are derived from the registry, not hardcoded;
the call also grants EXECUTE on a fixed allow-list of runtime cold-path
functions. The call is idempotent
and is not executable by PUBLIC, so an application role can never self-grant.
The role is never granted pg_read_server_files or pg_write_server_files, so it
has no host-file access. `CREATE ROLE` and `GRANT` both replicate over Spock,
so you onboard a role once on any node and it propagates across the mesh.

The Docker image sets `duckdb.postgres_role` to `coldfront_duckdb` and creates
that role when it initializes a new data directory. To name a different role,
set the container's `COLDFRONT_DUCKDB_ROLE` environment variable before that
first start. An empty value keeps pg_duckdb's default, under which only
superusers run DuckDB, so grant_app_access then fails with an error.

For how the non-superuser path works - the `SECURITY DEFINER` attach helpers,
the `PGC_SUSET` / `GUC_SUPERUSER_ONLY` config hardening, the
`duckdb.postgres_role` default that the image sets up, and how least privilege
holds across a Spock mesh - see
[Architecture: non-superuser app roles](architecture_guides/index.md#non-superuser-app-roles-least-privilege).
