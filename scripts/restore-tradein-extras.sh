#!/bin/bash
# =============================================================================
# restore-tradein-extras.sh — Import data captured by pre-tradein-extras.sh
#
# Run AFTER restore.sh has set up the new Mac (Homebrew installed, apps
# reinstalled, dotfiles in place). Walks each phase with confirms because
# many sandboxed apps need to be installed and run once before their data
# directories will accept imports.
#
# Usage: ./scripts/restore-tradein-extras.sh /path/to/mac-backup-extras/<timestamp>
# =============================================================================

# No `set -e` — like restore.sh, dozens of optional ops where one failure
# should not sink the run. Keep -u and pipefail.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/helpers.sh"

EXTRAS="${1:-}"
if [ -z "$EXTRAS" ] || [ ! -d "$EXTRAS" ]; then
    err "Usage: ./scripts/restore-tradein-extras.sh /path/to/mac-backup-extras/<timestamp>"
    exit 1
fi
[ -f "$EXTRAS/README.txt" ] || warn "No README.txt — is this really a pre-tradein-extras directory?"

LOG_FILE="$HOME/.mac-restore-extras.log"
exec > >(tee -a "$LOG_FILE") 2>&1
echo "=== restore-tradein-extras: $(date) — source: $EXTRAS ==="

MANUAL_TODO="$HOME/.mac-restore-extras-todo.txt"
> "$MANUAL_TODO"
todo() { echo "  - $1" >> "$MANUAL_TODO"; }

header "Restore Pre-Tradein Extras"
info "Source:  $EXTRAS"
info "Log:     $LOG_FILE"
info "Todo:    $MANUAL_TODO"
echo ""
confirm "Start?" || exit 0

# ── 1. Login Keychain ───────────────────────────────────────────────────────
phase "Login Keychain"
KC="$EXTRAS/keychain"
if [ -d "$KC" ]; then
    [ -f "$KC/inventory.txt" ] && cat "$KC/inventory.txt" | sed 's/^/    /'

    # Prefer .p12 import if present
    P12=$(find "$KC" -maxdepth 1 -name '*.p12' -type f 2>/dev/null | head -1)
    if [ -n "$P12" ] && [ -f "$P12" ]; then
        warn "Found $(basename "$P12") — needs the password you set during export"
        if confirm "Import .p12 into your login keychain now?"; then
            # Interactive password prompt happens here.
            if security import "$P12" -k "$HOME/Library/Keychains/login.keychain-db" -A; then
                log "Imported $(basename "$P12")"
                sensitive "Items added — first app access will prompt 'Always Allow'"
            else
                warn "Import failed (wrong password? or items already present)"
                todo "Import keychain manually: open $P12 in Finder"
            fi
        else
            todo "Import keychain manually: double-click $P12"
        fi
    else
        info "No .p12 found in $KC"
    fi

    # Raw .keychain-db fallback — add as a separate keychain
    RAW="$KC/login.keychain-db"
    if [ -f "$RAW" ]; then
        warn "Raw login.keychain-db is present (fallback)"
        info "It is encrypted with the OLD Mac's login password."
        if confirm "Mount it as an additional keychain (kept separate from your new login keychain)?"; then
            DEST="$HOME/Library/Keychains/old-mac-login.keychain-db"
            cp "$RAW" "$DEST"
            chmod 600 "$DEST"
            # Add to the user's keychain search list
            CURRENT=$(security list-keychains -d user | sed 's/^[[:space:]]*//; s/"//g' | tr '\n' ' ')
            security list-keychains -d user -s $CURRENT "$DEST" 2>/dev/null || true
            log "Mounted as: $DEST"
            info "Open Keychain Access — you should see 'old-mac-login' in the sidebar."
            info "Unlock it with your OLD Mac's login password, then drag items into 'login'."
            todo "In Keychain Access: unlock 'old-mac-login' and drag items into 'login'"
        else
            todo "Manually add keychain: Keychain Access → File → Add Keychain… → $RAW"
        fi
    fi
