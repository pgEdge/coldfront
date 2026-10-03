---
cwd: ../
---
# ColdFront Guided Walkthrough

If you are new to ColdFront, run the guided walkthrough.

The walkthrough is a self-contained, step-by-step tour of ColdFront's three
operating modes - tiered storage (hot PostgreSQL + cold Iceberg), decoupled
mode (Iceberg-only from the first row), and the standalone partitioner - plus a
distributed demo that runs two nodes over one shared lake. Every command on
this page is real: click it to run in Codespaces, or copy it into a local
shell.

> **Beta software** - ColdFront is beta software under active development. Do
> not use it in production. Interfaces, on-disk formats, and behavior may
> change without notice, and data loss is possible.

## ▶ In GitHub Codespaces

[Open this repo in a Codespace](https://github.com/codespaces/new?repo=pgEdge/coldfront)
and everything is preinstalled - Docker, psql, and the
[Runme extension](https://marketplace.visualstudio.com/items?itemName=stateful.runme)
that turns each code block below into a runnable cell. Click **Run** on each
cell as you read. The first cell builds the Docker images (two to five
minutes); everything after it is quick.

If you prefer a terminal, `bash examples/walkthrough/guide.sh` runs the same
demos as an interactive guide.

## 💻 On Your Own Machine

You need Docker 24+ with Compose V2 (the `docker compose` plugin, not the
legacy `docker-compose` binary), roughly 3 GB of free disk inside Docker's
virtual disk (the images alone are about 2.5 GB), and `curl`, `bash`, and
`psql` on the host. The interactive guide also needs `ss` on Linux or `lsof` on
macOS, which it uses to find free ports.

The fastest path is the one-liner, which downloads the walkthrough files and
launches the interactive guide:

```bash {"ignore":"true"}
curl -fsSL \
  https://raw.githubusercontent.com/pgEdge/ColdFront/main/examples/walkthrough/install.sh \
  | bash
```

The installer writes the files to a `coldfront-walkthrough` directory under the
current directory, and downloads them from the `main` branch. Set
`WALKTHROUGH_DIR` to choose another directory, or `WALKTHROUGH_BRANCH` to
download the files and build sources from another branch. Both variables must
reach `bash`, so set them after the pipe, as in
`| WALKTHROUGH_DIR=cf-demo bash`.

If you already have the repository cloned, run the guide directly:

```bash {"ignore":"true"}
bash examples/walkthrough/guide.sh
```

Either way, the guide builds the Docker images on first run, brings up the
stack, and walks through each demo interactively. This page and the
[demos](walkthrough_demos.md) cover the same steps - run them from the doc or
paste them into your shell.

The guide prints each demo command and query before it runs it. To have the
guide type each one a character at a time, as in a recording, set
`WALKTHROUGH_TYPE_DELAY` to the delay in seconds between characters (for
example, `0.03`). The default of `0` prints each command at once.

## What Setup Does

Setup runs before the demos begin. Setup starts the containers, waits for
PostgreSQL and Lakekeeper to accept connections, and creates the Lakekeeper
warehouse and namespace. The stack includes the following services:

- PostgreSQL 16, 17, or 18 with the pg_duckdb and coldfront extensions.
- SeaweedFS, a local S3-compatible object store standing in for a real cloud
  bucket.
- Lakekeeper, the Iceberg REST catalog that tracks table metadata and file
  locations.
- Lakekeeper's own PostgreSQL database (`lakekeeper-db`), plus a one-shot
  `lakekeeper-migrate` job that applies its schema migrations and exits.

The stack runs PostgreSQL 18 by default. To run 16 or 17, set `PG_MAJOR` before
`up` and change the `pgdata` volume path in `docker-compose.yml` to match.

Start the containers, then build the archiver image. That service is not part
of `up`: it runs on demand in Step 7 and Demo 3, so `up --build` leaves it
alone:

```bash
docker compose -f examples/walkthrough/docker-compose.yml \
  up -d --build
docker compose -f examples/walkthrough/docker-compose.yml \
  build archiver
```

If port 5432, 8181, or 8333 is already in use on your host, set
`COLDFRONT_PG_PORT`, `COLDFRONT_LK_PORT`, or `COLDFRONT_S3_PORT` before `up`.
If you remap the PG port, match it in the `psql` commands of the
[demos](walkthrough_demos.md). If you remap the Lakekeeper port, match it in
the `curl` commands on this page and in the demos.

Bootstrap Lakekeeper, create the `wh` warehouse backed by SeaweedFS, and seed
the `public` namespace. The interactive guide retries the warehouse POST until
SeaweedFS is ready. This cell makes one attempt, so run it again if the
warehouse POST fails:

```bash
# Bootstrap Lakekeeper (one-time per fresh stack)
curl -sf -X POST http://localhost:8181/management/v1/bootstrap \
  -H 'Content-Type: application/json' \
  -d '{"accept-terms-of-use":true}'

# Create the warehouse (retried by guide.sh until 200)
curl -sf -X POST http://localhost:8181/management/v1/warehouse \
  -H 'Content-Type: application/json' \
  -d '{
    "warehouse-name": "wh",
    "storage-profile": {
      "type": "s3",
      "bucket": "iceberg",
      "region": "us-east-1",
      "endpoint": "http://seaweedfs:8333",
      "path-style-access": true,
      "flavor": "s3-compat",
      "sts-enabled": false,
      "remote-signing-enabled": false
    },
    "storage-credential": {
      "type": "s3",
      "credential-type": "access-key",
      "aws-access-key-id": "admin",
      "aws-secret-access-key": "adminsecret"
    }
  }'

# Seed the public namespace
WID=$(curl -s http://localhost:8181/management/v1/warehouse \
  | grep -oE '"warehouse-id":"[^"]+"' \
  | head -1 | cut -d'"' -f4)
curl -sf -X POST \
  "http://localhost:8181/catalog/v1/${WID}/namespaces" \
  -H 'Content-Type: application/json' \
  -d '{"namespace":["public"]}'
```

### Using a Cloud Object Store

The walkthrough hero path uses SeaweedFS. To use a cloud store instead, replace
the warehouse JSON above, the `set_storage_secret` call in Step 5 of
[Demo 1](walkthrough_demos.md#demo-1-tiered-storage), and the `s3:` block in
`examples/walkthrough/config/archiver.yaml`, which the archiver uses for its
own connection to the store.

The following table shows the `set_storage_secret` signature for each supported
store:

| Store | set_storage_secret call |
|-------|------------------------|
| SeaweedFS (local) | `SELECT coldfront.set_storage_secret('admin', 'adminsecret', 'seaweedfs:8333');` |
| AWS S3 | `SELECT coldfront.set_storage_secret('key-id', 'secret-key', null, 'ap-south-2');` |
| GCS (HMAC) | `SELECT coldfront.set_storage_secret(p_key_id => '<hmac-key>', p_secret => '<hmac-secret>', p_endpoint => 'storage.googleapis.com', p_region => 'us-east-1', p_url_style => 'path', p_use_ssl => true);` |
| Azure ADLS Gen2 | `SELECT coldfront.set_storage_secret_azure('AccountName=<account>;AccountKey=<key>;EndpointSuffix=core.windows.net');` |

The [Object Store Setup](object_store.md) guide shows the matching warehouse
JSON for AWS S3; for GCS and Azure, see
[usage.md → Storage Backends](usage.md#storage-backends).

## Next Steps

With the stack running, continue with the following guides:

- The [Walkthrough Demos](walkthrough_demos.md) guide provides the tiered,
  decoupled, partitioner, and distributed demos.
- The [Object Store Setup](object_store.md) guide takes you from an empty
  bucket to a working cold tier.
