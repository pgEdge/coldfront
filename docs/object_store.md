# Configuring your Object Store

This walkthrough guides you from an empty bucket or container to a
working ColdFront cold tier. You stand up the ColdFront stack -
PostgreSQL and the Lakekeeper Iceberg catalog - with Docker, and point
it at your object store. ColdFront supports four cold-store backends:
S3-compatible stores (SeaweedFS, MinIO), virtual-hosted cloud S3 (AWS),
Google Cloud Storage, and Azure ADLS Gen2. Configure **exactly one** of
them for a given deployment; this guide shows the bucket/container
setup, the Lakekeeper warehouse, and the ColdFront credential for each.

---

## Prerequisites

Before you begin, decide which backend you are using, since the
bucket/container details, credential type, and Lakekeeper warehouse
profile differ by backend:

- **S3-compatible stores** (SeaweedFS, MinIO) need a bucket, the
  store's endpoint URL, and a long-term access key and secret.
- **Virtual-hosted cloud S3** (AWS) needs a bucket, the bucket's real
  Region, and a long-term access key and secret.
- **Google Cloud Storage** needs a bucket and an
  [HMAC key pair](https://cloud.google.com/storage/docs/authentication/hmackeys)
  (GCS has no native Lakekeeper profile; it is configured as an S3
  backend pointed at GCS's S3-interoperability endpoint).
- **Azure ADLS Gen2** needs a storage account, a filesystem (container)
  in that account, and the account's access key.

For any backend that takes a long-term key (S3-compatible, virtual-hosted
S3, and GCS):

> **Only long-term keys work.** Lakekeeper's warehouse credential has no
> field for a session token, so single sign-on (SSO) or temporary
> session-token credentials do **not** work here. Use a permanent
> access-key pair with no expiry.
>
> This applies to the warehouse's own credential. A deployment that must
> not store any object-store credential in the database can use vended
> credentials instead, where the warehouse issues short-lived per-table
> credentials at access time. Vended credentials are available for AWS S3
> and Azure ADLS Gen2, but not for GCS or other S3-compatible stores; see
> [vended_credentials.md](vended_credentials.md).

For AWS S3 and S3-compatible stores, grant the key permission to read,
write, and list the bucket (`GetObject` / `PutObject` / `DeleteObject` /
`ListBucket`) and to abort a failed multipart upload
(`AbortMultipartUpload`), as in the following example policy:

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

You also need the ColdFront image, built once by following
[installation.md](installation.md), which notes the registry access the
base image needs. Run the commands below from the repo root.

No prior ColdFront knowledge is required to perform the steps on this
page; perform the commands in the order they are presented. The
examples use placeholder bucket, account, and credential values
throughout - substitute your own.

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

The command also starts a bundled SeaweedFS object-store emulator,
gated behind the `local-store` profile, reserved for credential-free
local evaluation of the S3-compatible path. If you are connecting to a
real S3-compatible store, AWS S3, GCS, or Azure, you connect to it
directly and never need SeaweedFS.

---

## Configuring Lakekeeper

Next, bootstrap Lakekeeper, then create a warehouse and pre-create the
namespace your Iceberg tables will live in. The warehouse and
credential shape depend on which backend you chose in
[Prerequisites](#prerequisites); follow the matching subsection below.

First, bootstrap Lakekeeper and accept its terms of use:

```bash
curl -X POST http://localhost:8181/management/v1/bootstrap \
  -H "Content-Type: application/json" \
  -d '{"accept-terms-of-use":true}'
```

### S3-Compatible Stores (SeaweedFS, MinIO)

Create a warehouse with a path-style profile pointed at your store's
endpoint:

```bash
curl -X POST http://localhost:8181/management/v1/warehouse \
  -H "Content-Type: application/json" \
  -d '{
    "warehouse-name": "wh",
    "storage-profile": {
      "type": "s3",
      "bucket": "my-iceberg-bucket",
      "key-prefix": "coldfront",
      "region": "us-east-1",
      "endpoint": "https://my-store.example.com:9000",
      "path-style-access": true,
      "flavor": "s3-compat",
      "sts-enabled": false,
      "remote-signing-enabled": false
    },
    "storage-credential": {
      "type": "s3",
      "credential-type": "access-key",
      "aws-access-key-id": "<your-access-key-id>",
      "aws-secret-access-key": "<your-secret-key>"
    }
  }'
# => HTTP 201
```

`region` defaults to `us-east-1` if your store does not use Region
semantics. Set the ColdFront credential with an explicit endpoint:

```sql
SELECT coldfront.set_storage_secret('<your-access-key-id>', '<your-secret-key>',
  'my-store.example.com:9000', 'us-east-1', 'path', true);
```

### Virtual-Hosted Cloud S3 (AWS)

This is the **virtual-hosted cloud-S3** profile, and the following
flags matter:

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

Set the cold-tier credential with a `NULL` endpoint, which selects
DuckDB's native per-Region virtual-hosted addressing:

```sql
SELECT coldfront.set_storage_secret('AKIAEXAMPLE...', '<your-secret-key>', NULL, 'eu-west-1');
```

!!! warning "The 3rd argument (endpoint) must be NULL for a cloud S3 endpoint"

    A `NULL` endpoint selects DuckDB's native per-Region virtual-hosted + HTTPS
    addressing. The 4th argument is your bucket's region, from which DuckDB
    derives the endpoint. A non-NULL endpoint applies `url_style` and
    `use_ssl`, which default to path-style over plain HTTP - do **not** use
    that shape for cloud S3.

A vended-credentials variant is also available. To run ColdFront with no stored
credential ([vended_credentials.md](vended_credentials.md)), the warehouse issues
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
above with `SELECT coldfront.set_storage_secret_vended();`.

### Google Cloud Storage

Google Cloud Storage is *not a separate Lakekeeper profile*: it uses an
`s3` storage profile pointed at GCS's S3-interoperability endpoint,
with an HMAC key pair standing in for an access key:

```bash
curl -X POST http://localhost:8181/management/v1/warehouse \
  -H "Content-Type: application/json" \
  -d '{
    "warehouse-name": "wh",
    "storage-profile": {
      "type": "s3",
      "bucket": "my-iceberg-bucket",
      "key-prefix": "coldfront",
      "region": "us-east-1",
      "endpoint": "https://storage.googleapis.com",
      "path-style-access": true,
      "flavor": "s3-compat",
      "sts-enabled": false,
      "remote-signing-enabled": false
    },
    "storage-credential": {
      "type": "s3",
      "credential-type": "access-key",
      "aws-access-key-id": "<your-hmac-access-key-id>",
      "aws-secret-access-key": "<your-hmac-secret>"
    }
  }'
# => HTTP 201
```

Lakekeeper's native `gcs` profile is service-account only and is
**not** used here. Set the ColdFront credential the same way as any
other S3-compatible endpoint:

```sql
SELECT coldfront.set_storage_secret('<your-hmac-access-key-id>', '<your-hmac-secret>',
  'storage.googleapis.com', 'us-east-1', 'path', true);
```

GCS has no STS equivalent on the interoperability endpoint, so it has
no vended-credentials variant; it always uses this static HMAC key
pair.

### Azure ADLS Gen2

Azure ADLS Gen2 uses its own Lakekeeper warehouse type, `adls`, naming
a storage account and a filesystem (container) within it:

```bash
curl -X POST http://localhost:8181/management/v1/warehouse \
  -H "Content-Type: application/json" \
  -d '{
    "warehouse-name": "wh",
    "storage-profile": {
      "type": "adls",
      "filesystem": "my-iceberg-fs",
      "account-name": "myaccount"
    },
    "storage-credential": {
      "type": "az",
      "credential-type": "shared-access-key",
      "key": "<your-account-key>"
    }
  }'
# => HTTP 201
```

The warehouse's `storage-credential` is Lakekeeper's own credential for
reaching the account; it is separate from the credential ColdFront
itself uses. Set ColdFront's credential with
`set_storage_secret_azure()` instead of `set_storage_secret()` - it
takes a CONFIG-provider connection string, with the account key riding
inside `AccountKey=…`:

```sql
SELECT coldfront.set_storage_secret_azure(
    'DefaultEndpointsProtocol=https;AccountName=myaccount;AccountKey=<your-account-key>;EndpointSuffix=core.windows.net');
```

`set_storage_secret_azure()` writes the same `coldfront.storage_secret` row
(replicated, `pg_dump`-excluded) and materializes a `TYPE azure` PERSISTENT
SECRET. The Azure cold tier is subject to the soft-delete / change-feed
restriction in [Caveats](index.md#caveats).

A vended-credentials variant is also available: set `sas-enabled` on the
warehouse (on by default) and Lakekeeper vends a per-container SAS
token; the warehouse credential can then be a `shared-access-key`,
`client-credentials`, or `azure-system-identity`. On the database side,
use `SELECT coldfront.set_storage_secret_vended('azure');` instead of
`set_storage_secret_azure()`.

### Pre-Creating the Namespace

Regardless of backend, resolve the warehouse id and pre-create the
`public` namespace under it:

```bash
WID=$(curl -s http://localhost:8181/management/v1/warehouse \
  | grep -oE '"warehouse-id":"[^"]+"' | head -1 | cut -d'"' -f4)
[ -n "$WID" ] || { echo "no warehouse id - did the warehouse create return 201?"; exit 1; }

curl -X POST "http://localhost:8181/catalog/v1/$WID/namespaces" \
  -H "Content-Type: application/json" \
  -d '{"namespace":["public"]}'
```

!!! note "Why this step is required (decoupled mode)"

    `coldfront.create_iceberg_table()` (in
    [Testing with Decoupled Mode](#testing-with-decoupled-mode) below) runs
    `CREATE SCHEMA` and `CREATE TABLE` in one transaction. duckdb-iceberg
    defers the schema create to `COMMIT` but sends the table-create POST
    immediately, so against a namespace-less warehouse it fails with HTTP
    404. Pre-creating `public`
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

Now run the `set_storage_secret` (or `set_storage_secret_azure` /
`set_storage_secret_vended`) call from whichever backend subsection you
followed in [Configuring Lakekeeper](#configuring-lakekeeper) above.

---

## Testing with Decoupled Mode

A decoupled (iceberg-only) table has no Postgres hot tier; every row lives in
Iceberg on your object store, and you read and write it through a
normal-looking Postgres relation. This is the quickest way to prove the whole
path works:

```sql
SELECT coldfront.create_iceberg_table(
  'public', 'cold_demo',
  '[
    {"name": "id",   "type": "bigint"},
    {"name": "ts",   "type": "timestamptz"},
    {"name": "note", "type": "text"}
  ]'::jsonb,
  '{month(ts)}');

INSERT INTO public.cold_demo VALUES (1, now(), 'hello from the cold tier');
INSERT INTO public.cold_demo VALUES (2, now(), 'second row');

SELECT count(*) AS n, max(note) AS last FROM public.cold_demo;
-- => n = 2, last = 'second row'
```

That `count(*) = 2` is read back through `iceberg_scan` from your real
object store - the round trip is complete.

### Tiered Mode is the Headline Feature

Decoupled mode is just the warm-up. ColdFront's real purpose is
**tiered** tables: a partitioned Postgres table whose hot partitions
automatically age out to the cold tier once they pass a retention
window, after which reads transparently union live Postgres data with
cold data and writes route to the correct tier.

You drive tiered tables with the `archiver` binary against a small YAML config
(Postgres DSN, your warehouse name, and your backend's credentials); each
table's lifecycle is registered with `archiver register`. The credential and
warehouse you set up above are exactly what it needs. See
[usage.md](using_coldfront/index.md) for the archiver config and the partition CLI.

---

## Verifying the Configuration

You can confirm the objects physically landed in your object store
using that backend's own client. The following table shows an example
command per backend:

| Backend | Example verification command |
|---|---|
| S3-compatible / AWS S3 | `aws s3 ls s3://my-iceberg-bucket/coldfront/ --recursive` |
| Google Cloud Storage | `gsutil ls -r gs://my-iceberg-bucket/coldfront/` |
| Azure ADLS Gen2 | `az storage blob list --account-name myaccount --container-name my-iceberg-fs --prefix coldfront --output table` |

For AWS S3, export your region first:

```bash
export AWS_DEFAULT_REGION=eu-west-1
aws s3 ls s3://my-iceberg-bucket/coldfront/ --recursive
```

Iceberg stores each table directly under your `key-prefix` (S3-family
backends) or filesystem root (Azure), as `coldfront/<table-uuid>/`,
with a `data/` directory (parquet) and a `metadata/` directory
(metadata JSON, `*.avro` manifests, snapshot files) - UUID paths, not
your table name. (A namespace created on a Lakekeeper release before
0.13 keeps its `coldfront/<namespace-uuid>/<table-uuid>/` layout.)
"Where did `cold_demo` go?" → look under the UUID path beneath your
`key-prefix`.

Work through the following checklist if something failed:

- Check that you ran `CREATE EXTENSION coldfront` once in your database.
  Preloading is not the same as creating the extension, and a missing extension
  produces `schema "coldfront" does not exist`.
- For S3-family backends, check that `set_storage_secret(...)` has the right
  endpoint argument for your backend: `NULL` for virtual-hosted cloud S3, or an
  explicit host for an S3-compatible store or GCS. A wrong region sends
  requests to another Region's endpoint, which S3 rejects (with HTTP 400 for a
  bucket in a Region launched after 2019-03-20).
- For Azure, check that the connection string passed to
  `set_storage_secret_azure()` has the right `AccountName` and `AccountKey`.
- Check that the namespace `public` exists in Lakekeeper before
  `create_iceberg_table` runs. Without the namespace, the decoupled create
  fails with HTTP 404.
- Check that the key is a long-term key, not an SSO or temporary session-token
  credential (S3-family backends).

## Next Steps

To go further with ColdFront, consult the following guides:

- The [Using ColdFront](using_coldfront/index.md) guide details the archiver config, the
  partition CLI, and vended credentials in more detail.
- The [Compaction](compaction.md) guide documents cold-tier maintenance on
  the object store.
- The [Architecture](architecture_guides/index.md) overview describes how the cold tier is
  read and written.