else
    info "No keychain/ directory — skipping"
fi

# ── 2. Hidden Config Directories ────────────────────────────────────────────
phase "Hidden Config Directories"
HID="$EXTRAS/hidden-dirs"
if [ -d "$HID" ]; then
    while IFS= read -r src; do
        [ -d "$src" ] || continue
        name=$(basename "$src")
        dst="$HOME/$name"
        if [ -e "$dst" ]; then
            if confirm "$name exists at $dst — overwrite?"; then
                rsync -a "$src/" "$dst/" 2>/dev/null && log "$name (overwritten)"
            else
                info "$name skipped"
            fi
        else
            rsync -a "$src/" "$dst/" 2>/dev/null && log "$name"
        fi
    done < <(find "$HID" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort)
else
    info "No hidden-dirs/ — skipping"
fi

# ── 3. Sandboxed App Data ───────────────────────────────────────────────────
phase "Sandboxed App Data"

restore_sandbox() {
    local label="$1" src="$2" dst_root="$3"
    [ -d "$src/selected" ] || { info "$label: no selected/ data"; return 0; }

    warn "$label: ONLY restore after the corresponding app has been installed"
    warn "         AND launched once on this Mac. Otherwise macOS recreates the"
    warn "         dir with new permissions and your import is overwritten."
    confirm "Continue with $label restore?" || return 0

    local restored=0
    while IFS= read -r d; do
        [ -d "$d" ] || continue
        local name; name=$(basename "$d")
        local dst="$dst_root/$name"

        if [ -e "$dst" ]; then
            if confirm "$name exists — merge in old data (will not delete new files)?"; then
                rsync -a "$d/" "$dst/" 2>/dev/null && log "$name (merged)"
                restored=$((restored + 1))
            fi
        else
            mkdir -p "$dst_root"
            rsync -a "$d/" "$dst/" 2>/dev/null && log "$name (new)"
            restored=$((restored + 1))
        fi
    done < <(find "$src/selected" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort)

    info "$label: restored $restored"
    [ -f "$src/inventory.txt" ] && \
        info "Inventory of skipped (not restored): $src/inventory.txt"
}

restore_sandbox "Group Containers" \
    "$EXTRAS/group-containers" \
    "$HOME/Library/Group Containers"

restore_sandbox "Containers" \
    "$EXTRAS/containers" \
    "$HOME/Library/Containers"

# ── 4. Apple App Data (TCC) ─────────────────────────────────────────────────
phase "Apple App Data (Mail, Messages, Calendars, Safari)"
APPS="$EXTRAS/apple-apps"
if [ -d "$APPS" ]; then
    warn "These dirs are TCC-protected. Terminal needs Full Disk Access to write."
    warn "Also: Mail / Messages should be QUIT before restore."
    confirm "Restore Apple app data?" || true

    for sub in Mail Messages Calendars Safari; do
        src="$APPS/$sub"
        [ -d "$src" ] || continue
        dst="$HOME/Library/$sub"
        if [ -d "$dst" ] && [ "$(ls -A "$dst" 2>/dev/null)" ]; then
            if ! confirm "$dst has data — overwrite?"; then
                info "$sub skipped"
                continue
            fi
        fi
        if rsync -a "$src/" "$dst/" 2>/dev/null; then
            log "$sub"
        else
            warn "$sub failed — likely TCC; grant Full Disk Access and re-run"
            todo "Restore $sub manually: rsync -a \"$src/\" \"$dst/\""
        fi
    done
else
    info "No apple-apps/ — skipping"
fi

