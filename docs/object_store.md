# Get ColdFront running on S3

This walkthrough takes you from an empty S3 bucket to a working
ColdFront cold tier in one sitting. You stand up the ColdFront stack
(PostgreSQL + the Lakekeeper Iceberg catalog) with Docker, point it at
your bucket, and write rows that land as Apache Iceberg tables in S3 -
readable straight back through Postgres.

It targets a real cloud S3 service that uses virtual-hosted addressing.
For a path-style S3-compatible store (MinIO, SeaweedFS) or GCS, see
[usage.md → Storage backends](usage.md#storage-backends) instead.

No prior ColdFront knowledge assumed. Copy-paste top to bottom.
Placeholders used throughout: bucket `my-iceberg-bucket`, region
`eu-west-1`, key `AKIAEXAMPLE...`, secret `<your-secret-key>` -
substitute your own.

---

## 1. Prerequisites

Before you begin, gather the following:

- **An S3 bucket** - `my-iceberg-bucket` below.
- **Its region** - `eu-west-1` below. Use your bucket's real region.
- **A long-term access key** - an access key id (`AKIAEXAMPLE...`) and
  secret (`<your-secret-key>`).

  > **Long-term keys only.** Lakekeeper's warehouse credential has no
  > field for a session token, so single sign-on (SSO) or temporary
  > session-token credentials do **not** work here. Use a permanent
  > access-key pair with no expiry.
  >
  > This applies to the warehouse's own credential. A deployment that
  > must not store any object-store credential in the database can use
  > vended credentials instead, where the warehouse mints short-lived
  > per-table credentials at access time; see
  > [usage.md](usage.md#vended-minted-credentials).

- **Permissions** - the key needs read/write/list on the bucket
  (`GetObject` / `PutObject` / `DeleteObject` / `ListBucket`). Example
  policy:

  ```json
  {
    "Version": "2012-10-17",
    "Statement": [
      {
        "Effect": "Allow",
        "Action": ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket"],
        "Resource": [
          "arn:aws:s3:::my-iceberg-bucket",
          "arn:aws:s3:::my-iceberg-bucket/*"
        ]
      }
    ]
  }
  ```

- **The ColdFront image, built once.** Build it by following
  [installation.md](installation.md)
  (it notes the registry access the base image needs). Run the commands
  below from the repo root.

---

## 2. Bring up the stack (Postgres + Lakekeeper)

Start the stack from the repo root with a single Compose command:

```bash
docker compose up -d --build
```

This starts **Postgres** (with `pg_duckdb` and `coldfront` preloaded),
**Lakekeeper** (the Iceberg REST catalog), Lakekeeper's **own catalog
Postgres**, and a one-shot **migrate** job. It does **not** start the
bundled SeaweedFS - that is gated behind the `local-store` profile for
credential-free local eval. For cloud S3 you talk to the bucket
directly, so you don't need it.

If a local Postgres already owns port 5432, pick another host port:

```bash
COLDFRONT_PG_PORT=55432 docker compose up -d --build
```

Wait for Postgres to report healthy (the container name is derived from
your directory, so resolve it at runtime):

```bash
docker inspect -f '{{.State.Health.Status}}' "$(docker compose ps -q db)"   # => healthy
```

---

## 3. One-time Lakekeeper setup

Run the following three calls once each.

### 3a. Bootstrap Lakekeeper

Bootstrap Lakekeeper and accept its terms of use:

```bash
curl -X POST http://localhost:8181/management/v1/bootstrap \
  -H "Content-Type: application/json" \
  -d '{"accept-terms-of-use":true}'
```

### 3b. Create the S3 warehouse

A warehouse tells Lakekeeper where on S3 your Iceberg tables live and
which credential to use. This is the **virtual-hosted cloud-S3** profile
- these flags matter:

- `endpoint` **omitted** ⇒ native per-Region virtual-hosted + HTTPS
  addressing.
- `path-style-access: false` - required for virtual-hosted S3;
  path-style fails on any Region launched after 2019.
- `flavor: "aws"` - the Lakekeeper profile for virtual-hosted S3, not
  `s3-compat`.
- `sts-enabled: false` and `remote-signing-enabled: false` - long-term
  access key.

Create the warehouse with those flags set:

```bash
curl -X POST http://localhost:8181/management/v1/warehouse \
  -H "Content-Type: application/json" \
  -d '{
    "warehouse-name": "wh",
    "storage-profile": {
      "type": "s3",
      "bucket": "my-iceberg-bucket",
      "key-prefix": "coldfront",
      "region": "eu-west-1",
      "path-style-access": false,
      "flavor": "aws",
      "sts-enabled": false,
      "remote-signing-enabled": false
    },
    "storage-credential": {
      "type": "s3",
      "credential-type": "access-key",
      "aws-access-key-id": "AKIAEXAMPLE...",
      "aws-secret-access-key": "<your-secret-key>"
    }
  }'
# => HTTP 201
```

The `key-prefix` is an arbitrary path inside the bucket; `coldfront` is
just an example.

**Vended-credentials variant.** To run ColdFront with no stored
credential ([usage.md](usage.md#vended-minted-credentials)), the
warehouse mints per-table STS credentials instead of handing the client
a static key. Two things change from the warehouse above.

First, an IAM role scoped to the bucket. Lakekeeper assumes it per table
and vends the resulting short-lived key, secret, and session token to
ColdFront. Its permission policy grants `GetObject` / `PutObject` /
`DeleteObject` / `ListBucket` (plus the multipart actions) on the bucket
and `arn:aws:s3:::my-iceberg-bucket/*`. Its trust policy lets the
warehouse credential's own IAM identity assume it, gated by an
`ExternalId` that Lakekeeper must present (confused-deputy protection):

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {"AWS": "arn:aws:iam::<account-id>:user/<warehouse-iam-user>"},
    "Action": "sts:AssumeRole",
    "Condition": {"StringEquals": {"sts:ExternalId": "<shared-secret>"}}
  }]
}
```

Second, the warehouse: set `sts-enabled: true` and `assume-role-arn` in
the `storage-profile`, and add the matching `external-id` to the
`storage-credential` (which stays the warehouse's own long-term key):

```json
"storage-profile": {
  "...": "...(bucket, region, path-style-access:false, flavor:aws as above)",
  "sts-enabled": true,
  "assume-role-arn": "arn:aws:iam::<account-id>:role/<role-that-scopes-the-bucket>"
},
"storage-credential": {
  "type": "s3", "credential-type": "access-key",
  "aws-access-key-id": "AKIAEXAMPLE...", "aws-secret-access-key": "<your-secret-key>",
  "external-id": "<shared-secret>"
}
```

An `external-id` is **required** with `assume-role-arn`; the `<shared-secret>`
in the warehouse and in the role's trust condition must match. On the
database side, replace the `set_storage_secret(...)` call in Section 4
with `SELECT coldfront.set_storage_secret_vended();`.

### 3c. Pre-create the `default` namespace

Resolve the warehouse id, then create the `default` namespace under it:

```bash
WID=$(curl -s http://localhost:8181/management/v1/warehouse \
  | grep -oE '"warehouse-id":"[^"]+"' | head -1 | cut -d'"' -f4)
[ -n "$WID" ] || { echo "no warehouse id — did step 3b return 201?"; exit 1; }

curl -X POST "http://localhost:8181/catalog/v1/$WID/namespaces" \
  -H "Content-Type: application/json" \
  -d '{"namespace": ["default"]}'
```

> **Why this step is required (decoupled mode).**
> `coldfront.create_iceberg_table()` (Section 5) runs `CREATE SCHEMA`
> and `CREATE TABLE` in one transaction. The schema create is deferred
> to COMMIT but the table create is POSTed eagerly, so against a
> namespace-less warehouse it 404s. Pre-creating `default` makes the
> in-transaction `CREATE SCHEMA IF NOT EXISTS` a no-op. (Tiered mode's
> archiver creates the namespace itself, so this is only needed for the
> decoupled demo below.)

---

## 4. Database setup

Open psql inside the Postgres container:

```bash
docker exec -it "$(docker compose ps -q db)" psql -U coldfront -d coldfront
```

Create both extensions in your database:

```sql
CREATE EXTENSION IF NOT EXISTS pg_duckdb;
CREATE EXTENSION IF NOT EXISTS coldfront;
-- duckdb.install_extension('iceberg') is harmless but NOT needed on the ColdFront
-- image — the patched iceberg extension ships preplaced and autoloads on ATTACH.
```

> **`CREATE EXTENSION coldfront` is required and easy to miss.** The
> image preloads the `coldfront` shared library, but preloading does
> not register the extension's schema and functions in your database -
> you must `CREATE EXTENSION` it once. Skip it and the next call fails
> with `schema "coldfront" does not exist`.

Set the cold-tier S3 credential once. The signature is
`set_storage_secret(key_id, secret, endpoint, region, url_style,
use_ssl)`; the last four default to `NULL`, `'us-east-1'`, `'path'`,
`false`:

```sql
SELECT coldfront.set_storage_secret('AKIAEXAMPLE...', '<your-secret-key>', NULL, 'eu-west-1');
```

> **The 3rd argument (endpoint) must be `NULL` for a cloud S3
> endpoint** - that selects DuckDB's native per-Region virtual-hosted +
> HTTPS addressing (required for Regions launched after 2019). The 4th
> argument is your bucket's region. The SeaweedFS form you may have seen
> elsewhere passes a non-NULL endpoint and no region - do **not** use
> that shape for cloud S3.

---

## 5. Fastest demo - decoupled mode (the table lives entirely in S3)

A decoupled (iceberg-only) table has no Postgres hot tier; every row
lives in Iceberg on S3, and you read and write it through a
normal-looking Postgres relation. This is the quickest way to prove the
whole path works:

```sql
SELECT coldfront.create_iceberg_table(
  'public', 's3_demo',
  '[
    {"name": "id",   "type": "bigint"},
    {"name": "ts",   "type": "timestamptz"},
    {"name": "note", "type": "text"}
  ]'::jsonb);

INSERT INTO public.s3_demo VALUES (1, now(), 'hello from S3');
INSERT INTO public.s3_demo VALUES (2, now(), 'second row');

SELECT count(*) AS n, max(note) AS last FROM public.s3_demo;
-- => n = 2, last = 'second row'
```

That `count(*) = 2` is read back through `iceberg_scan` from your real
S3 bucket - the round trip is complete.

### Tiered mode - the headline feature

Decoupled mode is the warm-up. ColdFront's real purpose is **tiered**
tables: a partitioned Postgres table whose hot partitions automatically
age out to Iceberg on S3 once they pass a retention window, after which
reads transparently union live Postgres data with cold S3 data and
writes route to the correct tier.

You drive it with the `archiver` binary against a small YAML config
(Postgres DSN, the `wh` warehouse, your S3 region/keys); each table's
lifecycle is registered with `archiver register`. The credential and
warehouse you set up above are exactly what it needs. See
[usage.md](usage.md) for the archiver config and the partition CLI.

---

## 6. Verify in S3 and troubleshoot

Confirm objects physically landed (an S3 client such as the `aws` CLI,
region exported):

```bash
export AWS_DEFAULT_REGION=eu-west-1
aws s3 ls s3://my-iceberg-bucket/coldfront/ --recursive
```

Iceberg stores objects under `coldfront/<namespace-uuid>/<table-uuid>/`
with a `data/` directory (parquet) and a `metadata/` directory (metadata
JSON, `*.avro` manifests, snapshot files) - UUID paths, not your table
name. "Where did `s3_demo` go?" → look under the UUID path beneath your
`key-prefix`.

Work through this checklist if something failed:

1. **`CREATE EXTENSION coldfront`** - ran it once in your database?
   Preloading is not the same as creating the extension. Symptom:
   `schema "coldfront" does not exist`.
2. **`set_storage_secret(..., NULL, 'eu-west-1')`** - 3rd arg `NULL`
   (native vhost+HTTPS), 4th arg your real region? A non-NULL endpoint
   forces path-style and breaks modern Regions (HTTP 400).
3. **Namespace `default` pre-created** in Lakekeeper before
   `create_iceberg_table`? Without it the decoupled create 404s.
4. **Long-term key** - not an SSO / temporary session-token credential.
