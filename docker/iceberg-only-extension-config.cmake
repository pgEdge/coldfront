# Minimal extension_config.cmake for the multitier patched-iceberg build.
# Upstream duckdb-iceberg's extension_config.cmake also pulls in ducklake,
# tpch, icu, and aws.  We want only iceberg (and its avro dep).  ducklake
# in particular fails to compile cleanly against this pinned DuckDB submodule.
if (NOT EMSCRIPTEN)
duckdb_extension_load(avro
    LOAD_TESTS
    GIT_URL https://github.com/duckdb/duckdb-avro
    # Upstream iceberg at commit ebe0dfaf pins avro to
    # 7b75062f6345d11c5342c09216a75c57342c2e82, which has an incomplete-type
    # bug that GCC 11 (Rocky 9 default) rejects when instantiating
    # unordered_map<string, FieldID> in field_ids.hpp.  Newer GCCs and
    # clang accept it.  Use the v1.4-andium branch head which tracks the
    # same DuckDB v1.4.x line but doesn't hit this issue.
    GIT_TAG 93da8a19b41eb577add83d0552c6946a16e97c83
)
endif()

duckdb_extension_load(iceberg
    SOURCE_DIR ${CMAKE_CURRENT_LIST_DIR}
    LOAD_TESTS
)
