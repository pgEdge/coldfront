# extension_config.cmake for the DuckDB 1.5.x ColdFront build (Azure ADLS cold
# tier). Builds iceberg + avro + azure against one DuckDB (iceberg's
# v1.5-variegata submodule) so all three .duckdb_extension files share one ABI
# and load together in pg_duckdb 1.5.4.
#
# This config only selects which extensions to build; docker/Dockerfile.duckdb15-base
# applies ColdFront's duckdb-iceberg patches before the build.
if (NOT EMSCRIPTEN)
duckdb_extension_load(avro
    GIT_URL https://github.com/duckdb/duckdb-avro
    # the avro pin used by iceberg v1.5-variegata; builds clean under gcc-toolset-14.
    GIT_TAG 7f423d69709045e38f8431b3470e0395fce1a595)
duckdb_extension_load(azure
    GIT_URL https://github.com/duckdb/duckdb-azure
    # v1.5-variegata, the ABI-matched sibling of iceberg's branch. Not main:
    # azure main tracks duckdb main and collides at link ("multiple definition
    # of duckdb::FileFlags::FILE_FLAGS_NULL_IF_NOT_EXISTS"). This commit includes
    # ADLSv2 abfss:// write support (>= 391df596).
    GIT_TAG 563589b2f24290a4dcdd4247eaedf2b544f9dbcd)
duckdb_extension_load(postgres_scanner
    DONT_LINK
    GIT_URL https://github.com/duckdb/duckdb-postgres
    # The 'postgres' extension (pglocal write path: DuckDB reads PG tables to
    # stream into Iceberg). Built here so it is shipped in the image and never
    # downloaded at runtime: extensions.duckdb.org has no reliably-cached v1.5.4
    # build, and install_extension would block on the network. Pinned to the
    # v1.5-variegata commit at which a numeric NaN reads as NULL instead of 0
    # (ci/journey.sh TC-234), built against DuckDB v1.5.4.
    GIT_TAG 4053b617c863dfb435c9be9dacf1ec0e3dacde80
    SUBMODULES database-connector)
endif()

duckdb_extension_load(iceberg
    SOURCE_DIR ${CMAKE_CURRENT_LIST_DIR})
