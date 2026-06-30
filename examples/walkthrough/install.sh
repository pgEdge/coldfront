#!/usr/bin/env bash
# curl -fsSL https://raw.githubusercontent.com/pgEdge/coldfront/main/examples/walkthrough/install.sh | bash
set -euo pipefail

if [ -n "${CODESPACES:-}" ]; then
    echo ""
    echo "  Running inside GitHub Codespaces — setup is already handled by"
    echo "  the devcontainer. To start the walkthrough, run:"
    echo ""
    echo "      bash examples/walkthrough/guide.sh"
    echo ""
    exit 0
fi

WORK_DIR="${WALKTHROUGH_DIR:-coldfront-walkthrough}"
BRANCH="${WALKTHROUGH_BRANCH:-main}"
RAW="https://raw.githubusercontent.com/pgEdge/coldfront/${BRANCH}"

echo ""
echo "  pgEdge ColdFront Walkthrough"
echo "  ============================"
echo ""
echo "  Downloading walkthrough files..."

# All eight walkthrough files tracked under examples/walkthrough/ plus the
# Dockerfile needed by the db service build context (docker/Dockerfile.duckdb15).
FILES=(
    examples/walkthrough/guide.sh
    examples/walkthrough/runner.sh
    examples/walkthrough/setup.sh
    examples/walkthrough/docker-compose.yml
    examples/walkthrough/Dockerfile.archiver
    examples/walkthrough/seaweedfs-s3.json
    examples/walkthrough/config/archiver.yaml
    examples/walkthrough/config/partitioner.yaml
    docker/Dockerfile.duckdb15
)

for f in "${FILES[@]}"; do
    mkdir -p "${WORK_DIR}/$(dirname "$f")"
    if ! curl -fsSL "${RAW}/${f}" -o "${WORK_DIR}/${f}"; then
        echo "  Error: failed to download ${f}" >&2
        exit 1
    fi
done

# The db service (docker-compose.yml context: ../..) and archiver service both
# build from source at $WORK_DIR. Fetch a tarball subset from GitHub — no git
# clone needed. The top-level directory inside the archive is coldfront-<branch>/
# (confirmed: coldfront-main/ for branch=main), so --strip-components=1 lands
# everything directly in $WORK_DIR.
echo "  Fetching build sources..."
if ! curl -fsSL "https://codeload.github.com/pgEdge/coldfront/tar.gz/${BRANCH}" \
    | tar -xz -C "${WORK_DIR}" --strip-components=1 \
        "coldfront-${BRANCH}/extension" \
        "coldfront-${BRANCH}/cmd/archiver" \
        "coldfront-${BRANCH}/cmd/partitioner" \
        "coldfront-${BRANCH}/internal" \
        "coldfront-${BRANCH}/go.mod" \
        "coldfront-${BRANCH}/go.sum" \
        "coldfront-${BRANCH}/docker"; then
    echo "  Error: failed to fetch build sources" >&2
    exit 1
fi

chmod +x "${WORK_DIR}/examples/walkthrough/guide.sh" \
         "${WORK_DIR}/examples/walkthrough/setup.sh" \
         "${WORK_DIR}/examples/walkthrough/runner.sh"

echo "  Starting the walkthrough..."
echo ""
cd "${WORK_DIR}"
exec bash examples/walkthrough/guide.sh
