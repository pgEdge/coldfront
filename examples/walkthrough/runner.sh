# shellcheck shell=bash
# runner.sh: Terminal UX framework for interactive walkthrough scripts.
# Source this file from guide.sh; do not execute directly.
#
# Usage:
#   SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
#   source "$SCRIPT_DIR/runner.sh"

# --- Colors and formatting (pgEdge brand: teal + orange) ---
# shellcheck disable=SC2034  # Colors are used by sourcing scripts
BOLD='\033[1m'
TEAL='\033[38;5;30m'
ORANGE='\033[38;5;172m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
DIM='\033[2m'
RESET='\033[0m'

# --- Output helpers ---

header() {
  echo ""
  echo -e "${BOLD}${TEAL}══════════════════════════════════════════════════════════════${RESET}"
  echo -e "${BOLD}${TEAL}$1${RESET}"
  echo -e "${BOLD}${TEAL}══════════════════════════════════════════════════════════════${RESET}"
  echo ""
}

info() {
  echo -e "${GREEN}$1${RESET}"
}

warn() {
  echo -e "${YELLOW}$1${RESET}"
}

error() {
  echo -e "${RED}$1${RESET}"
}

explain() {
  echo -e "$1"
}

# type_out <text>: print <text> one character at a time, WALKTHROUGH_TYPE_DELAY
# seconds apart (default 0: all at once). Every command the guide shows goes
# through it, so a recording can have the commands typed.
TYPE_DELAY="${WALKTHROUGH_TYPE_DELAY:-0}"
type_out() {
  local s="$1" i
  if [ "$TYPE_DELAY" = 0 ]; then printf '%s' "$s"; return; fi
  for (( i=0; i<${#s}; i++ )); do
    printf '%s' "${s:i:1}"
    sleep "$TYPE_DELAY"
  done
}

show_cmd() {
  echo ""
  printf '%b' "${ORANGE}\$ "
  type_out "$1"
  printf '%b\n' "${RESET}"
}

# --- Interactive helpers ---

prompt_continue() {
  echo ""
  read -rp "Press Enter to continue..." </dev/tty
  echo ""
}

# --- Spinner ---

SPINNER_PID=""

start_spinner() {
  local msg="$1"
  if [[ ${BASH_VERSINFO[0]} -ge 4 ]]; then
    local chars='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
  else
    local chars='/-\|'
  fi
  (
    while true; do
      for (( i=0; i<${#chars}; i++ )); do
        printf "\r\033[38;5;30m%s\033[0m %s" "${chars:$i:1}" "$msg"
        sleep 0.1
      done
    done
  ) &
  SPINNER_PID=$!
}

stop_spinner() {
  if [[ -n "${SPINNER_PID:-}" ]]; then
    kill "$SPINNER_PID" 2>/dev/null || true
    wait "$SPINNER_PID" 2>/dev/null || true
    printf "\r\033[K"
    SPINNER_PID=""
  fi
}
