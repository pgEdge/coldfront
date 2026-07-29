#!/usr/bin/env bash
# common.sh - ColdFront binaries package (archiver, partitioner, compactor).
#
# PG-INDEPENDENT: these are pure static Go binaries (CGO_ENABLED=0), packaged
# from the GoReleaser tarball built in the SAME release run — not compiled here.
# One build per arch (no PG-major fan-out).

export COLDFRONT_REPO="https://github.com/pgEdge/ColdFront"
export COLDFRONT_BRANCH="${COMPONENT_BRANCH:-v1.0.0}"
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
