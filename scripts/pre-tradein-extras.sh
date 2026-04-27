#!/bin/bash
# =============================================================================
# pre-tradein-extras.sh — Capture data that main backup.sh does not cover
#
# Companion to backup.sh. Run AFTER the main backup, before wiping the Mac.
# Targets the gaps identified for trade-in scenarios:
#   - Login keychain (raw copy + GUI .p12 export instructions)
#   - Hidden config DIRECTORIES (the main dotfile loop only catches files)
#   - Selected sandboxed app data (Group Containers / Containers)
#   - Photos Library (only when iCloud Photos is off)
#   - Final Cut Pro / Logic Pro projects
#   - /etc/hosts and system Launch* inventory
#   - Local Postgres / MySQL / Redis dumps
#   - Docker images / volumes inventory
#   - Top-level loose files at ~ outside the standard sweep
#
# Usage: ./scripts/pre-tradein-extras.sh [--dry-run] /Volumes/MyDrive
#
#   --dry-run, -n   Walk all paths and report per-phase sizes + total estimate
#                   without writing anything to disk and without running heavy
#                   ops (DB dumps, Photos copy, etc.). Use this first to size
#                   the backup against your destination drive.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/helpers.sh"

# ── Argument parsing ────────────────────────────────────────────────────────
DRY_RUN=false
DRIVE=""
while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run|-n) DRY_RUN=true ;;
        -h|--help)
            sed -n '2,/^# =====/p' "$0" | sed 's/^# \{0,1\}//; s/^=.*$//'
            exit 0 ;;
        -*) err "Unknown flag: $1"; exit 1 ;;
        *)  [ -n "$DRIVE" ] && { err "Multiple drives given: $DRIVE and $1"; exit 1; }
            DRIVE="$1" ;;
    esac
    shift
done

if [ -z "$DRIVE" ]; then
    err "Usage: ./scripts/pre-tradein-extras.sh [--dry-run] /Volumes/YourDrive"
    echo "  Available volumes:"
    ls /Volumes/ 2>/dev/null | grep -v "Macintosh HD" | sed 's/^/    /'
    exit 1
fi
[ -d "$DRIVE" ] || { err "Drive not found: $DRIVE"; exit 1; }

# ── Dry-run helpers ─────────────────────────────────────────────────────────
# Track total estimated capture size across all phases.
TOTAL_KB=0

# Format kilobytes as a human-readable size (matches `du -sh` style).
_human() {
    awk -v kb="${1:-0}" 'BEGIN {
        u[1]="K"; u[2]="M"; u[3]="G"; u[4]="T";
        i=1; while (kb >= 1024 && i < 4) { kb /= 1024; i++ }
        printf "%.1f%s\n", kb, u[i]
    }'
}

# Add a path's size (in KB) to the running total. Swallows du failures
# (TCC-protected paths return non-zero, which would abort under pipefail).
_tally() {
    local path="$1"
    [ -e "$path" ] || return 0
    local kb
    kb=$(du -sk "$path" 2>/dev/null | awk '{print $1}' || true)
    TOTAL_KB=$(( TOTAL_KB + ${kb:-0} ))
}

# Gate a write operation. Returns 0 (caller should skip the real op) in
# dry-run mode after logging + tallying. Returns 1 in live mode so the
# caller proceeds with the actual write.
# Usage:  _dry "would copy: foo (12M)" "$src_path" || cp "$src_path" "$dst"
_dry() {
    local msg="$1"
    local src="${2:-}"
    if $DRY_RUN; then
        info "[dry-run] $msg"
        [ -n "$src" ] && _tally "$src"
        return 0
    fi
    return 1
}

# Wrapper around `mkdir -p` that is a no-op in dry-run mode.
_mkdir() { $DRY_RUN || mkdir -p "$@"; }

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
EXTRAS_DIR="$DRIVE/mac-backup-extras/$TIMESTAMP"
if ! $DRY_RUN; then
    mkdir -p "$EXTRAS_DIR"
    chmod 700 "$EXTRAS_DIR"
    chmod 700 "$DRIVE/mac-backup-extras" 2>/dev/null || true
