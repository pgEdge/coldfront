# Third-Party Notices

ColdFront bundles the third-party components below; their notices are reproduced to
satisfy their licenses. ColdFront itself is under the PostgreSQL License
([LICENSE.md](LICENSE.md)).

## MIT License

Copyright © Stichting DuckDB Foundation — **DuckDB** (2018-2025), **pg_duckdb**
(2024-2025), **duckdb-iceberg** (2018-2025), and the **avro** / **azure** /
**postgres_scanner** extensions. duckdb-iceberg is modified by ColdFront
(`docker/iceberg-bakery-aware-commit-refresh-v15.patch`).

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

## PostgreSQL License

pg_duckdb includes portions of PostgreSQL — Portions Copyright © 1996-2024
PostgreSQL Global Development Group; © 1994 The Regents of the University of
California — under the PostgreSQL License (full text in [LICENSE.md](LICENSE.md)).

## curl License

libcurl is bundled in the image (linked by DuckDB's `httpfs`; the runtime HTTP
client is httplib). It is distributed under the curl License:

> Copyright (C) Daniel Stenberg, daniel@haxx.se, and many contributors.
>
> Permission to use, copy, modify, and distribute this software for any purpose
> with or without fee is hereby granted, provided that the above copyright notice
> and this permission notice appear in all copies.
>
> THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
> IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS
> FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT OF THIRD PARTY RIGHTS. IN NO EVENT
> SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
> LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT
> OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
> SOFTWARE.
>
> Except as contained in this notice, the name of a copyright holder shall not be
> used in advertising or otherwise to promote the sale, use or other dealings in
> this Software without prior written authorization of the copyright holder.
