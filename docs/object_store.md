# Configuring your Object Store

This guide takes you from an empty bucket or container to a working ColdFront
cold tier. Before you create it, you prepare PostgreSQL and the Lakekeeper
Iceberg catalog, whether you installed them with packages, on bare metal, or
on Docker, then point them at your object store.

ColdFront supports four cold-store backends; configure exactly one of them for
each deployment:

- [S3-compatible stores](#configuring-an-s3-compatible-store), such as
  SeaweedFS and MinIO.
- [Virtual-hosted cloud S3 (AWS)](#configuring-aws-s3).
- [Google Cloud Storage](#configuring-google-cloud-storage).
- [Azure ADLS Gen2](#configuring-azure-adls-gen2).

For each backend, this guide covers the bucket or container setup, the
Lakekeeper warehouse, and the ColdFront credential.

## Before You Begin

Before you configure your backend, complete the following steps:

- Configure PostgreSQL as described in
  [Configuring PostgreSQL](configuration.md#configuring-postgresql).
- Install, configure, and start Lakekeeper as described in
  [Configuring Lakekeeper](configure_lakekeeper.md), and bootstrap it as
  described in step 1 of
  [Bootstrapping Lakekeeper](configure_lakekeeper.md#bootstrapping-lakekeeper).
- Create the `pg_duckdb` and `coldfront` extensions in each database that
  uses ColdFront, as described in
  [Configuring PostgreSQL for Lakekeeper](configure_lakekeeper.md#configuring-postgresql-for-lakekeeper).

Then, open a psql session in each database that uses ColdFront, replacing
`<database>` with the database's name. On a package or bare-metal deployment,
connect as a superuser, such as `postgres`:

```bash
sudo -u postgres psql -d <database>
```

On a Docker deployment, open the session in the PostgreSQL container:

```bash
docker exec -it "$(docker compose ps -q db)" psql -U coldfront -d <database>
```

The commands on this page reach Lakekeeper's management API at
`http://localhost:8181`; if Lakekeeper runs on another host or port, use that
address instead.

## Configuring a Storage Backend

Before you start, create the bucket or container and its access credential
with your provider's own tools; the sections below assume that they exist.
Then, follow the section for your backend to grant the bucket permissions
where needed, create the Lakekeeper warehouse, and store the ColdFront
credential.

!!! warning "Only long-term keys work"

    For a backend that takes a long-term key (an S3-compatible store, AWS S3,
    or GCS), Lakekeeper's warehouse credential has no field for a session
    token, so single sign-on (SSO) or temporary session-token credentials do
    not work. Use a permanent access-key pair with no expiry.

    This applies to the warehouse's own credential. A deployment that must not
    store any object-store credential in the database can use vended
    credentials instead, where the warehouse issues short-lived per-table
    credentials at access time. Vended credentials are available for AWS S3
    and Azure ADLS Gen2, but not for GCS or other S3-compatible stores; see
    [Using Vended Credentials](vended_credentials.md).

The examples on this page use placeholder bucket, account, and credential
values; substitute your own.

### Configuring an S3-Compatible Store

An S3-compatible store, such as SeaweedFS or MinIO, needs a bucket, the
store's endpoint URL, and a long-term access key and secret. Use the following
steps to configure it:

1. Grant the identity that owns your access key the same permissions as the
    [AWS S3 example policy](#configuring-aws-s3): `GetObject`, `PutObject`,
    `DeleteObject`, and `ListBucket` on the bucket, and
    `AbortMultipartUpload`. Use your store's own access control to grant
    them. If your store supports lifecycle rules, add an
    `AbortIncompleteMultipartUpload` rule to delete the leftover parts of
    failed multipart uploads, which DuckDB never aborts.

2. Create a warehouse with a path-style profile pointed at your store's
    endpoint. The command saves the warehouse's ID in `WID`. The `key-prefix`
    is an arbitrary path inside the bucket; `coldfront` is only an example.
    If your store does not use regions, keep `us-east-1`:

    ```bash
    WID=$(curl -s -X POST http://localhost:8181/management/v1/warehouse \
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
      }' \
      | grep -oE '"warehouse-id":"[^"]+"' | cut -d'"' -f4)
    echo "$WID"
    ```

3. In each database, store the ColdFront credential with the store's
    endpoint, without the `https://` prefix. The last argument is `true`
    because the example endpoint uses TLS:

    ```sql
    SELECT coldfront.set_storage_secret('<your-access-key-id>', '<your-secret-key>',
      'my-store.example.com:9000', 'us-east-1', 'path', true);
    ```

Then, continue with [Creating the Namespace](#creating-the-namespace).

### Configuring AWS S3

AWS S3 needs a bucket, the bucket's Region, and a long-term access key and
secret. The AWS warehouse profile uses the following flags:

- Omitting `endpoint` selects native per-Region virtual-hosted addressing over
  HTTPS.
- `path-style-access: false` selects virtual-hosted addressing, because AWS
  plans to discontinue path-style URLs.
- `flavor: "aws"` marks the store as AWS S3, which decides how Lakekeeper uses
  STS, while `s3-compat` is for other S3-compatible stores.
- `sts-enabled: false` and `remote-signing-enabled: false` make the warehouse
  use the long-term access key.

Use the following steps to configure AWS S3:

1. Grant the IAM user that owns your access key permission to read, write,
    and list the bucket (`GetObject`, `PutObject`, `DeleteObject`, and
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

    DuckDB never aborts a failed multipart upload, so also add an
    `AbortIncompleteMultipartUpload` lifecycle rule to the bucket to delete
    leftover parts.

2. Create the warehouse with those flags set. The command saves the
    warehouse's ID in `WID`. The `key-prefix` is an arbitrary path inside the
    bucket; `coldfront` is only an example:

    ```bash
    WID=$(curl -s -X POST http://localhost:8181/management/v1/warehouse \
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
      }' \
      | grep -oE '"warehouse-id":"[^"]+"' | cut -d'"' -f4)
    echo "$WID"
    ```

3. In each database, store the ColdFront credential with a `NULL` endpoint
    and your bucket's Region:

    ```sql
    SELECT coldfront.set_storage_secret('AKIAEXAMPLE...', '<your-secret-key>', NULL, 'eu-west-1');
    ```

    !!! warning "The endpoint argument must be NULL for AWS S3"

        A `NULL` endpoint selects DuckDB's native per-Region virtual-hosted
        addressing over HTTPS, with the endpoint derived from the Region in
        the fourth argument. A non-`NULL` endpoint applies `url_style` and
        `use_ssl`, which default to path-style over plain HTTP; do not use
        that form for AWS S3.

Then, continue with [Creating the Namespace](#creating-the-namespace).

#### Using Vended Credentials with AWS S3

To run ColdFront with no stored credential (see
[Using Vended Credentials](vended_credentials.md)), the warehouse issues
per-table temporary credentials from AWS Security Token Service (STS) instead
of a static key. Use the following steps in place of the steps above:

1. Create an IAM role scoped to the bucket. Lakekeeper assumes the role for
    each table and vends the resulting short-lived key, secret, and session
    token to ColdFront. The role's permission policy grants `GetObject`,
    `PutObject`, `DeleteObject`, and `ListBucket` (plus the multipart
    actions) on the bucket and `arn:aws:s3:::my-iceberg-bucket/*`. Its trust
    policy lets the warehouse credential's own IAM identity assume the role,
    gated by an `ExternalId` that Lakekeeper must present (confused-deputy
    protection):

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

2. Create the warehouse as in step 2 above, with `sts-enabled: true` and
    `assume-role-arn` in the `storage-profile`, and the matching
    `external-id` in the `storage-credential`, which stays the warehouse's
    own long-term key:

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

    The role's trust policy requires `sts:ExternalId`, so the `external-id`
    must match the `<shared-secret>` in that condition; Lakekeeper itself
    makes `external-id` mandatory only for `aws-system-identity`
    credentials.

3. In each database, enable vended credentials instead of storing a key:

    ```sql
    SELECT coldfront.set_storage_secret_vended();
    ```

Then, continue with [Creating the Namespace](#creating-the-namespace).

### Configuring Google Cloud Storage

Google Cloud Storage needs a bucket and an
[HMAC key pair](https://cloud.google.com/storage/docs/authentication/hmackeys).
Lakekeeper's native `gcs` storage profile is service-account only, so this
guide uses an `s3` storage profile pointed at GCS's S3-interoperability
endpoint, with the HMAC key pair standing in for an access key. GCS has no STS
equivalent on that endpoint, so it has no vended-credentials variant.

Use the following steps to configure Google Cloud Storage:

1. Create the warehouse. The command saves the warehouse's ID in `WID`:

    ```bash
    WID=$(curl -s -X POST http://localhost:8181/management/v1/warehouse \
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
      }' \
      | grep -oE '"warehouse-id":"[^"]+"' | cut -d'"' -f4)
    echo "$WID"
    ```

2. In each database, store the ColdFront credential the same way as for any
    other S3-compatible endpoint:

    ```sql
    SELECT coldfront.set_storage_secret('<your-hmac-access-key-id>', '<your-hmac-secret>',
      'storage.googleapis.com', 'us-east-1', 'path', true);
    ```

Then, continue with [Creating the Namespace](#creating-the-namespace).

### Configuring Azure ADLS Gen2

Azure ADLS Gen2 needs a storage account with hierarchical namespace enabled
(for example, `az storage account create --hns true`), a filesystem
(container) in that account, and the account's access key. A StorageV2
account without hierarchical namespace is not an ADLS Gen2 account, and
Lakekeeper's `adls` warehouse fails on it. The Azure cold tier is also subject
to the soft-delete and change-feed restriction in [Caveats](caveats.md).

Use the following steps to configure Azure ADLS Gen2:

1. Create an `adls` warehouse that names the storage account and the
    filesystem. The command saves the warehouse's ID in `WID`. The
    warehouse's `storage-credential` is Lakekeeper's own credential for
    reaching the account, separate from the credential ColdFront uses:

    ```bash
    WID=$(curl -s -X POST http://localhost:8181/management/v1/warehouse \
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
      }' \
      | grep -oE '"warehouse-id":"[^"]+"' | cut -d'"' -f4)
    echo "$WID"
    ```

2. In each database, store the ColdFront credential with
    `set_storage_secret_azure()`, which takes a connection string with the
    account key in `AccountKey=…`. The function writes the same
    `coldfront.storage_secret` row as `set_storage_secret()`:

    ```sql
    SELECT coldfront.set_storage_secret_azure(
        'DefaultEndpointsProtocol=https;AccountName=myaccount;AccountKey=<your-account-key>;EndpointSuffix=core.windows.net');
    ```

Then, continue with [Creating the Namespace](#creating-the-namespace).

#### Using Vended Credentials with Azure ADLS Gen2

With `sas-enabled` set on the warehouse, which is the default, Lakekeeper
vends a per-container SAS token, and the warehouse credential can be a
`shared-access-key`, `client-credentials`, or `azure-system-identity`. In
each database, enable vended credentials instead of step 2 above:

```sql
SELECT coldfront.set_storage_secret_vended('azure');
```

## Creating the Namespace

Whichever backend you configured, create the `public` namespace under the
warehouse, using the ID that the warehouse command saved in `WID`:

```bash
if [ -z "$WID" ]; then
  echo "No warehouse ID - check that the warehouse create succeeded."
else
  curl -X POST "http://localhost:8181/catalog/v1/$WID/namespaces" \
    -H "Content-Type: application/json" \
    -d '{"namespace":["public"]}'
fi
```

Decoupled mode requires the namespace: `coldfront.create_iceberg_table()`
creates the namespace and the table in one transaction, but sends the table
request before the namespace is committed, so the table create fails with
HTTP 404 if the namespace does not already exist. In tiered mode, the
archiver creates the namespace itself.

If you run the warehouse command again after the warehouse exists, the create
request fails and `WID` is empty. Set `WID` to the `warehouse-id` of the `wh`
warehouse in the output of
`curl -s http://localhost:8181/management/v1/warehouse`, then rerun the
namespace request.

## Testing with Decoupled Mode

A decoupled (Iceberg-only) table has no PostgreSQL hot tier: every row lives
in Iceberg on your object store, and you read and write it through a
PostgreSQL relation. Creating one is the quickest way to prove that the whole
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

A count of `2` is read back through Iceberg from your object store, which
confirms the round trip.

Tiered tables, ColdFront's main feature, use the same warehouse and
credential: hot partitions age out to the cold tier, and reads and writes
reach both tiers. To set them up, see
[Writing ColdFront's Configuration](configuration.md#writing-coldfronts-configuration)
and
[Managing Partitioned Tables (CLI)](using_coldfront/index.md#managing-partitioned-tables-cli).

## Verifying the Configuration

You can confirm that the objects landed in your object store with the
backend's own client:

| Backend | Example verification command |
|---|---|
| S3-compatible / AWS S3 | `aws s3 ls s3://my-iceberg-bucket/coldfront/ --recursive` |
| Google Cloud Storage | `gsutil ls -r gs://my-iceberg-bucket/coldfront/` |
| Azure ADLS Gen2 | `az storage blob list --account-name myaccount --container-name my-iceberg-fs --prefix coldfront --output table` |

For AWS S3, export your Region first:

```bash
export AWS_DEFAULT_REGION=eu-west-1
aws s3 ls s3://my-iceberg-bucket/coldfront/ --recursive
```

Iceberg stores each table under your `key-prefix` (S3-family backends) or
the filesystem root (Azure) as `coldfront/<table-uuid>/`, with a `data/`
directory for Parquet files and a `metadata/` directory for metadata JSON,
`*.avro` manifests, and snapshot files. The paths use UUIDs, not table names,
so look for `cold_demo` under a UUID path beneath your `key-prefix`. A
namespace created on a Lakekeeper release before 0.13 keeps the
`coldfront/<namespace-uuid>/<table-uuid>/` layout.

If something failed, work through the following checklist:

- Check that you ran `CREATE EXTENSION coldfront` once in your database.
  Preloading is not the same as creating the extension, and a missing extension
  produces `schema "coldfront" does not exist`.
- For S3-family backends, check that `set_storage_secret(...)` has the right
  endpoint argument for your backend: `NULL` for AWS S3, or an explicit host
  for an S3-compatible store or GCS. A wrong region sends requests to another
  Region's endpoint, which S3 rejects (with HTTP 400 for a bucket in a Region
  launched after 2019-03-20).
- For Azure, check that the connection string passed to
  `set_storage_secret_azure()` has the right `AccountName` and `AccountKey`.
- Check that the namespace `public` exists in Lakekeeper before
  `create_iceberg_table` runs. Without the namespace, the decoupled create
  fails with HTTP 404.
- Check that the key is a long-term key, not an SSO or temporary session-token
  credential (S3-family backends).