fi

if $DRY_RUN; then
    header "Pre-Tradein Extras (DRY RUN — nothing will be written)"
else
    header "Pre-Tradein Extras"
fi
info "Destination: $EXTRAS_DIR"
AVAIL=$(df -h "$DRIVE" | tail -1 | awk '{print $4}')
info "Available space: $AVAIL"
echo ""
if $DRY_RUN; then
    info "Dry run: walking paths, reporting sizes, no writes."
else
    info "This captures gaps not covered by backup.sh. Run AFTER backup.sh."
fi
echo ""
confirm "Start?" || exit 0

# ── 1. Login Keychain ───────────────────────────────────────────────────────
phase "Login Keychain"
KC_DIR="$EXTRAS_DIR/keychain"
_mkdir "$KC_DIR"

LOGIN_KC="$HOME/Library/Keychains/login.keychain-db"
if [ -f "$LOGIN_KC" ]; then
    SIZE=$(du -sh "$LOGIN_KC" 2>/dev/null | cut -f1)
    # Item-count snapshot (no -d flag, no per-secret prompts) — read-only,
    # safe to run in both modes.
    ITEM_COUNT=$(security dump-keychain "$LOGIN_KC" 2>/dev/null | grep -c '^keychain:' || true)
    SYNC_COUNT=$(security dump-keychain "$LOGIN_KC" 2>/dev/null \
        | grep -c '"sync"<uint32>=0x00000001' || true)

    if _dry "would copy login.keychain-db ($SIZE, $ITEM_COUNT items, $((ITEM_COUNT - SYNC_COUNT)) local-only)" "$LOGIN_KC"; then
        :
    else
        cp "$LOGIN_KC" "$KC_DIR/login.keychain-db"
        log "login.keychain-db raw copy ($SIZE)"
        sensitive "Already encrypted with your OLD Mac's login password — keep it secret"

        {
            echo "Captured at: $(date)"
            echo "Items in login keychain: $ITEM_COUNT"
            echo "Items already syncing to iCloud: $SYNC_COUNT"
            echo "Local-only (will be lost without this backup): $((ITEM_COUNT - SYNC_COUNT))"
        } > "$KC_DIR/inventory.txt"
        log "Inventory: $ITEM_COUNT items, $((ITEM_COUNT - SYNC_COUNT)) local-only"
    fi

    $DRY_RUN || cat > "$KC_DIR/EXPORT-INSTRUCTIONS.txt" <<'EOF'
TWO IMPORT PATHS — do BOTH for safety, use whichever works on new Mac.

(A) GUI .p12 export (cleanest, but skips Secure Enclave items)
    1. Open Keychain Access  (open -a "Keychain Access")
    2. Click "login" in the sidebar
    3. Select all items   (Cmd-A)
    4. File → Export Items…   save as  login-keychain.p12
    5. Set a strong password (you will need it on the new Mac)
    6. Drop the .p12 file into this same directory

(B) Raw login.keychain-db file (this script already copied it)
    On new Mac:
        Keychain Access → File → Add Keychain… → pick the file
    You will be prompted for your OLD Mac's login password to unlock it.

NOTE: Touch ID / Secure Enclave-bound items cannot be exported by either path.
      They are device-locked by design. Re-enroll on the new Mac.
EOF
else
    warn "No login.keychain-db found at $LOGIN_KC"
fi

