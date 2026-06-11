# pgEdge ColdFront — 10,000-foot view

## The problem, in business terms

Every busy PostgreSQL database keeps growing. Within a year or two, most of
the data is old and rarely touched — but you pay for all of it, every day:
storage bills, longer backups, slower recovery, bigger and pricier
replicas. Cost and operational risk scale with how much data you've
*accumulated*, not with the small slice your application actually uses.

The usual answers are all bad: keep paying; delete the history and lose it;
or move it to a separate system with different tools that breaks the
queries your teams already rely on.

## What ColdFront does

ColdFront keeps your recent, active data in PostgreSQL — fast, exactly as
today — and automatically moves the older data to low-cost cloud object
storage (Amazon S3, Google Cloud Storage, or Azure) in an **open file
format**. Applications keep querying one table, the same way, with no code
changes. The full history stays available; the storage bill for the cold
part drops by roughly 90%.

No application rewrite, no separate analytics system, no proprietary
lock-in — and it runs on the standard PostgreSQL your teams already use.

## Who it's for

ColdFront fits any system where a large, ever-growing PostgreSQL table has
a busy recent edge and a long tail that's queried only occasionally:

- **Observability & monitoring platforms.** A product monitoring thousands
  of database or server instances generates billions of metric and event
  rows. The last few weeks drive every dashboard and alert; years of history
  must stay queryable for trends, capacity planning, and SLAs. ColdFront
  keeps the recent window fast and the rest on cheap storage — one query
  surface, a fraction of the cost.
- **Financial & regulated industries.** 7–10+ year retention mandates where
  data must stay *queryable*, not just archived — held in an open,
  vendor-neutral format with no lock-in for the life of the obligation.
- **IoT, telemetry & ad-tech.** Millions of events or sensor readings a day:
  recent data powers alerting, history feeds reporting and models, and the
  table stops growing without bound — nothing is lost.
- **AI & analytics.** The full data history, queryable at analytical speed
  for training, retrieval, and feature engineering, without copying it into
  a separate warehouse or data lake.
- **Global, multi-region SaaS.** Recent data replicates between regions; the
  deep history lives once in shared cloud storage — readable from anywhere,
  written safely from any region.

## Why it's different

- **Open, never locked in.** Cold data is stored in Apache Iceberg — the
  industry-standard open format read by every major analytics tool. Stop
  using ColdFront tomorrow and your data is still yours and still readable;
  nothing proprietary at any layer.
- **Standard PostgreSQL.** No proprietary fork, no special distribution, no
  forced cluster — the database your teams already run, with existing
  backups, monitoring, and operations unchanged. Adoption doesn't mean
  re-platforming.
- **No application changes.** Same table, same queries, same code; the
  tiering is invisible to the application.
- **Archived data stays editable.** Unlike most tiering products, old data
  can still be corrected or deleted through the normal interface — important
  for right-to-delete and data corrections. A strict read-only mode is
  available when you want it.
- **Scales with you.** Start on a single server; grow to a multi-region,
  multi-writer deployment when you need it — with no change to the data
  model or the application.

## The business case

- **~90% lower storage cost** on the cold tier — commodity object storage
  instead of premium database storage.
- **Smaller, faster, cheaper operations** — quicker backups and restores,
  lighter replicas, shorter maintenance windows.
- **No vendor lock-in** — open database, open format, your choice of cloud
  storage. Walk away any time with your data intact.
- **Compliance-friendly** — years of queryable history in an open format at
  archive prices.
- **AI-ready** — your complete history is accessible to whatever AI and
  analytics stack you choose.

## How it compares (at a glance)

The closest alternatives — EDB, Databricks, Snowflake — each require *their*
platform: a proprietary database, a managed service, or a minimum
multi-node cluster, and most make archived data read-only. ColdFront runs on
standard open-source PostgreSQL, keeps the cold tier writable and in an open
format on storage you control, and works on a single server. You own your
infrastructure, your data format, and your vendor choices at every tier.

## Where it fits — and where it doesn't

A fit when a PostgreSQL table grows continuously, a recent window carries
the load, and the long tail is queried occasionally — and you want the
archive to stay open and queryable, with no lock-in.

Less of a fit when *all* the data is hot and latency-critical (keep it in
PostgreSQL), or the data has no natural time dimension to age on.

## Availability

ColdFront is open source and runs on community PostgreSQL. It ships as part
of **pgEdge Enterprise Postgres** with pre-built binaries, the multi-region
distributed option, and enterprise support.
