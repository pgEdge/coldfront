# pgedge-lakekeeper

[Lakekeeper](https://lakekeeper.io) is an implementation of the Apache Iceberg
REST Catalog. This package installs the prebuilt `lakekeeper` binary and a
systemd service (`lakekeeper.service`).

The service is **not enabled or started automatically** — Lakekeeper needs an
external PostgreSQL database and some required configuration before it can run.

## 1. Provide a PostgreSQL database

Lakekeeper stores all catalog state in PostgreSQL **15 or newer**. Create a
database and a role, for example:

```sql
CREATE ROLE lakekeeper LOGIN PASSWORD 'change-me';
CREATE DATABASE lakekeeper OWNER lakekeeper;
```

The one-time migration (step 3) creates the extensions Lakekeeper needs
(`uuid-ossp`, `pgcrypto`, `pg_trgm`, `btree_gin`, `btree_gist`), so the role
must be able to `CREATE EXTENSION` — or create them ahead of time as a
superuser.

## 2. Configure `/etc/lakekeeper/lakekeeper.env`

Edit the environment file and set at least the two required variables:

- `LAKEKEEPER__PG_DATABASE_URL_WRITE` — the PostgreSQL connection string.
- `LAKEKEEPER__PG_ENCRYPTION_KEY` — a strong random secret that encrypts stored
  credentials. Generate one with `openssl rand -base64 32`. **Keep it stable and
  back it up**: it must be identical across nodes sharing the same catalog, and
  losing it makes stored secrets unrecoverable.

Optional settings (read replica, listen address/port, authorization backend)
are documented inline in the file. If no authorization backend is configured
the catalog is **open** — configure authentication/authorization before
exposing it in production.

## 3. Run the one-time database migration

Lakekeeper must migrate the database before the first `serve`:

```bash
# Load the same settings the service uses, then migrate as the lakekeeper user.
set -a; . /etc/lakekeeper/lakekeeper.env; set +a
sudo -E -u lakekeeper /usr/bin/lakekeeper migrate
```

Alternatively, uncomment `ExecStartPre=/usr/bin/lakekeeper migrate` in
`/usr/lib/systemd/system/lakekeeper.service` to run the idempotent migration
automatically on every start.

## 4. Start the service

```bash
sudo systemctl enable --now lakekeeper
sudo systemctl status lakekeeper
```

Lakekeeper listens on `0.0.0.0:8181` by default. Logs go to the journal
(`journalctl -u lakekeeper`).