# ── 2. Hidden Config Directories ────────────────────────────────────────────
# The main backup.sh dotfile loop only catches files at $HOME/.* — directories
# are skipped. These are the user-config dirs worth grabbing.
phase "Hidden Config Directories"
HIDDEN_DIRS=(
    .iterm2 .gitkraken .gemini .codex .cursor .vscode
    .ipython .jupyter .matplotlib
    .cups
    .gk .gitflow_export
    .local
    .docker .kube      # in case main backup missed (it copies these by name only)
)
HID_DST="$EXTRAS_DIR/hidden-dirs"
_mkdir "$HID_DST"
HID_COUNT=0
for d in "${HIDDEN_DIRS[@]}"; do
    [ -d "$HOME/$d" ] || continue
    SIZE=$(du -sh "$HOME/$d" 2>/dev/null | cut -f1)
    if _dry "would copy $d ($SIZE, pre-cache-exclude)" "$HOME/$d"; then
        HID_COUNT=$((HID_COUNT + 1))
        continue
    fi
    rsync -a \
        --exclude='*/Cache*' --exclude='*/cache*' \
        --exclude='*/logs/*' --exclude='*.log' \
        --exclude='*/GPUCache/*' --exclude='*/blob_storage/*' \
        --exclude='*/CachedData/*' --exclude='*/CachedExtensions/*' \
        "$HOME/$d/" "$HID_DST/$d/" 2>/dev/null || true
    if [ -d "$HID_DST/$d" ]; then
        SIZE=$(du -sh "$HID_DST/$d" 2>/dev/null | cut -f1)
        log "$d ($SIZE)"
        HID_COUNT=$((HID_COUNT + 1))
    fi
done
info "Captured $HID_COUNT hidden directories"

# ── 3. Sandboxed App Data (Group Containers + Containers) ───────────────────
# Strategy: inventory ALL bundle IDs (cheap), copy a curated whitelist.
# The whole tree is tens of GB — copying everything is wasteful and most app
# state is rebuilt on first launch anyway. Edit the patterns below to taste.
phase "Sandboxed App Data"

GC_KEEP_PATTERNS=(
    # Apple core data
    'group.com.apple.notes'
    'group.com.apple.calendar'
    'group.com.apple.reminders'
    'group.com.apple.AddressBook'
    'group.com.apple.shortcuts'
    'group.com.apple.stickies'
    'group.com.apple.VoiceMemos'
    # Messaging / 2FA — irreplaceable if not synced
    'net.whatsapp.WhatsApp'
    'authy'
    '1password'
    'authenticator'
    'bitwarden'
    # Knowledge / journaling apps that store data locally
    'md.obsidian'
    'com.bear-writer'
    'com.dayoneapp'
    'com.culturedcode.things3'
    'com.agiletortoise.Drafts'
    'com.literatureandlatte.scrivener'
)
C_KEEP_PATTERNS=(
    'com.apple.Notes'
    'com.apple.iCal'
    'com.apple.reminders'
    'com.apple.AddressBook'
    'com.apple.Shortcuts'
    'com.apple.stickies'
    'com.apple.VoiceMemos'
    'com.apple.iWork'         # Pages, Numbers, Keynote
    'authy' '1password' 'authenticator' 'bitwarden'
    'md.obsidian'
    'com.bear-writer'
    'com.dayoneapp'
    'com.culturedcode.things3'
    'com.agiletortoise.Drafts'
)

# Helper: returns 0 if $1 matches any pattern in the named array.
matches_any() {
    local s="$1"; shift
    local p
    for p in "$@"; do
        case "$s" in
            *"$p"*) return 0 ;;
        esac
    done
    return 1
}

capture_sandbox() {
    local label="$1" src="$2" dst_root="$3"
    shift 3
    local patterns=("$@")

    [ -d "$src" ] || { info "$label: not found"; return 0; }
    _mkdir "$dst_root"
    local inv="$dst_root/inventory.txt"
    local sel="$dst_root/selected"
    _mkdir "$sel"

    if ! $DRY_RUN; then
        {
            echo "# $label inventory ($(date))"
            echo "# Format: SIZE  STATUS  bundle-id"
            echo "# STATUS: KEPT = copied to selected/, SKIP = inventoried only"
            echo ""
        } > "$inv"
    fi

    local kept=0 skipped=0
    local kept_kb=0 skip_kb=0
    while IFS= read -r d; do
        [ -d "$d" ] || continue
        local name; name=$(basename "$d")
        # `|| true` inside the pipeline guards against TCC-protected entries
        # (du exits non-zero, which would otherwise abort under pipefail).
        local size; size=$(du -sh "$d" 2>/dev/null | cut -f1 || true)
        local kb;   kb=$(du -sk "$d" 2>/dev/null | awk '{print $1}' || true)
        if matches_any "$name" "${patterns[@]}"; then
            kept=$((kept + 1))
            kept_kb=$((kept_kb + ${kb:-0}))
            if $DRY_RUN; then
                _tally "$d"
            else
                rsync -a \
                    --exclude='*/Cache*' --exclude='*/cache*' --exclude='*/Caches/*' \
                    --exclude='*/logs/*' --exclude='*.log' \
                    "$d/" "$sel/$name/" 2>/dev/null || true
                printf '%-10s KEPT  %s\n' "$size" "$name" >> "$inv"
            fi
        else
            skipped=$((skipped + 1))
            skip_kb=$((skip_kb + ${kb:-0}))
            $DRY_RUN || printf '%-10s SKIP  %s\n' "$size" "$name" >> "$inv"
        fi
    done < <(find "$src" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort)

    if $DRY_RUN; then
        info "[dry-run] $label: $kept would-keep ($(_human "$kept_kb")), $skipped inventory-only ($(_human "$skip_kb"))"
    else
        log "$label: $kept kept, $skipped inventoried-only"
        [ "$kept" -gt 0 ] && info "  Kept data size: $(du -sh "$sel" 2>/dev/null | cut -f1)"
    fi
}

