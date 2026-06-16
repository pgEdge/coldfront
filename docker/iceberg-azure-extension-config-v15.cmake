# extension_config.cmake for the DuckDB 1.5.x ColdFront build (Azure ADLS cold
# tier). Builds iceberg + avro + azure against ONE DuckDB (iceberg's
# v1.5-variegata submodule) so all three .duckdb_extension files share one ABI
# and load together in pg_duckdb 1.5.3. See DUCKDB_1.5_PATCHED.md for the why.
#
# This config only SELECTS which extensions to build; the bakery-aware-commit-
# refresh patch is applied separately by docker/Dockerfile.duckdb15-base
# (iceberg-bakery-aware-commit-refresh-v15.patch).
if (NOT EMSCRIPTEN)
duckdb_extension_load(avro
    GIT_URL https://github.com/duckdb/duckdb-avro
    # the avro pin used by iceberg v1.5-variegata; builds clean under gcc-toolset-14.
    GIT_TAG 7f423d69709045e38f8431b3470e0395fce1a595)
duckdb_extension_load(azure
    GIT_URL https://github.com/duckdb/duckdb-azure
    # v1.5-variegata — the ABI-matched sibling of iceberg's branch. NOT main:
    # azure main tracks duckdb main and collides at link ("multiple definition
    # of duckdb::FileFlags::FILE_FLAGS_NULL_IF_NOT_EXISTS"). This commit carries
    # ADLSv2 abfss:// write support (>= 391df596).
    GIT_TAG 563589b2f24290a4dcdd4247eaedf2b544f9dbcd)
duckdb_extension_load(postgres_scanner
    DONT_LINK
    GIT_URL https://github.com/duckdb/duckdb-postgres
    # The 'postgres' extension (pglocal write path: DuckDB reads PG tables to
    # stream into Iceberg). Built here so it is SHIPPED in the image and never
    # downloaded at runtime — extensions.duckdb.org has no reliably-cached v1.5.3
    # build, and install_extension would block on the network. This is the EXACT
    # commit + submodule DuckDB 14eca11b pins for postgres_scanner
    # (duckdb/.github/config/extensions/postgres_scanner.cmake) — guaranteed
    # API+ABI-compatible. NOT main (main needs a newer database-connector that
    # breaks against this DuckDB: "dbconnector/pool.hpp: No such file").
    GIT_TAG 6b2b12cad3afef61e8a4637e714e8a88895fed1a
    SUBMODULES database-connector)
endif()

duckdb_extension_load(iceberg
    SOURCE_DIR ${CMAKE_CURRENT_LIST_DIR})
