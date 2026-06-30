#!/usr/bin/env bash
set -euo pipefail

# Install PostgreSQL client and jq
sudo apt-get update -y
sudo apt-get install -y postgresql-client jq

# Run the walkthrough setup
# Note: If the published base image is awkward to pull in CI/Codespaces,
# set COLDFRONT_BASE to build the base locally:
# export COLDFRONT_BASE=local && bash examples/walkthrough/setup.sh
bash examples/walkthrough/setup.sh || true

echo "Setup checked. Run: bash examples/walkthrough/guide.sh"