capture_sandbox "Group Containers" \
    "$HOME/Library/Group Containers" \
    "$EXTRAS_DIR/group-containers" \
    "${GC_KEEP_PATTERNS[@]}"

capture_sandbox "Containers" \
    "$HOME/Library/Containers" \
    "$EXTRAS_DIR/containers" \
    "${C_KEEP_PATTERNS[@]}"

# ── 4. TCC-protected Apple app data ─────────────────────────────────────────
# Mail / Messages / Safari live under ~/Library/ but are TCC-gated. Without
# Full Disk Access for Terminal these will fail with permission errors.
phase "Apple App Data (TCC-protected)"
TCC_DST="$EXTRAS_DIR/apple-apps"
_mkdir "$TCC_DST"
TCC_OK=true
for sub in Mail Messages Calendars Safari; do
    src="$HOME/Library/$sub"
    [ -d "$src" ] || continue
    # Use du as a TCC probe — fails the same way rsync would, without writing.
    if ! SIZE=$(du -sh "$src" 2>/dev/null | cut -f1) || [ -z "$SIZE" ]; then
        warn "$sub — permission denied (Terminal needs Full Disk Access)"
        TCC_OK=false
        continue
    fi
    if _dry "would copy $sub ($SIZE)" "$src"; then
        continue
    fi
    if rsync -a --exclude='Caches/' --exclude='*.log' \
        "$src/" "$TCC_DST/$sub/" 2>/dev/null; then
        log "$sub ($SIZE)"
    else
        warn "$sub — permission denied during rsync"
        TCC_OK=false
    fi
done
if ! $TCC_OK; then
    cat <<'EOF'

  → Grant Full Disk Access to your terminal and re-run if you want this data:
       System Settings → Privacy & Security → Full Disk Access → enable for Terminal
EOF
fi

# ── 5. Photos Library (only if iCloud Photos is OFF) ────────────────────────
phase "Photos Library"
PHOTOS="$HOME/Pictures/Photos Library.photoslibrary"
if [ -d "$PHOTOS" ]; then
    if is_icloud_photos_enabled; then
        info "iCloud Photos is ENABLED — library re-syncs on new Mac, skipping"
    else
        SIZE=$(du -sh "$PHOTOS" 2>/dev/null | cut -f1 || true)
        warn "iCloud Photos is OFF — your library is local-only"
        if $DRY_RUN; then
            info "[dry-run] would prompt to back up Photos Library ($SIZE) — counting it as included in the estimate"
            _tally "$PHOTOS"
        elif confirm "Back up Photos Library ($SIZE)?"; then
            mkdir -p "$EXTRAS_DIR/photos-library"
            rsync -a --progress "$PHOTOS/" "$EXTRAS_DIR/photos-library/Photos Library.photoslibrary/" 2>/dev/null
            log "Photos Library captured"
        fi
    fi
else
    info "No Photos Library at default path"
fi

