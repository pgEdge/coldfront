#!/usr/bin/env bash
# common.sh - ColdFront DuckDB extensions (iceberg, avro, azure, postgres_scanner).
#
# PG-INDEPENDENT, arch+distro-keyed. Built from the patched duckdb-iceberg tree
# against DuckDB ${DUCKDB_VERSION} and placed under
#   ${COLDFRONT_EXTDIR}/v${DUCKDB_VERSION}/linux_<arch>/
# pg_duckdb's DuckDB engine locates extensions under v<engine_version>/<platform>/,
# so that path segment MUST be the clean engine version (see below).

# --- DuckDB ENGINE version: the SINGLE source of truth --------------------------
# Drives the install-path segment, OVERRIDE_GIT_DESCRIBE, and the duckdb clone
# tag. It is ALWAYS the clean engine version (e.g. 1.5.4) — never decorated with a
# pre-release pretag, because DuckDB looks up extensions under v<engine_version>/,
# which is fixed regardless of the ColdFront release's rc/beta status. Keep in
# lockstep with pg_duckdb's bundled DuckDB. Overridable via COMPONENT_VERSION.
export DUCKDB_VERSION="${COMPONENT_VERSION:-1.5.4}"

# --- Package version --------------------------------------------------------------
# The rpm/deb package Version. Starts equal to the engine version; on DEB a
# pre-release pretag is folded in with '~' for correct apt ordering (below). The
# package version may become 1.5.4~rc1, but DUCKDB_VERSION stays 1.5.4.
export DUCKDB_EXT_VERSION="$DUCKDB_VERSION"
export DUCKDB_EXT_BUILDNUM="${COMPONENT_BUILDNUM:-1}"

# --- Build pins -------------------------------------------------------------------
# duckdb-iceberg: the 4 patches target ICEBERG_REF (branch fetched first so the
# ref resolves). avro/azure/postgres_scanner refs live in the extension_config
# cmake (packaging copies docker/iceberg-azure-extension-config-v15.cmake).
export ICEBERG_REPO="https://github.com/duckdb/duckdb-iceberg"
export ICEBERG_BRANCH="${ICEBERG_BRANCH:-v1.5-variegata}"
export ICEBERG_REF="${ICEBERG_REF:-0fad545a}"
export DUCKDB_REPO="https://github.com/duckdb/duckdb"
export VCPKG_REPO="https://github.com/microsoft/vcpkg"

# --- Install location (PG-independent) --------------------------------------------
# DuckDB appends v<engine>/linux_<arch>/. Point duckdb.extension_directory at this
# in postgresql.conf (see the shipped config sample).
export COLDFRONT_EXTDIR="${COLDFRONT_EXTDIR:-/usr/lib/pgedge/coldfront/duckdb-extensions}"

# DEB only: fold a pre-release pretag (BUILDNUM='rc1_1') into the PACKAGE version
# with '~' (1.5.4~rc1, BUILDNUM=1) so '~' sorts pre-releases below stable in
# dpkg/reprepro. DUCKDB_VERSION (path/build) stays clean. RPM keeps the pretag in
# Release (rpmvercmp sorts rc1_1 below 1).
if command -v apt-get &>/dev/null; then
    if [[ "$DUCKDB_EXT_BUILDNUM" == *_* ]]; then
        DUCKDB_EXT_PRETAG="${DUCKDB_EXT_BUILDNUM%%_*}"
        export DUCKDB_EXT_VERSION="${DUCKDB_VERSION}~${DUCKDB_EXT_PRETAG}"
        DUCKDB_EXT_BUILDNUM="${DUCKDB_EXT_BUILDNUM#*_}"
    fi
fi

export REPO_TYPE="${REPO_TYPE:-daily}"
