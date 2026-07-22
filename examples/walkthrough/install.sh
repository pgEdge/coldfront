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

mkdir -p "${WORK_DIR}/examples/walkthrough/config"
mkdir -p "${WORK_DIR}/docs"

# All walkthrough files tracked under examples/walkthrough/, the
# Dockerfile needed by the db service build context, and the published
# tour document so curl-pipe users can open it in an editor.
FILES=(
    examples/walkthrough/guide.sh
    examples/walkthrough/runner.sh
    examples/walkthrough/setup.sh
    examples/walkthrough/docker-compose.yml
    examples/walkthrough/docker-compose.mesh.yml
    examples/walkthrough/Dockerfile.archiver
    examples/walkthrough/seaweedfs-s3.json
    examples/walkthrough/config/archiver.yaml
    examples/walkthrough/config/partitioner.yaml
    docker/Dockerfile.duckdb15
    docs/walkthrough.md
)

FAILED=0
for f in "${FILES[@]}"; do
    mkdir -p "${WORK_DIR}/$(dirname "$f")"
    if ! curl -fsSL "${RAW}/${f}" -o "${WORK_DIR}/${f}"; then
        echo "  Warning: failed to download ${f}" >&2
        FAILED=$((FAILED + 1))
    fi
done

if [[ $FAILED -gt 0 ]]; then
    echo ""
    echo "  Error: ${FAILED} file(s) failed to download — check your network/branch." >&2
    echo ""
    exit 1
fi

# The db service (docker-compose.yml context: ../..) and archiver service both
# build from source at $WORK_DIR. Fetch a tarball subset from GitHub — no git
# clone needed. The top-level directory inside the archive is coldfront-<branch>/
# with slashes in the branch name flattened to dashes (coldfront-main/,
# coldfront-feat-walkthrough/), so --strip-components=1 lands everything
# directly in $WORK_DIR.
TAR_DIR="coldfront-${BRANCH//\//-}"
echo "  Fetching build sources..."
if ! curl -fsSL "https://codeload.github.com/pgEdge/coldfront/tar.gz/${BRANCH}" \
    | tar -xz -C "${WORK_DIR}" --strip-components=1 \
        "${TAR_DIR}/extension" \
        "${TAR_DIR}/cmd/archiver" \
        "${TAR_DIR}/cmd/partitioner" \
        "${TAR_DIR}/internal" \
        "${TAR_DIR}/go.mod" \
        "${TAR_DIR}/go.sum" \
        "${TAR_DIR}/docker" \
        "${TAR_DIR}/THIRD_PARTY_NOTICES.md" \
        "${TAR_DIR}/LICENSE.md"; then
    echo "  Error: failed to fetch build sources" >&2
    exit 1
fi

chmod +x "${WORK_DIR}/examples/walkthrough/guide.sh" \
         "${WORK_DIR}/examples/walkthrough/setup.sh" \
         "${WORK_DIR}/examples/walkthrough/runner.sh"

cd "${WORK_DIR}"

# --- Run setup (prerequisites only) ---

bash examples/walkthrough/setup.sh

# --- Choose how to continue ---

echo ""
echo "  Setup complete! How would you like to continue?"
echo ""
echo "    1) Interactive Guide — step-by-step in this terminal  [default]"
echo "    2) Exit — I'll open the walkthrough in my editor"
echo ""
read -rp "  Choose [1/2]: " choice </dev/tty

case "$choice" in
    2)
        echo ""
        echo "  Open this file in your editor and run the commands in this terminal:"
        echo "    $(pwd)/docs/walkthrough.md"
        echo ""
        ;;
    *)
        echo ""
        exec bash examples/walkthrough/guide.sh
        ;;
esac
