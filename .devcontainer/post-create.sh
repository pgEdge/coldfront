#!/usr/bin/env bash
set -euo pipefail

echo "=== ColdFront Walkthrough: Codespaces Setup ==="

# Install PostgreSQL client, jq, and iproute2 (setup.sh needs `ss`)
echo "Installing jq, iproute2, and the PostgreSQL client..."
sudo apt-get update -qq
sudo apt-get install -y -qq postgresql-client jq iproute2

# Run the prerequisites check
echo ""
bash examples/walkthrough/setup.sh

echo ""
echo "Setup complete!"
echo "  Walkthrough:       docs/walkthrough.md is open - click 'Run' on each cell as you read"
echo "  Interactive Guide: bash examples/walkthrough/guide.sh (terminal alternative)"
