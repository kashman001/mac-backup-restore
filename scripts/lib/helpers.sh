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

# Strip leading and trailing whitespace from $1.
# Pure bash 3.2 — does NOT pipe through xargs, which would choke on input
# containing unbalanced quotes (e.g. a Steam game name like "Don't Starve").
trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
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

# Returns 0 if PATH is part of iCloud Desktop & Documents sync.
# Detection: the iCloud File Provider stamps an xattr on managed dirs.
is_icloud_drive_synced() {
    [ -e "$1" ] || return 1
    xattr -p com.apple.file-provider-domain-id "$1" 2>/dev/null \
        | grep -q "CloudDocs.iCloudDriveFileProvider"
}

# Returns 0 if iCloud Photos sync is enabled.
# Detection: combines two signals — either is sufficient.
#   1. The Photos Library has a "cpl/" (Cloud Photo Library) subdir under
#      resources/, which is created when iCloud Photos is provisioned for that
#      library and persists across daemon idle states.
#   2. com.apple.cloudphotod has a CPLEngineParameters-SystemLibrary key, set
#      by the daemon when it's actively running. Authoritative when present
#      but absent when the daemon has been idle.
is_icloud_photos_enabled() {
    [ -d "$HOME/Pictures/Photos Library.photoslibrary/resources/cpl" ] && return 0
    defaults read com.apple.cloudphotod "CPLEngineParameters-SystemLibrary" \
        >/dev/null 2>&1
}

# Returns 0 if Apple Music's iCloud Music Library / Sync Library is on.
# Detection: combines two persistent signals from com.apple.Music defaults.
#   1. _MPCloudServiceStatusControllerSubscriptionAvailability=1 — Music.app
#      has confirmed an active Apple Music subscription with cloud library.
#   2. doesStoreSupportCloudMusicLibrary=1 — Music.app has confirmed the
#      account supports cloud library access. Stays set across launches.
# Either signal being "1" means cloud library is available.
is_icloud_music_enabled() {
    local v
    v=$(defaults read com.apple.Music _MPCloudServiceStatusControllerSubscriptionAvailability 2>/dev/null) || true
    [ "$v" = "1" ] && return 0
    v=$(defaults read com.apple.Music doesStoreSupportCloudMusicLibrary 2>/dev/null) || true
    [ "$v" = "1" ] && return 0
    return 1
}

# Returns 0 if TV.app's iCloud / iTunes-in-the-Cloud is on.
is_icloud_tv_enabled() {
    [ "$(defaults read com.apple.TV cloudLibraryEnabled 2>/dev/null)" = "1" ]
}