# ── 5. Photos Library ───────────────────────────────────────────────────────
phase "Photos Library"
PHOTOS_SRC="$EXTRAS/photos-library/Photos Library.photoslibrary"
if [ -d "$PHOTOS_SRC" ]; then
    DST="$HOME/Pictures/Photos Library.photoslibrary"
    SIZE=$(du -sh "$PHOTOS_SRC" 2>/dev/null | cut -f1)
    warn "This will copy $SIZE to $DST"
    do_restore=false
    if [ -e "$DST" ]; then
        warn "An existing Photos Library is at $DST"
        if confirm "Overwrite it with the backup?"; then
            do_restore=true
            rm -rf "$DST"
        else
            info "Keeping existing library"
        fi
    else
        confirm "Restore Photos Library?" && do_restore=true
    fi
    if $do_restore; then
        rsync -a --progress "$PHOTOS_SRC/" "$DST/" 2>/dev/null
        log "Photos Library restored"
        info "Open Photos.app holding Option to choose this library if needed."
        todo "Open Photos.app and verify library opens / first-launch indexing"
    fi
else
    info "No photos-library/ — skipping"
fi

# ── 6. Creative Apps (Final Cut, Logic) ─────────────────────────────────────
phase "Creative Apps"
CREATIVE="$EXTRAS/creative"
if [ -d "$CREATIVE" ]; then
    # Final Cut bundles → ~/Movies
    if [ -d "$CREATIVE/finalcut" ]; then
        for bundle in "$CREATIVE/finalcut"/*.fcpbundle; do
            [ -d "$bundle" ] || continue
            name=$(basename "$bundle")
            dst="$HOME/Movies/$name"
            if [ -e "$dst" ]; then
                warn "$name exists at $dst — skipping"
                continue
            fi
            if confirm "Restore Final Cut library $name?"; then
                rsync -a --progress "$bundle/" "$dst/" 2>/dev/null && log "$name"
            fi
        done
    fi

    # Logic projects + audio packs → ~/Music
    for pack in logic audio-music-apps; do
        src="$CREATIVE/$pack"
        [ -d "$src" ] || continue
        case "$pack" in
            logic)            dst="$HOME/Music/Logic" ;;
            audio-music-apps) dst="$HOME/Music/Audio Music Apps" ;;
        esac
        if confirm "Restore $pack to $dst?"; then
            mkdir -p "$(dirname "$dst")"
            rsync -a --progress "$src/" "$dst/" 2>/dev/null && log "$pack"
        fi
    done
else
    info "No creative/ — skipping"
fi

# ── 7. System Files ─────────────────────────────────────────────────────────
phase "System Files"
SYS="$EXTRAS/system"
if [ -d "$SYS" ]; then
    # /etc/hosts — diff first, then prompt with sudo
    if [ -f "$SYS/etc-hosts" ]; then
        info "Diff vs current /etc/hosts:"
        diff -u /etc/hosts "$SYS/etc-hosts" | sed 's/^/    /' || true
        if confirm "Apply old /etc/hosts (requires sudo)?"; then
            sudo cp /etc/hosts "/etc/hosts.bak.$(date +%Y%m%d_%H%M%S)" 2>/dev/null || true
            sudo cp "$SYS/etc-hosts" /etc/hosts \
                && log "/etc/hosts updated (backup of original kept as /etc/hosts.bak.*)"
        fi
    fi

    # System Launch* — INVENTORY ONLY, surfaces what to reinstall
    for invfile in _Library_LaunchAgents.txt _Library_LaunchDaemons.txt; do
        [ -f "$SYS/$invfile" ] || continue
        echo ""
        info "System $(basename "$invfile" .txt | sed 's/^_//; s/_/\//g') from old Mac:"
        sed 's/^/    /' "$SYS/$invfile"
        todo "Reinstall apps that ship LaunchAgents/Daemons (see $SYS/$invfile)"
    done
else
    info "No system/ — skipping"
fi

# ── 8. Databases ────────────────────────────────────────────────────────────
phase "Databases"
DBS="$EXTRAS/databases"
if [ -d "$DBS" ]; then
    [ -f "$DBS/brew-services.txt" ] && {
        info "Old Mac's brew services:"
        sed 's/^/    /' "$DBS/brew-services.txt"
    }

    # Postgres
    if [ -f "$DBS/postgres-dumpall.sql" ]; then
        warn "Postgres dump found ($(du -sh "$DBS/postgres-dumpall.sql" | cut -f1))"
        if has psql && pg_isready -q 2>/dev/null; then
            if confirm "Restore Postgres dump now?"; then
                psql -f "$DBS/postgres-dumpall.sql" postgres \
                    && log "Postgres restored"
            fi
        else
            warn "Postgres not running — start it first:"
            warn "  brew services start postgresql && wait, then re-run"
            todo "Restore Postgres: psql -f $DBS/postgres-dumpall.sql postgres"
        fi
    fi

    # MySQL
    if [ -f "$DBS/mysql-dumpall.sql" ]; then
        warn "MySQL dump found ($(du -sh "$DBS/mysql-dumpall.sql" | cut -f1))"
        if has mysql && (mysql -e "SELECT 1" >/dev/null 2>&1); then
            if confirm "Restore MySQL dump now?"; then
                mysql < "$DBS/mysql-dumpall.sql" \
                    && log "MySQL restored"
            fi
        else
            warn "MySQL not running — start it first"
            todo "Restore MySQL: mysql < $DBS/mysql-dumpall.sql"
        fi
    fi

    # Redis
    for rdb in "$DBS"/*.rdb; do
        [ -f "$rdb" ] || continue
        warn "Redis snapshot found: $(basename "$rdb")"
        for var_dir in /opt/homebrew/var/db/redis /usr/local/var/db/redis; do
            [ -d "$var_dir" ] || continue
            if confirm "Copy to $var_dir/$(basename "$rdb")? (Redis must be stopped)"; then
                cp "$rdb" "$var_dir/$(basename "$rdb")" \
                    && log "Redis snapshot placed at $var_dir"
            fi
        done
    done
else
    info "No databases/ — skipping"
fi

# ── 9. Docker ───────────────────────────────────────────────────────────────
phase "Docker"
DOCK="$EXTRAS/docker"
if [ -d "$DOCK" ]; then
    info "Docker images on old Mac:"
    [ -f "$DOCK/images.txt" ] && sed 's/^/    /' "$DOCK/images.txt"
    info "Docker volumes on old Mac:"
    [ -f "$DOCK/volumes.txt" ] && sed 's/^/    /' "$DOCK/volumes.txt"
    todo "Re-pull Docker images and recreate volumes (see $DOCK/)"
else
    info "No docker/ — skipping"
fi

# ── 10. Top-level Loose Files ───────────────────────────────────────────────
phase "Top-level Loose Files"
TOP="$EXTRAS/toplevel"
if [ -d "$TOP" ]; then
    while IFS= read -r entry; do
        name=$(basename "$entry")
        [ "$name" = "skipped.txt" ] && continue
        dst="$HOME/$name"
        if [ -e "$dst" ]; then
            if confirm "$name exists at $dst — overwrite?"; then
                rsync -a "$entry" "$HOME/" 2>/dev/null && log "$name (overwritten)"
            fi
        else
            rsync -a "$entry" "$HOME/" 2>/dev/null && log "$name"
        fi
    done < <(find "$TOP" -mindepth 1 -maxdepth 1 2>/dev/null | sort)
    [ -f "$TOP/skipped.txt" ] && {
        info "Items skipped at backup time (too large):"
        sed 's/^/    /' "$TOP/skipped.txt"
    }
else
    info "No toplevel/ — skipping"
fi

# ── Done ────────────────────────────────────────────────────────────────────
header "Restore Pre-Tradein Extras Complete"
log "Log:  $LOG_FILE"
if [ -s "$MANUAL_TODO" ]; then
    warn "Manual follow-ups:"
    cat "$MANUAL_TODO"
else
    log "Nothing left for manual follow-up."
fi
echo ""
