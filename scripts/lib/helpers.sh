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
