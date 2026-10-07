# Configuring your Object Store

This walkthrough guides you from an empty S3 bucket to a working
ColdFront cold tier. You stand up the ColdFront stack - PostgreSQL and
the Lakekeeper Iceberg catalog - with Docker, and point it at your
bucket. The rows you write land as Apache Iceberg tables in S3, and
PostgreSQL reads them back directly.

---

## Prerequisites

Before you begin, gather the following:

- an S3 bucket (`my-iceberg-bucket` in the examples below).
- the bucket's real region (`eu-west-1` in the examples below).
- a long-term access key, meaning an access key id (`AKIAEXAMPLE...`) and its
  secret (`<your-secret-key>`).

    > **Only long-term keys work.** Lakekeeper's warehouse credential has no
    > field for a session token, so single sign-on (SSO) or temporary
    > session-token credentials do **not** work here. Use a permanent
    > access-key pair with no expiry.
    >
    > This applies to the warehouse's own credential. A deployment that must
    > not store any object-store credential in the database can use vended
    > credentials instead, where the warehouse issues short-lived per-table
    > credentials at access time; see [usage.md](usage.md#vended-credentials).

- permission for the key to read, write and list the bucket (`GetObject` /
  `PutObject` / `DeleteObject` / `ListBucket`) and to abort a failed multipart
  upload (`AbortMultipartUpload`), as in the following example policy:

    ```json
    {
      "Version": "2012-10-17",
      "Statement": [
        {
          "Effect": "Allow",
          "Action": ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket", "s3:AbortMultipartUpload"],
          "Resource": [
            "arn:aws:s3:::my-iceberg-bucket",
            "arn:aws:s3:::my-iceberg-bucket/*"
          ]
        }
      ]
    }
    ```

    DuckDB never aborts a failed multipart upload, so add an
    `AbortIncompleteMultipartUpload` lifecycle rule to the bucket to delete
    leftover parts.

- the ColdFront image, built once by following
  [installation.md](installation.md), which notes the registry access the base
  image needs. Run the commands below from the repo root.

This walkthrough targets a real cloud S3 service that uses virtual-hosted
addressing. For a path-style S3-compatible store (MinIO, SeaweedFS) or GCS, see
the [Storage Backends](usage.md#storage-backends) section of the Using
ColdFront guide instead.

No prior ColdFront knowledge is required to perform the steps on this
page; perform the commands in the order they are presented. The
examples use the following placeholders throughout: bucket
`my-iceberg-bucket`, region `eu-west-1`, key `AKIAEXAMPLE...`, secret
`<your-secret-key>` - substitute your own.

---

## Bringing Up the Stack (Postgres + Lakekeeper)

Our first step begins by starting the stack from the repo root with
a single Compose command. The `docker-compose.yml` file ships in the
ColdFront repository root, so `docker compose` finds it automatically
when you run the command from there:

```bash
docker compose up -d --build
```

If a local Postgres already owns port 5432, pick another host port:

```bash
COLDFRONT_PG_PORT=55432 docker compose up -d --build
```

If port 8181 is taken, set `COLDFRONT_LK_PORT` the same way to move
Lakekeeper's host port. Then use that port in place of `8181` in every `curl`
command in [Configuring Lakekeeper](#configuring-lakekeeper) below.

Wait for Postgres to report healthy (the container name is derived from your
directory, so resolve it at runtime):

```bash
docker inspect -f '{{.State.Health.Status}}' "$(docker compose ps -q db)"   # => healthy
```

The command brings up four containers:

- PostgreSQL, with `pg_duckdb` and `coldfront` already preloaded.
- Lakekeeper, the Iceberg REST catalog.
- Lakekeeper's own catalog database.
- a one-shot migrate job that applies Lakekeeper's schema migrations
  and then exits.

The command does not start the bundled SeaweedFS object-store
emulator; that container is gated behind the `local-store` profile,
reserved for credential-free local evaluation. Because this
walkthrough targets a real cloud S3 bucket, you connect to it
directly and never need SeaweedFS.

---

## Configuring Lakekeeper

Next, use the following three steps to bootstrap Lakekeeper, create the
S3 warehouse, and pre-create the namespace your Iceberg tables will
live in.

First, bootstrap Lakekeeper and accept its terms of use:

```bash
curl -X POST http://localhost:8181/management/v1/bootstrap \
  -H "Content-Type: application/json" \
  -d '{"accept-terms-of-use":true}'
```

Next, create a warehouse that tells Lakekeeper where on S3 your
Iceberg tables live and which credential to use. This is the
**virtual-hosted cloud-S3** profile, and the following flags matter:

- omitting `endpoint` selects native per-Region virtual-hosted addressing over
  HTTPS.
- `path-style-access: false` selects virtual-hosted addressing, because AWS
  plans to discontinue path-style URLs.
- `flavor: "aws"` marks the store as AWS S3, which decides how Lakekeeper uses
  STS, while `s3-compat` is for other S3-compatible stores.
- `sts-enabled: false` and `remote-signing-enabled: false` make the warehouse
  use the long-term access key.

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

The `key-prefix` is an arbitrary path inside the bucket. `coldfront` is only an
example.

A vended-credentials variant is also available. To run ColdFront with no stored
credential ([usage.md](usage.md#vended-credentials)), the warehouse issues
per-table temporary credentials from AWS Security Token Service (STS) instead
of handing the client a static key. Two things change from the warehouse above.

First, create an IAM role scoped to the bucket. Lakekeeper assumes the role per
table and vends the resulting short-lived key, secret, and session token to
ColdFront. Its permission policy grants `GetObject` / `PutObject` /
`DeleteObject` / `ListBucket` (plus the multipart actions) on the bucket and
`arn:aws:s3:::my-iceberg-bucket/*`. Its trust policy lets the warehouse
credential's own IAM identity assume the role, gated by an `ExternalId` that
Lakekeeper must present (confused-deputy protection):

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

Second, update the warehouse: set `sts-enabled: true` and `assume-role-arn` in
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

The role's trust policy above requires `sts:ExternalId`, so the `external-id`
in the warehouse credential must match the `<shared-secret>` in that condition;
Lakekeeper itself makes `external-id` mandatory only for `aws-system-identity`
credentials. On the database side, replace the `set_storage_secret(...)` call
in [Creating the Supporting
Extensions](#creating-the-supporting-extensions) with
`SELECT coldfront.set_storage_secret_vended();`.

Then, pre-create the `public` namespace: resolve the warehouse id,
then create the namespace under it:

```bash
WID=$(curl -s http://localhost:8181/management/v1/warehouse \
  | grep -oE '"warehouse-id":"[^"]+"' | head -1 | cut -d'"' -f4)
[ -n "$WID" ] || { echo "no warehouse id - did the warehouse create return 201?"; exit 1; }

curl -X POST "http://localhost:8181/catalog/v1/$WID/namespaces" \
  -H "Content-Type: application/json" \
  -d '{"namespace":["public"]}'
```

!!! note "Why this step is required (decoupled mode)"

    `coldfront.create_iceberg_table()` (in [Testing with Decoupled
    Mode](#testing-with-decoupled-mode) below) runs `CREATE SCHEMA` and
    `CREATE TABLE` in one transaction. duckdb-iceberg defers the schema create
    to `COMMIT` but sends the table-create POST immediately, so against a
    namespace-less warehouse it fails with HTTP 404. Pre-creating `public`
    makes the in-transaction `CREATE SCHEMA IF NOT EXISTS` a no-op. (Tiered
    mode's archiver creates the namespace itself, so this is only needed for
    the decoupled demo below.)

---

## Creating the Supporting Extensions

Next, connect to the server with psql and open a session inside the
Postgres container:

```bash
docker exec -it "$(docker compose ps -q db)" psql -U coldfront -d coldfront
```

Create both extensions in your database:

```sql
CREATE EXTENSION IF NOT EXISTS pg_duckdb;
CREATE EXTENSION IF NOT EXISTS coldfront;
-- duckdb.install_extension('iceberg') is harmless but NOT needed on the ColdFront
-- image - the patched iceberg extension ships preplaced and autoloads on ATTACH.
```

!!! warning "CREATE EXTENSION coldfront is required and easy to miss"

    The image preloads the `coldfront` shared library, but preloading does not
    register the extension's schema and functions in your database - you must
    `CREATE EXTENSION` it once. Skip that step and the next call fails with
    `schema "coldfront" does not exist`.

Set the cold-tier S3 credential once. The signature is
`set_storage_secret(key_id, secret, endpoint, region, url_style, use_ssl)`; the
last four default to `NULL`, `'us-east-1'`, `'path'`, `false`:

```sql
SELECT coldfront.set_storage_secret('AKIAEXAMPLE...', '<your-secret-key>', NULL, 'eu-west-1');
```

!!! warning "The 3rd argument (endpoint) must be NULL for a cloud S3 endpoint"

    A `NULL` endpoint selects DuckDB's native per-Region virtual-hosted + HTTPS
    addressing. The 4th argument is your bucket's region, from which DuckDB
    derives the endpoint. The SeaweedFS form you may have seen elsewhere passes
    a non-NULL endpoint and no region - do **not** use that shape for cloud S3.

---

## Testing with Decoupled Mode

A decoupled (iceberg-only) table has no Postgres hot tier; every row lives in
Iceberg on S3, and you read and write it through a normal-looking Postgres
relation. This is the quickest way to prove the whole path works:

```sql
SELECT coldfront.create_iceberg_table(
  'public', 's3_demo',
  '[
    {"name": "id",   "type": "bigint"},
    {"name": "ts",   "type": "timestamptz"},
    {"name": "note", "type": "text"}
  ]'::jsonb,
  '{month(ts)}');

INSERT INTO public.s3_demo VALUES (1, now(), 'hello from S3');
INSERT INTO public.s3_demo VALUES (2, now(), 'second row');

SELECT count(*) AS n, max(note) AS last FROM public.s3_demo;
-- => n = 2, last = 'second row'
```

That `count(*) = 2` is read back through `iceberg_scan` from your real S3
bucket - the round trip is complete.

### Tiered Mode is the Headline Feature

Decoupled mode is just the warm-up. ColdFront's real purpose is
**tiered** tables: a partitioned Postgres table whose hot partitions
automatically age out to Iceberg on S3 once they pass a retention
window, after which reads transparently union live Postgres data with
cold S3 data and writes route to the correct tier.

You drive tiered tables with the `archiver` binary against a small YAML config
(Postgres DSN, the `wh` warehouse, your S3 region/keys); each table's lifecycle
is registered with `archiver register`. The credential and warehouse you set up
above are exactly what it needs. See [usage.md](usage.md) for the archiver
config and the partition CLI.

---

## Verifying the Configuration

You can confirm the objects physically landed in the bucket by
exporting your region as an environment variable, and then connecting
with an S3 client (this example uses the `aws` CLI):

```bash
export AWS_DEFAULT_REGION=eu-west-1
aws s3 ls s3://my-iceberg-bucket/coldfront/ --recursive
```

Iceberg stores each table directly under your `key-prefix`, as
`coldfront/<table-uuid>/`, with a `data/` directory (parquet) and a `metadata/`
directory (metadata JSON, `*.avro` manifests, snapshot files) - UUID paths, not
your table name. (A namespace created on a Lakekeeper release before 0.13 keeps
its `coldfront/<namespace-uuid>/<table-uuid>/` layout.) "Where did `s3_demo`
go?" → look under the UUID path beneath your `key-prefix`.

Work through the following checklist if something failed:

- Check that you ran `CREATE EXTENSION coldfront` once in your database.
  Preloading is not the same as creating the extension, and a missing extension
  produces `schema "coldfront" does not exist`.
- Check that `set_storage_secret(..., NULL, 'eu-west-1')` has `NULL` as its
  third argument (native virtual-hosted addressing over HTTPS) and your real
  region as its fourth. A non-NULL endpoint applies `url_style` and `use_ssl`,
  which default to path-style over plain HTTP. A wrong region sends requests to
  another Region's endpoint, which S3 rejects (with HTTP 400 for a bucket in a
  Region launched after 2019-03-20).
- Check that the namespace `public` exists in Lakekeeper before
  `create_iceberg_table` runs. Without the namespace, the decoupled create
  fails with HTTP 404.
- Check that the key is a long-term key, not an SSO or temporary session-token
  credential.

## Next Steps

To go further with ColdFront, consult the following guides:

- The [Using ColdFront](usage.md) guide covers the archiver config, the
  partition CLI, and the other storage backends.
- The [Compaction](compaction.md) guide covers cold-tier maintenance on the
  bucket.
- The [Architecture](architecture.md) overview describes how the cold tier is
  read and written.
