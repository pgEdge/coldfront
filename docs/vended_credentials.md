# Using Vended Credentials

Vended credentials let a deployment run with no object-store credential stored
in the database, in a DuckDB secret file, or in an archiver config; this suits
compliance environments that forbid persisting long-term keys. Lakekeeper
issues a short-lived, per-table credential (an S3 STS access key, secret, and
session token) at read and write time, and ColdFront uses it directly. The
long-term credential lives only in the Lakekeeper warehouse.

Enable vended credentials with a single call that stores no credential:

```sql
SELECT coldfront.set_storage_secret_vended();
```

This writes a `coldfront.storage_secret` row marked as vended, so nothing is
materialized as a DuckDB secret; `ensure_attached()` then attaches the catalog
with credential vending turned on. The archiver and the compactor read the
same row, so a vended deployment has no `s3:` or `azure:` stanza to import and
no credential in any file.

Vended mode targets the two clouds that issue scoped credentials: AWS S3 (STS)
and Azure ADLS Gen2 (SAS). The `set_storage_secret_vended()` call above enables
AWS S3; the same call with `'azure'` enables Azure through the identical path:

```sql
SELECT coldfront.set_storage_secret_vended('azure');
```

Vending requires a Lakekeeper warehouse configured to vend credentials:

- On AWS S3, the warehouse uses `flavor: aws` with `sts-enabled: true`, an
  `assume-role-arn` for a bucket-scoped IAM role, and an `external-id` on the
  warehouse credential that the role's trust policy also requires. The full
  warehouse and IAM-role setup is in
  [object_store.md](object_store.md#configuring-lakekeeper).
- On Azure ADLS Gen2, the warehouse is an `adls` warehouse with `sas-enabled`
  (on by default). Lakekeeper vends a per-container SAS token; the warehouse
  credential can be a `shared-access-key`, `client-credentials`, or
  `azure-system-identity`.

Google Cloud Storage over the S3-interoperability endpoint has no STS to issue
short-lived credentials, so GCS stays on static HMAC credentials.

The compactor runs fully under vended credentials: compaction, snapshot expiry,
and orphan-file reclaim all use the vended per-table credentials.

Switching a running deployment between static and vended credentials changes
the attach mode, which is fixed per PostgreSQL backend at attach time; open a
new session (or restart the archiver and compactor, which are short-lived
processes) so the new mode takes effect.
