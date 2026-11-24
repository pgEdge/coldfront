---
cwd: ../../
---
# Exploring ColdFront

Each of the following walkthroughs contains the steps to deploy the stack,
demonstrate the benefits of each deployment architecture, and clean up the
environment afterwards:

- [Exploring Tiered Storage](../walkthrough_tiered.md) demonstrates keeping
  recent data in PostgreSQL and archiving older data to cold Iceberg.
- [Exploring Decoupled Mode](../walkthrough_decoupled.md) demonstrates storing
  a table entirely in Iceberg from the first row.
- [Exploring the Standalone Partitioner](../walkthrough_partitioner.md)
  demonstrates managing PostgreSQL partitions with no cold tier at all.
- [Exploring Distributed Mode](../walkthrough_distributed.md) demonstrates
  running two PostgreSQL nodes over one shared lake.

You can use the Exploring pages to take a self-contained, step-by-step tour of
ColdFront's three operating modes in a GitHub Codespace, or deploy the
walkthrough on your own system. Either way, the walkthrough runs in Docker
containers deployed with the Compose files in the ColdFront repository.

> **Beta software** - ColdFront is beta software under active development. Do
> not use it in production. Interfaces, on-disk formats, and behavior may
> change without notice, and data loss is possible.

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

The walkthroughs are designed to be performed manually on your own system, or
in a Codespace. If you would like to perform the walkthrough manually on your
own system, confirm that your system meets the following prerequisites, and
then continue with
[Downloading the Walkthrough Files](#downloading-the-walkthrough-files):

- Docker 24+ with Compose V2 (the `docker compose` plugin, not the legacy
  `docker-compose` binary).
- roughly 3 GB of free disk inside Docker's virtual disk (the images alone
  are about 2.5 GB).
- `curl`, `bash`, and `psql` reside on the host.
- `ss` on Linux or `lsof` on macOS, which the interactive guide uses to find
  free ports.

### Using the Interactive Guide

The interactive guide runs each walkthrough for you on your own system. A
Codespace does not need the installer or this section: the demo pages run as
notebooks, and the distributed demo's page shows how to start the guide in the
Codespace. To start the guide, run the following command from the repository
root or the `coldfront-walkthrough` directory:

```bash {"ignore":"true"}
bash examples/walkthrough/guide.sh
```

The guide builds the Docker images on first run, brings up the stack, and
presents the four demos as a menu - tiered, decoupled, partitioner, and
distributed - plus options to reset the demo tables or tear the stack down. In
the guide's menu, the R) Reset option drops the tables every demo created, in
PostgreSQL and in the Iceberg catalog, and keeps the stack running. If the
two-node cluster from the distributed demo is up, Reset first switches back to
the single-node stack.

The guide prints each demo command and query before it runs it. To have the
guide type each one a character at a time, as in a recording, set
`WALKTHROUGH_TYPE_DELAY` to the delay in seconds between characters (for
example, `0.03`). The default of `0` prints each command at once.

### Downloading the Walkthrough Files

Clone the [ColdFront repository](https://github.com/pgEdge/ColdFront), or use
the walkthrough installer (`examples/walkthrough/install.sh`) to download only
the walkthrough files. The following command downloads the installer from
GitHub and runs it; the installer writes the files to a
`coldfront-walkthrough` directory under the current directory and then starts
the interactive guide. Quit the guide if you want to follow the demo pages
yourself:

```bash {"ignore":"true"}
curl -fsSL \
  https://raw.githubusercontent.com/pgEdge/ColdFront/main/examples/walkthrough/install.sh \
  | bash
```

The installer downloads the walkthrough files from the `main` branch. The
[walkthrough README](https://github.com/pgEdge/ColdFront/blob/main/examples/walkthrough/README.md)
describes the installer's options, such as choosing another directory or
branch.

Run every demo command from the repository root, or from the
`coldfront-walkthrough` directory if you used the installer, and then continue
with [Running the Demos](#running-the-demos).

### Changing the Demo Ports

If port 5432, 8181, or 8333 is already in use on your host, set
`COLDFRONT_PG_PORT`, `COLDFRONT_LK_PORT`, or `COLDFRONT_S3_PORT` before the
`docker compose up` command on a demo page. If you remap the PG port, match it
in the `psql` commands of the demos. If you remap the Lakekeeper port, match it
in the `curl` commands of the demos.

## Running the Demos

Open any demo page and follow the section for your environment. Each page
starts the stack, runs the demo, and ends with a When You Finish section, so
you can run the demos in any order. If the stack is already running from
another demo, each page explains which start steps to skip.

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
