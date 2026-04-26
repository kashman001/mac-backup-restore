#!/bin/bash
# =============================================================================
# restore-oh-my-zsh.sh — Restore ONLY the oh-my-zsh sub-step from a backup
#
# Use this when the main restore.sh has already run on the new Mac (so
# dotfiles, SSH, brew, etc. are already in place) and you only need to
# add oh-my-zsh customizations on top — without re-running the full restore.
#
# Mirrors the oh-my-zsh block in scripts/restore.sh exactly, so output and
# behavior are identical.
#
# Usage: ./scripts/restore-oh-my-zsh.sh /Volumes/YourDrive/mac-backup/<TIMESTAMP>
# =============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/helpers.sh"

BACKUP="${1:-}"
if [ -z "$BACKUP" ] || [ ! -d "$BACKUP" ]; then
    err "Usage: ./scripts/restore-oh-my-zsh.sh /Volumes/YourDrive/mac-backup/<TIMESTAMP>"
    if [ -d "${1:-}/mac-backup" ]; then
        echo "  Available backups:"
        ls -1 "$1/mac-backup" 2>/dev/null | sed 's/^/    /'
    fi
    exit 1
fi

header "oh-my-zsh restore (standalone)"
info "Restoring from: $BACKUP"
echo ""

OMZ_SRC="$BACKUP/config/oh-my-zsh"
OMZ_HAS_MANIFEST=0
OMZ_HAS_LOOSE=0
[ -f "$OMZ_SRC/manifest.txt" ] && [ -s "$OMZ_SRC/manifest.txt" ] && OMZ_HAS_MANIFEST=1
[ -d "$OMZ_SRC/custom" ] && [ -n "$(ls -A "$OMZ_SRC/custom" 2>/dev/null)" ] && OMZ_HAS_LOOSE=1

if [ "$OMZ_HAS_MANIFEST" != 1 ] && [ "$OMZ_HAS_LOOSE" != 1 ]; then
    warn "No oh-my-zsh data in this backup at $OMZ_SRC"
    info "Nothing to restore. Exiting."
    exit 0
fi

info "oh-my-zsh customizations from backup detected"
[ "$OMZ_HAS_MANIFEST" = 1 ] && \
    info "  $(wc -l < "$OMZ_SRC/manifest.txt" | tr -d ' ') git-managed plugin(s)/theme(s) to re-clone"
[ "$OMZ_HAS_LOOSE" = 1 ] && \
    info "  loose customizations: $(find "$OMZ_SRC/custom" -type f 2>/dev/null | wc -l | tr -d ' ') file(s)"

confirm "Restore oh-my-zsh and customizations?" && {
    if [ ! -d "$HOME/.oh-my-zsh" ]; then
        info "Installing oh-my-zsh (unattended, keeps existing .zshrc)..."
        RUNZSH=no KEEP_ZSHRC=yes \
            sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended --keep-zshrc \
            >/dev/null 2>&1 \
            && log "oh-my-zsh installed" \
            || warn "oh-my-zsh install script failed — manual install may be needed"
    else
        log "oh-my-zsh already installed"
    fi

    if [ "$OMZ_HAS_MANIFEST" = 1 ] && [ -d "$HOME/.oh-my-zsh" ]; then
        while IFS='|' read -r kind name url; do
            [ -n "$kind" ] && [ -n "$name" ] && [ -n "$url" ] || continue
            dest="$HOME/.oh-my-zsh/custom/$kind/$name"
            if [ -d "$dest" ]; then
                log "  $kind/$name already present"
            else
                git clone --depth=1 "$url" "$dest" 2>/dev/null \
                    && log "  cloned $kind/$name" \
                    || warn "  failed to clone $kind/$name from $url"
            fi
        done < "$OMZ_SRC/manifest.txt"
    fi

    if [ "$OMZ_HAS_LOOSE" = 1 ] && [ -d "$HOME/.oh-my-zsh" ]; then
        rsync -a "$OMZ_SRC/custom/" "$HOME/.oh-my-zsh/custom/" 2>/dev/null
        log "Loose oh-my-zsh customizations restored"
    fi

    echo ""
    log "Done. Open a new terminal (or run 'exec zsh') to pick up changes."
}