# ── 6. Creative Apps (Final Cut Pro, Logic Pro) ─────────────────────────────
phase "Creative Apps"
CREATIVE="$EXTRAS_DIR/creative"
_mkdir "$CREATIVE"

# Final Cut Pro libraries — *.fcpbundle anywhere under ~/Movies
while IFS= read -r bundle; do
    [ -d "$bundle" ] || continue
    name=$(basename "$bundle")
    SIZE=$(du -sh "$bundle" 2>/dev/null | cut -f1 || true)
    if $DRY_RUN; then
        info "[dry-run] would prompt: Final Cut library $name ($SIZE) — counting in estimate"
        _tally "$bundle"
        continue
    fi
    if confirm "Back up Final Cut library $name ($SIZE)?"; then
        rsync -a --progress "$bundle/" "$CREATIVE/finalcut/$name/" 2>/dev/null
        log "Final Cut: $name"
    fi
done < <(find "$HOME/Movies" -maxdepth 2 -name '*.fcpbundle' -type d 2>/dev/null)

# Logic Pro projects + audio packs
for sub in "Logic" "Audio Music Apps"; do
    src="$HOME/Music/$sub"
    [ -d "$src" ] || continue
    SIZE=$(du -sh "$src" 2>/dev/null | cut -f1 || true)
    if $DRY_RUN; then
        info "[dry-run] would prompt: ~/Music/$sub ($SIZE) — counting in estimate"
        _tally "$src"
        continue
    fi
    if confirm "Back up ~/Music/$sub ($SIZE)?"; then
        rsync -a --progress "$src/" "$CREATIVE/$(echo "$sub" | tr ' ' '-' | tr '[:upper:]' '[:lower:]')/" 2>/dev/null
        log "Logic: $sub"
    fi
done

# ── 7. System Files & Inventory ─────────────────────────────────────────────
phase "System Files"
SYS="$EXTRAS_DIR/system"
_mkdir "$SYS"

# /etc/hosts
if [ -r /etc/hosts ]; then
    if _dry "would copy /etc/hosts" "/etc/hosts"; then
        :
    else
        cp /etc/hosts "$SYS/etc-hosts"
        log "/etc/hosts"
        # Also save a diff against the macOS default so restore can show what's custom
        cat > "$SYS/etc-hosts.default" <<'EOF'
##
# Host Database
#
# localhost is used to configure the loopback interface
# when the system is booting.  Do not change this entry.
##
127.0.0.1	localhost
255.255.255.255	broadcasthost
::1             localhost
EOF
    fi
fi

# System-wide LaunchAgents and LaunchDaemons — INVENTORY ONLY.
# These plists reference apps that don't exist on the new Mac yet; restoring
# them blindly causes launchd errors. Save the list so the user knows what
# to reinstall.
for d in /Library/LaunchAgents /Library/LaunchDaemons; do
    [ -d "$d" ] || continue
    out="$SYS/$(echo "$d" | tr '/' '_' | sed 's/^_//').txt"
    COUNT=$(ls -1 "$d" 2>/dev/null | wc -l | tr -d ' ')
    if $DRY_RUN; then
        info "[dry-run] would inventory $d ($COUNT entries)"
    else
        ls -1 "$d" > "$out" 2>/dev/null || true
        log "$d inventory ($COUNT entries)"
    fi
done

# crontab is already captured by main backup; skip.

# ── 8. Homebrew Services & Local Databases ──────────────────────────────────
phase "Local Services & Databases"
DBS="$EXTRAS_DIR/databases"
_mkdir "$DBS"

if has brew; then
    if _dry "would snapshot 'brew services list'"; then
        :
    else
        brew services list > "$DBS/brew-services.txt" 2>/dev/null || true
        log "brew services snapshot"
    fi
fi

# Postgres dump (if reachable). Skip the actual dump in dry-run — it's slow
# and the size depends on data we don't pre-measure.
if has pg_dumpall && pg_isready -q 2>/dev/null; then
    if $DRY_RUN; then
        info "[dry-run] Postgres is running — would prompt to pg_dumpall"
    elif confirm "Postgres is running — dump all databases?"; then
        pg_dumpall > "$DBS/postgres-dumpall.sql" 2>/dev/null \
            && log "Postgres pg_dumpall ($(du -sh "$DBS/postgres-dumpall.sql" | cut -f1))" \
            || warn "pg_dumpall failed (auth?)"
    fi
