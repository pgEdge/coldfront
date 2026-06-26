#!/usr/bin/env bash
set -euo pipefail

# setup.sh -- Check prerequisites for the ColdFront walkthrough.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=runner.sh
source "$SCRIPT_DIR/runner.sh"
OS="$(uname -s)"

header "ColdFront Walkthrough -- Prerequisites Check"
explain "Checking that required tools are installed..."
echo ""

REQUIRED_CMDS=(docker curl jq psql)
if [[ "$OS" == "Darwin" ]]; then REQUIRED_CMDS+=(lsof); else REQUIRED_CMDS+=(ss); fi
MISSING=()
for cmd in "${REQUIRED_CMDS[@]}"; do
  if command -v "$cmd" &>/dev/null; then
    info "$cmd  found ($(command -v "$cmd"))"
  else
    error "$cmd  not found"; MISSING+=("$cmd")
  fi
done
echo ""

if [[ ${#MISSING[@]} -gt 0 ]]; then
  warn "Missing tools: ${MISSING[*]}"
  explain "Install hints:"
  for cmd in "${MISSING[@]}"; do
    case "$cmd" in
      docker) explain "  docker  -- https://docs.docker.com/get-docker/";;
      curl)   explain "  curl    -- https://curl.se/download.html";;
      jq)     explain "  jq      -- https://jqlang.github.io/jq/download/";;
      psql)
        if [[ "$OS" == "Darwin" ]]; then
          explain "  psql    -- brew install libpq && brew link --force libpq"
        else
          explain "  psql    -- install postgresql-client via your package manager"
        fi;;
      lsof) explain "  lsof    -- xcode-select --install";;
      ss)   explain "  ss      -- sudo apt-get install -y iproute2";;
    esac
  done
  echo ""
  error "Install the missing tools, then re-run the guide."
  exit 1
fi

explain "Verifying Docker daemon is accessible..."
if ! docker info &>/dev/null; then
  echo ""
  if [[ "$OS" == "Darwin" ]]; then
    error "Docker does not appear to be running. Start Docker Desktop and re-run."
  elif command -v systemctl &>/dev/null && systemctl is-active docker &>/dev/null 2>&1; then
    error "Docker is running but your user cannot access it."
    explain "  sudo usermod -aG docker \$USER && newgrp docker"
  else
    error "Docker is installed but the daemon is not running."
    explain "  sudo systemctl start docker"
  fi
  exit 1
fi
info "Docker daemon is running."
echo ""

# Apple Silicon note: the published base may be amd64-only (see plan Task 1).
if [[ "$OS" == "Darwin" && "$(uname -m)" == "arm64" ]]; then
  warn "Apple Silicon detected. If the coldfront base image has no arm64 build,"
  warn "it runs under emulation (functional, slower). The walkthrough still works."
  echo ""
fi

info "All prerequisites satisfied."
