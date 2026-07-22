#!/usr/bin/env bash
# common.sh - Lakekeeper (Apache Iceberg REST Catalog) package.
#
# PG-INDEPENDENT: packaged from the upstream PREBUILT release binary
# (github.com/lakekeeper/lakekeeper), NOT compiled here. One build per arch (no
# PG-major fan-out). The build scripts auto-detect the arch from the build
# container and download the matching release tarball.
#
# The upstream binaries are glibc-DYNAMIC and require GLIBC >= 2.34, so this
# package targets el9/el10 + jammy/noble/bookworm/trixie. Debian bullseye
# (glibc 2.31) CANNOT run these prebuilt binaries and is intentionally omitted.

export LAKEKEEPER_VERSION="${COMPONENT_VERSION:-0.13.1}"
export LAKEKEEPER_BUILDNUM="${COMPONENT_BUILDNUM:-1}"

# DEB only: move a pre-release pretag (e.g. BUILDNUM='rc1_1') into the upstream
# VERSION with a leading '~' (0.13.1~rc1, BUILDNUM=1) so '~' sorts pre-releases
# BELOW stable in dpkg/reprepro. Gated on apt-get so RPM keeps the pretag in
# Release (rpmvercmp already sorts rc1_1 below stable).
if command -v apt-get &>/dev/null; then
    if [[ "$LAKEKEEPER_BUILDNUM" == *_* ]]; then
        LAKEKEEPER_PRETAG="${LAKEKEEPER_BUILDNUM%%_*}"
        export LAKEKEEPER_VERSION="${LAKEKEEPER_VERSION}~${LAKEKEEPER_PRETAG}"
        LAKEKEEPER_BUILDNUM="${LAKEKEEPER_BUILDNUM#*_}"
    fi
fi
export LAKEKEEPER_BUILDNUM

export REPO_TYPE="${REPO_TYPE:-daily}"
