#!/usr/bin/env bash
set -euo pipefail

# Entry point for the pgEdge builder-action. Invoked as:
#   common/build.sh <component>
# where <component> is a packaging dir under the repo root that holds a
# common.sh + build-rpm.sh / build-deb.sh (e.g. "packaging/pg_duckdb").
COMPONENT_NAME=$1
source "$(dirname "$0")/../${COMPONENT_NAME}/common.sh"

# common-functions.sh is a committed copy of the shared pgEdge build helpers
# (from pgedge-enterprise-packages/common/). The builder-action mounts the repo
# and runs this script but does not supply it, so it must live in the repo —
# same pattern as ai-dba-workbench's packaging/scripts/common-functions.sh.
COMMON_FILE="$(dirname "$0")/common-functions.sh"
if [ -f "$COMMON_FILE" ]; then
  source "$COMMON_FILE"
else
  echo "Error: $COMMON_FILE not found!" >&2
  exit 1
fi

###########
# Main
###########
detect_os_type
prepare
build
post_build
