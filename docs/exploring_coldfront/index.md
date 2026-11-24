---
cwd: ../../
---
# Exploring ColdFront

Each of the following demos starts the stack it needs and runs from start to
finish on its own page:

- [Exploring Tiered Storage](../walkthrough_tiered.md)
- [Exploring Decoupled Mode](../walkthrough_decoupled.md)
- [Exploring the Standalone Partitioner](../walkthrough_partitioner.md)
- [Exploring Distributed Mode](../walkthrough_distributed.md)

You can use the Exploring pages to take a self-contained, step-by-step tour of
ColdFront's three operating modes in a GitHub Codespace, or deploy the
walkthrough on your own system. Either way, the walkthrough runs in Docker
containers deployed with the Compose files in the ColdFront repository, and
demonstrates:

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

Both paths start the same demo stack, and the demo pages run the same commands
in either environment.

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

## Preparing a Codespace

A Codespace runs the walkthrough in your browser, with nothing to install on
your own system. Use the following steps to create the Codespace and open the
Exploring pages as runnable notebooks:

1. [Open this repo in a Codespace](https://github.com/codespaces/new?repo=pgEdge/coldfront)
   and select `Create codespace`. Docker, psql, and the
   [Runme extension](https://marketplace.visualstudio.com/items?itemName=stateful.runme)
   are preinstalled.
2. When VS Code asks whether you trust the authors of the files in the folder,
   select `Trust Folder & Continue`. Runme then opens this page as a notebook
   in which the walkthrough's commands are runnable cells; to run a cell, click
   the triangle to the left of the cell.

When the Codespace is ready, open a demo page from the Explorer. Each demo page
starts the stack in its first cells, so continue with
[Running the Demos](#running-the-demos).

## Preparing Your Own System

On your own system, the interactive guide starts the stack and runs the demos
for you, or you can run each demo page by hand. Before you start, confirm that
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

### Running the Demos by Hand

To run the demos without the guide, clone the
[ColdFront repository](https://github.com/pgEdge/ColdFront), and then follow
the section for your own system on each demo page from the repository root.
Each demo page starts the stack, so continue with
[Running the Demos](#running-the-demos).

### Changing the Demo Ports

If port 5432, 8181, or 8333 is already in use on your host, set
`COLDFRONT_PG_PORT`, `COLDFRONT_LK_PORT`, or `COLDFRONT_S3_PORT` before the
`docker compose up` command on a demo page. If you remap the PG port, match it
in the `psql` commands of the demos. If you remap the Lakekeeper port, match it
in the `curl` commands of the demos.

## Running the Demos

Each demo page starts the stack, runs the demo, and ends with a When You Finish
section. If the stack is already running from another demo, skip the start
steps on the next page. In a Codespace, open the demo page and click the
triangle beside each cell in order. On your own system, work from the
repository root, or from the `coldfront-walkthrough` directory if you used the
installer: paste each shell command into a terminal and each SQL block into a
psql session that you open with
`psql postgresql://coldfront@localhost:5432/coldfront`, or choose the demo from
the interactive guide's menu.

If you run a demo page's Lakekeeper bootstrap after the `wh` warehouse exists,
the create request fails and `WID` is empty. Set `WID` to the `warehouse-id` of
the `wh` warehouse in the output of
`curl -s http://localhost:8181/management/v1/warehouse`, then rerun the
namespace request.

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
replace the warehouse JSON in the bootstrap commands on the demo pages, the
`set_storage_secret` call in
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