fi

# MySQL / MariaDB dump
if has mysqldump && (mysql -e "SELECT 1" >/dev/null 2>&1); then
    if $DRY_RUN; then
        info "[dry-run] MySQL is running — would prompt to mysqldump --all-databases"
    elif confirm "MySQL is running — dump all databases?"; then
        mysqldump --all-databases > "$DBS/mysql-dumpall.sql" 2>/dev/null \
            && log "MySQL mysqldump" \
            || warn "mysqldump failed (auth?)"
    fi
fi

# Redis BGSAVE — copy the .rdb after
if has redis-cli && redis-cli ping 2>/dev/null | grep -q PONG; then
    if $DRY_RUN; then
        info "[dry-run] Redis is running — would BGSAVE and copy .rdb snapshots"
    elif confirm "Redis is running — capture RDB snapshot?"; then
        redis-cli BGSAVE >/dev/null 2>&1 || true
        sleep 2
        for rdb in /opt/homebrew/var/db/redis/*.rdb /usr/local/var/db/redis/*.rdb; do
            [ -f "$rdb" ] || continue
            cp "$rdb" "$DBS/$(basename "$rdb")"
            log "Redis: $(basename "$rdb")"
        done
    fi
fi

# Raw on-disk DB locations — if user wants the whole var dir
for var_dir in /opt/homebrew/var /usr/local/var; do
    [ -d "$var_dir" ] || continue
    for sub in postgres mysql redis postgresql@14 postgresql@15 postgresql@16; do
        [ -d "$var_dir/$sub" ] || continue
        SIZE=$(du -sh "$var_dir/$sub" 2>/dev/null | cut -f1)
        info "On-disk: $var_dir/$sub ($SIZE) — restore by copying back to same path"
        $DRY_RUN || echo "$var_dir/$sub|$SIZE" >> "$DBS/on-disk-data-dirs.txt"
    done
done

# ── 9. Docker ───────────────────────────────────────────────────────────────
phase "Docker"
DOCK="$EXTRAS_DIR/docker"
_mkdir "$DOCK"
if has docker && docker ps >/dev/null 2>&1; then
    IMG_COUNT=$(docker image ls -q  2>/dev/null | wc -l | tr -d ' ')
    VOL_COUNT=$(docker volume ls -q 2>/dev/null | wc -l | tr -d ' ')
    if $DRY_RUN; then
        info "[dry-run] would inventory Docker: $IMG_COUNT images, $VOL_COUNT volumes"
    else
        docker image ls  --format '{{.Repository}}:{{.Tag}} ({{.Size}})' > "$DOCK/images.txt" 2>/dev/null || true
        docker volume ls --format '{{.Name}} ({{.Driver}})'             > "$DOCK/volumes.txt" 2>/dev/null || true
        docker ps -a     --format '{{.Names}} | {{.Image}} | {{.Status}}' > "$DOCK/containers.txt" 2>/dev/null || true
        log "Docker images: $IMG_COUNT"
        log "Docker volumes: $VOL_COUNT"
        info "Volumes are inventoried only — re-pull images and recreate volumes on new Mac"
    fi
else
    info "Docker not running — skipping"
fi

# ── 10. Top-level Loose Files in $HOME ──────────────────────────────────────
# The main backup walks Documents/Desktop/Downloads/Pictures/Music/Movies, so
# anything else at depth 1 of $HOME (non-hidden, non-symlink, non-system-dir)
# is missed. Capture small dirs verbatim, list large ones.
phase "Top-level Loose Files"
TOP="$EXTRAS_DIR/toplevel"
_mkdir "$TOP"

KNOWN_TOP=(
    Documents Desktop Downloads Music Movies Pictures Public Sites
    Library Applications Developer
)
is_known_top() {
    local n="$1"; local k
    for k in "${KNOWN_TOP[@]}"; do
        [ "$n" = "$k" ] && return 0
    done
    return 1
}

while IFS= read -r entry; do
    name=$(basename "$entry")
    # Skip hidden, symlinks, and the standard dirs
    case "$name" in .*) continue ;; esac
    [ -L "$entry" ] && continue
    is_known_top "$name" && continue

    SIZE_BYTES=$(du -sk "$entry" 2>/dev/null | awk '{print $1}' || true)
    SIZE=$(du -sh "$entry" 2>/dev/null | cut -f1 || true)

    # 500 MB cutoff — above this we just inventory unless user opts in
    if [ "${SIZE_BYTES:-0}" -gt 512000 ]; then
        if $DRY_RUN; then
            info "[dry-run] would prompt: $name ($SIZE) — counting in estimate"
            _tally "$entry"
        elif confirm "$name is $SIZE — back it up?"; then
            rsync -a "$entry" "$TOP/" 2>/dev/null || true
            log "$name ($SIZE)"
        else
            echo "$name | $SIZE | SKIPPED" >> "$TOP/skipped.txt"
        fi
    else
        if _dry "would copy $name ($SIZE)" "$entry"; then
            continue
        fi
        rsync -a "$entry" "$TOP/" 2>/dev/null || true
        log "$name ($SIZE)"
    fi
done < <(find "$HOME" -mindepth 1 -maxdepth 1 2>/dev/null | sort)

# ── 11. README ──────────────────────────────────────────────────────────────
$DRY_RUN || cat > "$EXTRAS_DIR/README.txt" <<EOF
Pre-Tradein Extras
==================
Captured: $(date)
Host:     $(hostname)
User:     $(whoami)

This directory contains data NOT covered by the main backup.sh, captured
before trading in or wiping the source Mac.

Layout
------
  keychain/             login.keychain-db raw copy + .p12 export instructions
  hidden-dirs/          Hidden directories at \$HOME (.iterm2, .gitkraken, etc.)
  group-containers/     Selected sandboxed Group Container data (whitelisted)
  containers/           Selected sandboxed Container data (whitelisted)
  apple-apps/           Mail, Messages, Calendars, Safari (TCC-permitting)
  photos-library/       Photos Library (only present if iCloud Photos was off)
  creative/             Final Cut Pro / Logic Pro projects
  system/               /etc/hosts + system Launch* inventory
  databases/            Postgres / MySQL / Redis dumps + brew services list
  docker/               Docker images / volumes / containers inventory
  toplevel/             Loose files at \$HOME outside the standard sweep

Restore
-------
On the new Mac:
    bash scripts/restore-tradein-extras.sh "$EXTRAS_DIR"

Or run individual phases by inspecting restore-tradein-extras.sh.
EOF

# ── Done ────────────────────────────────────────────────────────────────────
if $DRY_RUN; then
    header "Dry Run Summary"
    AVAIL_KB=$(df -k "$DRIVE" 2>/dev/null | tail -1 | awk '{print $4}')
    log "Estimated capture size: $(_human "$TOTAL_KB")"
    log "Available on $DRIVE:    $(_human "${AVAIL_KB:-0}")"
    if [ "${AVAIL_KB:-0}" -lt "$TOTAL_KB" ]; then
        warn "Estimated size exceeds available space — free up room or pick a larger drive"
    else
        info "Drive has enough space"
    fi
    echo ""
    info "Re-run without --dry-run to actually capture:"
    echo "    bash $REPO_DIR/scripts/pre-tradein-extras.sh \"$DRIVE\""
    echo ""
    info "(estimates count would-confirm-yes paths at full size; drop the ones"
    info " you'll skip at the prompt and your real capture will be smaller.)"
    echo ""
else
    header "Pre-Tradein Extras Complete"
    TOTAL=$(du -sh "$EXTRAS_DIR" 2>/dev/null | cut -f1)
    log "Total size: $TOTAL"
    log "Location:   $EXTRAS_DIR"
    echo ""
    info "Restore later with:"
    echo "    bash $REPO_DIR/scripts/restore-tradein-extras.sh \"$EXTRAS_DIR\""
    echo ""
fi
