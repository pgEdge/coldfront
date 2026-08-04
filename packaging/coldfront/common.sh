#!/usr/bin/env bash
# common.sh - Common environment variables for the ColdFront extension package.

# Build once per PostgreSQL major version (fan-out across the matrix).
PER_PG_VERSION=true

# Default PostgreSQL version and derived values
export PG_VERSION="${PG_VERSION:-17.7}"
export PG_MAJOR_VERSION="$(echo "$PG_VERSION" | cut -d. -f1)"

# The coldfront extension source lives in THIS repo (extension/coldfront), so
# there is no upstream repo/branch to fetch. The package version is the
# ColdFront release version (tag-driven via COMPONENT_VERSION); the extension's
# SQL version (coldfront.control default_version) is independent of it.
export COLDFRONT_VERSION="${COMPONENT_VERSION:-1.0.0}"
export COLDFRONT_BUILDNUM="${COMPONENT_BUILDNUM:-1}"

# DEB only: move a pre-release pretag (e.g. BUILDNUM='rc1_1') into the upstream
# VERSION with a leading '~' (1.0.0~rc1, BUILDNUM=1) so '~' sorts pre-releases
# BELOW stable in dpkg/reprepro. Gated on apt-get so RPM keeps the pretag in
# Release (rpmvercmp already sorts rc1_1 below 1).
if command -v apt-get &>/dev/null; then
    if [[ "$COLDFRONT_BUILDNUM" == *_* ]]; then
        COLDFRONT_PRETAG="${COLDFRONT_BUILDNUM%%_*}"
        export COLDFRONT_VERSION="${COLDFRONT_VERSION}~${COLDFRONT_PRETAG}"
        COLDFRONT_BUILDNUM="${COLDFRONT_BUILDNUM#*_}"
    fi
fi

export REPO_TYPE="${REPO_TYPE:-daily}"
