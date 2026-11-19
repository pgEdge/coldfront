---
cwd: ../../
---
# Exploring ColdFront - Getting Started

This walkthrough is the foundation step for the mode-specific guides that
follow:

- [Exploring Tiered Storage](../walkthrough_tiered.md)
- [Exploring Decoupled Mode](../walkthrough_decoupled.md)
- [Exploring the Standalone Partitioner](../walkthrough_partitioner.md)
- [Exploring Distributed Mode](../walkthrough_distributed.md)

It is a self-contained, step-by-step tour of ColdFront's three operating
modes, using Docker containers deployed with the Compose files in the
ColdFront repository. The walkthrough demonstrates:

- tiered storage, which keeps recent data in PostgreSQL and archives older
  data to cold Iceberg.
- decoupled mode, which stores a table entirely in Iceberg from the first
  row.
- the standalone partitioner, which manages PostgreSQL partitions with no
  cold tier at all.
- a distributed demo that runs two nodes over one shared lake.

> **Beta software** - ColdFront is beta software under active development. Do
> not use it in production. Interfaces, on-disk formats, and behavior may
> change without notice, and data loss is possible.

You can run the walkthrough in a GitHub Codespace or on your own system. Each
path starts the same demo stack; the demo pages then run the same commands in
either environment.

## Understanding the Demo Stack

The walkthrough runs ColdFront and the services it depends on in Docker
containers. The stack includes the following services:

- PostgreSQL 16, 17, or 18 with the pg_duckdb and `coldfront` extensions.
- SeaweedFS, a local S3-compatible object store standing in for a real cloud
  bucket.
- Lakekeeper, the Iceberg REST catalog that tracks table metadata and file
  locations.
- Lakekeeper's own PostgreSQL database (`lakekeeper-db`), plus a one-shot
  `lakekeeper-migrate` job that applies its schema migrations and exits.

The stack runs PostgreSQL 18 by default. To run 16 or 17, set `PG_MAJOR` before
`up` and change the `pgdata` volume path in `docker-compose.yml` to match.

## Starting the Stack in a Codespace

A Codespace runs the walkthrough in your browser, with nothing to install on
your own system. Use the following steps to create the Codespace and open this
page as a runnable notebook:

1. [Open this repo in a Codespace](https://github.com/codespaces/new?repo=pgEdge/coldfront)
   and select `Create codespace`. Docker, psql, and the
   [Runme extension](https://marketplace.visualstudio.com/items?itemName=stateful.runme)
   are preinstalled.
2. When VS Code asks whether you trust the authors of the files in the folder,
   select `Trust Folder & Continue`. Runme then opens this page as a notebook
   in which the walkthrough's commands are runnable cells; to run a cell, click
   the triangle to the left of the cell.

Run the following cell to start the containers and build the archiver image.
The archiver runs on demand in the tiered and partitioner demos, so `up` does
not start it. The first run builds the Docker images, which takes two to five
minutes:

```bash
docker compose -f examples/walkthrough/docker-compose.yml \
  up -d --build
docker compose -f examples/walkthrough/docker-compose.yml \
  build archiver
```

Run the following cell to bootstrap Lakekeeper, create the `wh` warehouse
backed by SeaweedFS, and seed the `public` namespace. The cell makes one
attempt, so run it again if the warehouse request fails:

```bash
# Bootstrap Lakekeeper (one-time per fresh stack)
curl -sf -X POST http://localhost:8181/management/v1/bootstrap \
  -H 'Content-Type: application/json' \
  -d '{"accept-terms-of-use":true}'

# Create the warehouse and save its ID (retried by guide.sh until 200)
WID=$(curl -sf -X POST http://localhost:8181/management/v1/warehouse \
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
  }' \
  | grep -oE '"warehouse-id":"[^"]+"' | cut -d'"' -f4)

# Seed the public namespace
if [ -z "$WID" ]; then
  echo "No warehouse ID - check that the warehouse create succeeded."
else
  curl -sf -X POST \
    "http://localhost:8181/catalog/v1/${WID}/namespaces" \
    -H 'Content-Type: application/json' \
    -d '{"namespace":["public"]}'
fi
```

If you run the bootstrap again after the warehouse exists, the create
request fails and `WID` is empty. Set `WID` to the `warehouse-id` of the `wh`
warehouse in the output of
`curl -s http://localhost:8181/management/v1/warehouse`, then rerun the
namespace request.

When both cells finish, the stack is running; continue with
[Running the Demos](#running-the-demos).

## Starting the Stack on Your Own System

On your own system, the interactive guide starts the stack and runs the demos
for you, or you can start the stack by hand. Before you start, confirm that
your system meets the following prerequisites:

- Docker 24+ with Compose V2 (the `docker compose` plugin, not the legacy
  `docker-compose` binary).
- roughly 3 GB of free disk inside Docker's virtual disk (the images alone
  are about 2.5 GB).
- `curl`, `bash`, and `psql` reside on the host.
- `ss` on Linux or `lsof` on macOS, which the interactive guide uses to find
  free ports.

### Using the Interactive Guide

The interactive guide builds the Docker images on first run, brings up the
stack, and presents the four demos as a menu - tiered, decoupled, partitioner,
and distributed - plus options to reset the demo tables or tear the stack
down. The following command downloads the walkthrough files and launches the
guide:

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

If you already have the repository cloned, run the guide from the repository
root instead:

```bash {"ignore":"true"}
bash examples/walkthrough/guide.sh
```

The guide prints each demo command and query before it runs it. To have the
guide type each one a character at a time, as in a recording, set
`WALKTHROUGH_TYPE_DELAY` to the delay in seconds between characters (for
example, `0.03`). The default of `0` prints each command at once.

### Starting the Stack by Hand

To start the stack without the guide, clone the
[ColdFront repository](https://github.com/pgEdge/ColdFront) and run the
following commands from its root. The first command starts the containers and
builds the archiver image, which runs on demand in the tiered and partitioner
demos:

```bash {"ignore":"true"}
docker compose -f examples/walkthrough/docker-compose.yml \
  up -d --build
docker compose -f examples/walkthrough/docker-compose.yml \
  build archiver
```

If port 5432, 8181, or 8333 is already in use on your host, set
`COLDFRONT_PG_PORT`, `COLDFRONT_LK_PORT`, or `COLDFRONT_S3_PORT` before `up`.
If you remap the PG port, match it in the `psql` commands of the demos. If you
remap the Lakekeeper port, match it in the following `curl` commands and in
the demos.

The following commands bootstrap Lakekeeper, create the `wh` warehouse backed
by SeaweedFS, and seed the `public` namespace. The interactive guide retries
the warehouse request until SeaweedFS is ready; the commands make one attempt,
so run them again if the warehouse request fails:

```bash {"ignore":"true"}
# Bootstrap Lakekeeper (one-time per fresh stack)
curl -sf -X POST http://localhost:8181/management/v1/bootstrap \
  -H 'Content-Type: application/json' \
  -d '{"accept-terms-of-use":true}'

# Create the warehouse and save its ID (retried by guide.sh until 200)
WID=$(curl -sf -X POST http://localhost:8181/management/v1/warehouse \
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
  }' \
  | grep -oE '"warehouse-id":"[^"]+"' | cut -d'"' -f4)

# Seed the public namespace
if [ -z "$WID" ]; then
  echo "No warehouse ID - check that the warehouse create succeeded."
else
  curl -sf -X POST \
    "http://localhost:8181/catalog/v1/${WID}/namespaces" \
    -H 'Content-Type: application/json' \
    -d '{"namespace":["public"]}'
fi
```

If you run the bootstrap again after the warehouse exists, the create
request fails and `WID` is empty. Set `WID` to the `warehouse-id` of the `wh`
warehouse in the output of
`curl -s http://localhost:8181/management/v1/warehouse`, then rerun the
namespace request.

When the commands finish, the stack is running; continue with
[Running the Demos](#running-the-demos).

## Running the Demos

Each demo page runs the same commands in either environment. In a Codespace,
open the demo page and click the triangle beside each cell in order. On your
own system, paste each command into a terminal at the repository root, or
choose the demo from the interactive guide's menu.

The walkthrough includes the following demos:

- The [Tiered Storage Demo](../walkthrough_tiered.md) adds ColdFront to an
  existing database and moves its cold data to object storage.
- The [Decoupled Mode Demo](../walkthrough_decoupled.md) stores a table in
  Iceberg from the first row and adopts a table that another engine wrote.
- The [Partitioner Demo](../walkthrough_partitioner.md) manages PostgreSQL
  range partitions without any cold tier.
- The [Distributed Demo](../walkthrough_distributed.md) points two PostgreSQL
  nodes at one shared lake. The demo needs its own two-node stack, so its page
  is not click-runnable; run it with the interactive guide in either
  environment.

## Using a Cloud Object Store

The walkthrough uses SeaweedFS by default. To use a cloud store instead,
replace the warehouse JSON in the bootstrap commands, the `set_storage_secret`
call in
[Step 5](../walkthrough_tiered.md#pointing-coldfront-at-the-object-store) of
the tiered demo, and the `s3:` block in
`examples/walkthrough/config/archiver.yaml`, which `import` writes into the
server as the storage secret.

The following table shows the `set_storage_secret` signature for each supported
store:

| Store | set_storage_secret call |
|-------|------------------------|
| SeaweedFS (local) | `SELECT coldfront.set_storage_secret('admin', 'adminsecret', 'seaweedfs:8333');` |
| AWS S3 | `SELECT coldfront.set_storage_secret('key-id', 'secret-key', null, 'ap-south-2');` |
| GCS (HMAC) | `SELECT coldfront.set_storage_secret(p_key_id => '<hmac-key>', p_secret => '<hmac-secret>', p_endpoint => 'storage.googleapis.com', p_region => 'us-east-1', p_url_style => 'path', p_use_ssl => true);` |
| Azure ADLS Gen2 | `SELECT coldfront.set_storage_secret_azure('AccountName=<account>;AccountKey=<key>;EndpointSuffix=core.windows.net');` |

The [Configuring your Object Store](../object_store.md) guide shows the
matching Lakekeeper warehouse JSON for each of these backends.

## Tearing Down the Stack

To stop the stack and remove all data volumes, run the following command:

```bash
docker compose \
  -f examples/walkthrough/docker-compose.yml \
  down -v
```

The `-v` flag removes the named volumes: `pgdata` (PostgreSQL), `lkdata` (the
Lakekeeper catalog) and `s3data` (the object store). Omit the flag to keep the
data for a later session.

If you ran the [distributed demo](../walkthrough_distributed.md), tear down its
separate mesh stack too:

```bash
docker compose \
  -f examples/walkthrough/docker-compose.mesh.yml \
  down -v
```

In the interactive guide, the menu's R) Reset option drops the tables every
demo created, in PostgreSQL and in the Iceberg catalog, and keeps the stack
running. If the two-node cluster from the distributed demo is up, Reset first
switches back to the single-node stack.
