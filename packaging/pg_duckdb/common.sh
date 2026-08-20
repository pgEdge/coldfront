#!/usr/bin/env bash
# common.sh - Common environment variables for the ColdFront pg_duckdb package.
#
# NOTE (disk): this package compiles all of DuckDB + extensions with LTO and is
# the heaviest build here — it can exhaust a hosted runner's disk. The release
# workflow frees ~25-30GB before pg_duckdb cells; if that ever still hits "No
# space left on device", the next lever is to move Docker's storage to the
# runner's /mnt (~70GB) disk. See the "Free up disk space" step in
# .github/workflows/release.yml for the ready-to-use snippet.

# Build once per PostgreSQL major version (fan-out across the matrix).
PER_PG_VERSION=true

# Default PostgreSQL version and derived values
export PG_VERSION="${PG_VERSION:-17.7}"
export PG_MAJOR_VERSION="$(echo "$PG_VERSION" | cut -d. -f1)"

# pg_duckdb pinned to the merged PR #1025 commit (DuckDB 1.5.4). No released
# pg_duckdb tag carries 1.5.x; this commit pins its duckdb submodule to v1.5.4.
# This is an UPSTREAM pin, independent of the ColdFront release tag — do NOT
# derive it from COMPONENT_BRANCH (the builder-action always sets that to the
# ColdFront tag, which is not a pg_duckdb ref). Override only via PG_DUCKDB_COMMIT.
export PG_DUCKDB_REPO="https://github.com/duckdb/pg_duckdb"
export PG_DUCKDB_COMMIT="${PG_DUCKDB_COMMIT:-c04e6a2dcf4e999abb921da1ba2f8335dad644e0}"
export PG_DUCKDB_VERSION="${COMPONENT_VERSION:-1.5.4}"
export PG_DUCKDB_BUILDNUM="${COMPONENT_BUILDNUM:-1}"

# libcurl built from source at BUILD TIME ONLY on the two distros whose system
# curl is too old to COMPILE against — el9 (7.76) and debian bullseye (7.74) —
# because DuckDB 1.5.4's httpfs uses CURLSSLOPT_AUTO_CLIENT_CERT (curl >= 7.77).
# 8.12.0 also fixes CVE-2025-0665. It is NOT shipped and NOT rpath'd: the built
# .so references only the libcurl.so.4 soname plus symbols the older system curl
# already provides, so at runtime the native system libcurl resolves it. Every
# other distro compiles against its own system libcurl and ignores this.
export CURL_VERSION="${CURL_VERSION:-8.12.0}"

# --- Shared DuckDB engine package ----------------------------------------------
# libduckdb.so is DuckDB itself, built from pg_duckdb's third_party/duckdb
# submodule. Nothing in it is PostgreSQL-specific — its DT_NEEDED set is only
# curl/ssl/crypto/stdc++/m/gcc_s/c — so every per-major build produces the same
# engine (verified: .text and .rodata are bit-identical across PG 16/17/18).
#
# Shipping that identical library from all three per-major packages made them
# mutually UNINSTALLABLE: identical binary -> identical build-id -> each package
# claimed the same /usr/lib/.build-id/<xx>/<hash>, but as a symlink pointing at
# its OWN PG libdir. rpm's transaction test and dpkg both reject that, so
# installing pg16+pg17+pg18 side by side failed. It only appeared to work on
# distros where an accidental per-major RUNPATH perturbed the binary enough to
# change its build-id.
#
# The engine now ships ONCE as `pgedge-libduckdb`, into a pgEdge-private
# directory (not the system libdir — the soname is unversioned, so a public
# install would squat a name any future distro duckdb package would want).
# pg_duckdb.so reaches it through an RPATH added at build time, so the per-major
# packages carry nothing but the extension itself.
#
# PER_PG_VERSION=true gives each major its own rpmbuild/dpkg-buildpackage run,
# so exactly ONE run may emit the shared package. If more than one did, the
# release would push N same-version artifacts built from N different runs:
# reprepro rejects the second outright ("already registered with different
# checksum") and the dnf side would silently replace the file, leaving clients
# with repo metadata pointing at a checksum that no longer matches.
#
# That one run is the LATEST major — it is the major that stays in the matrix
# as older ones age out, so the owner moves forward on its own. The list comes
# from release.yml's detect step for this component, read straight out of the
# workflow so the two can never drift (the duckdb-extensions component reads
# ICEBERG_REF from the Dockerfile the same way). $GITHUB_WORKSPACE is mounted
# into the build container, so the workflow is readable from inside the build.
CWD="${CWD:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
libduckdb_pg_majors="$(awk '
    /component_name: packaging\/pg_duckdb[[:space:]]*$/ { found = 1 }
    found && /pg_versions:/ { gsub(/[^0-9,]/, ""); print; exit }
' "${CWD}/.github/workflows/release.yml" 2>/dev/null)"

# Highest major in that list. Falls back to 18 when the list is unreadable — a
# build outside a repo checkout, or a workflow edit that moves the detect step
# beyond awk's reach. A wrong owner is self-announcing rather than silent:
# pgedge-libduckdb either goes missing (the promote install test fails on an
# unsatisfied dependency) or gets built twice (the apt push fails).
# LIBDUCKDB_OWNER_PG_MAJOR is the single override knob.
export LIBDUCKDB_OWNER_PG_MAJOR="${LIBDUCKDB_OWNER_PG_MAJOR:-$(
    printf '%s' "${libduckdb_pg_majors:-18}" | tr ',' '\n' | grep -E '^[0-9]+$' | sort -n | tail -1
)}"
: "${LIBDUCKDB_OWNER_PG_MAJOR:=18}"
unset libduckdb_pg_majors

# Where the shared engine installs, and what pg_duckdb.so gets an RPATH to.
# Its own subdirectory alongside the duckdb extensions, under the same
# /usr/lib/pgedge/coldfront root (COLDFRONT_EXTDIR is
# /usr/lib/pgedge/coldfront/duckdb-extensions), so the package owns its
# directory outright and the ColdFront payload stays in one namespace. Same literal path on RPM and DEB:
# deliberately not %{_libdir} and not multiarch-qualified, since nothing here is
# ever co-installed for two architectures and one path keeps the RPATH identical
# across formats. Private rather than a public libdir because the soname is
# unversioned — a public install would squat a name any future distro duckdb
# package would want.
export LIBDUCKDB_DIR="${LIBDUCKDB_DIR:-/usr/lib/pgedge/coldfront/libduckdb}"

# The clean upstream DuckDB engine version, captured BEFORE the DEB pretag fold
# below can decorate PG_DUCKDB_VERSION (1.5.4 -> 1.5.4~beta2). The per-major
# packages depend on the shared engine by this version, so the dependency stays
# stable across rc/beta rebuilds while still pinning the C++ ABI to one engine.
export PG_DUCKDB_ENGINE_VERSION="${PG_DUCKDB_VERSION}"

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
