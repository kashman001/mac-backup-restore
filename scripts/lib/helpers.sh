#!/bin/bash
# =============================================================================
# helpers.sh — Shared utilities for backup and restore scripts
# =============================================================================

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m'

log()       { echo -e "  ${GREEN}✓${NC} $1"; }
warn()      { echo -e "  ${YELLOW}!${NC} $1"; }
info()      { echo -e "  ${BLUE}i${NC} $1"; }
err()       { echo -e "  ${RED}✗${NC} $1"; }
sensitive() { echo -e "  ${RED}🔒${NC} $1"; }

header() {
    echo ""
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BOLD}  $1${NC}"
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
}

phase() {
    echo ""
    echo -e "${BLUE}── $1 ──────────────────────────────────────────${NC}"
    echo ""
}

confirm() {
    read -p "  $1 (y/n) " -n 1 -r
    echo ""
    [[ $REPLY =~ ^[Yy]$ ]]
}

has() {
    command -v "$1" &>/dev/null
}

# Look up a value by key in a pipe-delimited array.
# Usage: lookup KEY "${ARRAY[@]}"
# Prints value and returns 0 if found, returns 1 if not.
# Constraint: keys must not contain '|'. Values may contain '|' (only the first
# '|' is treated as the delimiter).
# Caller must guard empty-array expansion under bash 3.2 + set -u, e.g.:
#   [ "${#ARR[@]}" -gt 0 ] && lookup KEY "${ARR[@]}"
lookup() {
    local key="$1"; shift
    local entry
    for entry in "$@"; do
        if [ "${entry%%|*}" = "$key" ]; then
            echo "${entry#*|}"
            return 0
        fi
    done
    return 1
}
