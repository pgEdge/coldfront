#!/usr/bin/env bash
# common.sh - Common environment variables for the ColdFront pg_duckdb package.

# Build once per PostgreSQL major version (fan-out across the matrix).
PER_PG_VERSION=true

# Default PostgreSQL version and derived values
export PG_VERSION="${PG_VERSION:-17.7}"
export PG_MAJOR_VERSION="$(echo "$PG_VERSION" | cut -d. -f1)"

# pg_duckdb pinned to the merged PR #1025 commit (DuckDB 1.5.4). No released
# pg_duckdb tag carries 1.5.x; this commit pins its duckdb submodule to v1.5.4.
# COMPONENT_BRANCH/COMPONENT_VERSION may override for a rebuild.
export PG_DUCKDB_REPO="https://github.com/duckdb/pg_duckdb"
export PG_DUCKDB_COMMIT="${COMPONENT_BRANCH:-c04e6a2dcf4e999abb921da1ba2f8335dad644e0}"
export PG_DUCKDB_VERSION="${COMPONENT_VERSION:-1.5.4}"
export PG_DUCKDB_BUILDNUM="${COMPONENT_BUILDNUM:-1}"

# libcurl built from source and BUNDLED in the package. DuckDB 1.5.4 httpfs links
# CURLSSLOPT_AUTO_CLIENT_CERT (curl >= 7.77); el9 ships 7.76 and debian bullseye
# 7.74, so the system curl can't resolve pg_duckdb.so's symbols at load. 8.12.0
# also fixes CVE-2025-0665. Installed into the PG libdir with a $ORIGIN RUNPATH
# on pg_duckdb.so so it finds the co-located copy without touching the OS libcurl.
export CURL_VERSION="${CURL_VERSION:-8.12.0}"

# DEB only: move a pre-release pretag (e.g. BUILDNUM='rc1_1') into the upstream
# VERSION with a leading '~' (1.5.4~rc1, BUILDNUM=1) so '~' sorts pre-releases
# BELOW stable in dpkg/reprepro. Gated on apt-get so RPM keeps the pretag in
# Release (rpmvercmp already sorts rc1_1 below 1). The source pin is the commit,
# not the version, so this never affects what is built.
if command -v apt-get &>/dev/null; then
    if [[ "$PG_DUCKDB_BUILDNUM" == *_* ]]; then
        PG_DUCKDB_PRETAG="${PG_DUCKDB_BUILDNUM%%_*}"
        export PG_DUCKDB_VERSION="${PG_DUCKDB_VERSION}~${PG_DUCKDB_PRETAG}"
        PG_DUCKDB_BUILDNUM="${PG_DUCKDB_BUILDNUM#*_}"
    fi
fi

export REPO_TYPE="${REPO_TYPE:-daily}"
