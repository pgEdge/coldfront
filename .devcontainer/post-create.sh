#!/usr/bin/env bash
set -euo pipefail

echo "=== ColdFront Walkthrough — Codespaces Setup ==="

# Install PostgreSQL client, jq, and iproute2 (setup.sh needs `ss`)
echo "Installing jq, iproute2, and the PostgreSQL client..."
sudo apt-get update -qq
sudo apt-get install -y -qq postgresql-client jq iproute2

# Run the prerequisites check
# Note: If the published base image is awkward to pull in CI/Codespaces,
# set COLDFRONT_BASE to build the base locally:
# export COLDFRONT_BASE=local && bash examples/walkthrough/setup.sh
echo ""
bash examples/walkthrough/setup.sh

echo ""
echo "Setup complete!"
echo "  Walkthrough:       docs/walkthrough.md is open - click 'Run' on each cell as you read"
echo "  Interactive Guide: bash examples/walkthrough/guide.sh (terminal alternative)"
