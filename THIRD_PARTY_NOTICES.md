# Third-Party Notices

ColdFront builds on and redistributes third-party components. Their copyright and
license notices are reproduced here to comply with their terms. These notices apply
to those components, **not** to ColdFront as a whole — ColdFront itself is under the
PostgreSQL License (see [LICENSE.md](LICENSE.md)).

The ColdFront DuckDB 1.5.x base image (`docker/Dockerfile.duckdb15-base`) compiles
and ships binaries of the DuckDB-family components below; this file is also copied
into the published image.

---

## DuckDB family — MIT License

The following are licensed under the **MIT License**:

- **DuckDB** — https://github.com/duckdb/duckdb — Copyright 2018-2025 Stichting DuckDB Foundation
- **pg_duckdb** (DuckDB 1.5.3, PR #1025) — https://github.com/duckdb/pg_duckdb — Copyright 2024-2025 Stichting DuckDB Foundation
- **duckdb-iceberg** (`v1.5-variegata`, **modified** — see below) — https://github.com/duckdb/duckdb-iceberg — Copyright 2018-2025 Stichting DuckDB Foundation
- the DuckDB extensions **avro**, **azure**, and **postgres_scanner** built from the DuckDB / duckdb-iceberg trees

MIT License text:

> Permission is hereby granted, free of charge, to any person obtaining a copy of
> this software and associated documentation files (the "Software"), to deal in the
> Software without restriction, including without limitation the rights to use,
> copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the
> Software, and to permit persons to whom the Software is furnished to do so,
> subject to the following conditions:
>
> The above copyright notice and this permission notice shall be included in all
> copies or substantial portions of the Software.
>
> THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
> IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS
> FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
> COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN
> AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION
> WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

### Modification notice — duckdb-iceberg

ColdFront applies `docker/iceberg-bakery-aware-commit-refresh-v15.patch` to
**duckdb-iceberg** — the *bakery-aware commit-refresh* patch (it re-stamps
`parent_snapshot_id` at the Iceberg commit POST so concurrent cold-tier writers do
not 409). The MIT License permits modification and redistribution provided the
copyright and permission notice above are retained, which they are. The modified
extension binaries are redistributed in the ColdFront base image.

---

## PostgreSQL portions (within pg_duckdb)

pg_duckdb includes portions of PostgreSQL, distributed under the **PostgreSQL
License**:

> Portions Copyright (c) 1996-2024, PostgreSQL Global Development Group
> Portions Copyright (c) 1994, The Regents of the University of California
>
> Permission to use, copy, modify, and distribute this software and its
> documentation for any purpose, without fee, and without a written agreement is
> hereby granted, provided that the above copyright notice and this paragraph and
> the following two paragraphs appear in all copies. [Full text: the PostgreSQL
> License.]

---

## Other build / runtime dependencies

- **libcurl** — https://curl.se — curl license (MIT/X-style). Built from source
  (8.11.x) in the base image for DuckDB 1.5.3 httpfs.
- **vcpkg** — https://github.com/microsoft/vcpkg — MIT (build-time only; not
  redistributed).
- DuckDB's vendored third-party libraries (re2, zstd, utf8proc, fast_float,
  libpg_query, …) are redistributed under their respective licenses as shipped in
  the DuckDB source tree.

Each component's authoritative license text is included with its sources in the
upstream DuckDB / duckdb-iceberg / pg_duckdb repositories.
