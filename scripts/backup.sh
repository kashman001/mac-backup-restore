#!/bin/bash
# =============================================================================
# backup.sh — Full Mac backup to an external drive
# Usage: ./scripts/backup.sh /Volumes/MyDrive
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/helpers.sh"

# ── Destination ──────────────────────────────────────────────────────────────
DRIVE="${1:-}"
if [ -z "$DRIVE" ]; then
    err "Usage: ./scripts/backup.sh /Volumes/YourDrive"
    echo "  Available volumes:"
    ls /Volumes/ 2>/dev/null | grep -v "Macintosh HD" | sed 's/^/    /'
    exit 1
fi

if [ ! -d "$DRIVE" ]; then
    err "Drive not found: $DRIVE"
    exit 1
fi

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_DIR="$DRIVE/mac-backup/$TIMESTAMP"
mkdir -p "$BACKUP_DIR"

header "Mac Backup"
info "Destination: $BACKUP_DIR"
AVAIL=$(df -h "$DRIVE" | tail -1 | awk '{print $4}')
info "Available space: $AVAIL"
echo ""
confirm "Start backup?" || exit 0

# ── 1. Software Inventory ───────────────────────────────────────────────────
phase "Software Inventory"
INV="$BACKUP_DIR/software-inventory"
mkdir -p "$INV"

ls /Applications > "$INV/applications.txt" 2>/dev/null && \
    log "Applications list ($(wc -l < "$INV/applications.txt" | tr -d ' ') apps)"

[ -d "$HOME/Applications" ] && \
    ls "$HOME/Applications" > "$INV/user-applications.txt" 2>/dev/null && \
    log "User applications list"

# Homebrew
if has brew; then
    brew bundle dump --file="$INV/Brewfile" --force 2>/dev/null && \
        log "Brewfile ($(grep -c '' "$INV/Brewfile") entries)"
    brew list --formula > "$INV/brew-formulae.txt" 2>/dev/null
    brew list --cask > "$INV/brew-casks.txt" 2>/dev/null
    brew tap > "$INV/brew-taps.txt" 2>/dev/null
    log "Brew formulae, casks, and taps"
else
    warn "Homebrew not found — skipping"
fi

# Mac App Store
if has mas; then
    mas list > "$INV/mac-app-store.txt" 2>/dev/null && log "Mac App Store apps"
else
    warn "mas not installed — run: brew install mas"
fi

# Language-specific package managers
has npm    && npm list -g --depth=0 > "$INV/npm-globals.txt" 2>/dev/null       && log "npm globals"
has pip3   && pip3 list --format=freeze > "$INV/pip3-packages.txt" 2>/dev/null  && log "pip3 packages"
has pipx   && pipx list --json > "$INV/pipx-packages.json" 2>/dev/null         && log "pipx packages"
has cargo  && cargo install --list > "$INV/cargo-packages.txt" 2>/dev/null     && log "Cargo packages"
has gem    && gem list --local > "$INV/ruby-gems.txt" 2>/dev/null              && log "Ruby gems"
has code   && code --list-extensions > "$INV/vscode-extensions.txt" 2>/dev/null && log "VS Code extensions"
has cursor && cursor --list-extensions > "$INV/cursor-extensions.txt" 2>/dev/null && log "Cursor extensions"

[ -d "$HOME/go/bin" ] && ls "$HOME/go/bin" > "$INV/go-binaries.txt" 2>/dev/null && log "Go binaries"

# ── 2. Dotfiles & Config ────────────────────────────────────────────────────
phase "Dotfiles & Config"
CFG="$BACKUP_DIR/config"
mkdir -p "$CFG"/{dotfiles,ssh,gnupg}

# Shell and tool dotfiles
DOTFILES=(
    .zshrc .zshenv .zprofile .zsh_history
    .bashrc .bash_profile .bash_history .profile
    .gitconfig .gitignore_global
    .vimrc .vim .nvim
    .tmux.conf
    .npmrc .yarnrc .yarnrc.yml
    .gemrc .curlrc .wgetrc
    .editorconfig .hushlogin .mackup.cfg
    .tool-versions .python-version .node-version .ruby-version .nvmrc
    .p10k.zsh .starship.toml
)

copied=0
for f in "${DOTFILES[@]}"; do
    if [ -e "$HOME/$f" ]; then
        cp -a "$HOME/$f" "$CFG/dotfiles/" 2>/dev/null && ((copied++))
    fi
done
log "Dotfiles ($copied files)"

# SSH
if [ -d "$HOME/.ssh" ]; then
    cp -a "$HOME/.ssh/"* "$CFG/ssh/" 2>/dev/null && log "SSH keys and config"
    sensitive "SSH keys backed up — keep secure"
fi

# GPG
if has gpg && gpg --list-secret-keys 2>/dev/null | grep -q sec; then
    gpg --export-secret-keys --armor > "$CFG/gnupg/secret-keys.asc" 2>/dev/null
    gpg --export-ownertrust > "$CFG/gnupg/ownertrust.txt" 2>/dev/null
    log "GPG keys"
    sensitive "GPG keys backed up — keep secure"
fi

# ~/.config (skip caches)
if [ -d "$HOME/.config" ]; then
    rsync -a --exclude='*/Cache*' --exclude='*/cache*' --exclude='*/logs/*' \
        --exclude='*/blob_storage/*' --exclude='*/GPUCache/*' \
        "$HOME/.config/" "$CFG/dot-config/" 2>/dev/null
    log "~/.config ($(du -sh "$CFG/dot-config" 2>/dev/null | cut -f1))"
fi

# Cloud/infra credentials
for cred_dir in .aws .kube .docker; do
    if [ -d "$HOME/$cred_dir" ]; then
        cp -a "$HOME/$cred_dir" "$CFG/" 2>/dev/null && log "$cred_dir config"
    fi
done

# ── 3. App Settings ─────────────────────────────────────────────────────────
phase "Application Settings"
APP="$BACKUP_DIR/app-settings"
mkdir -p "$APP"

# VS Code
VSCODE_USER="$HOME/Library/Application Support/Code/User"
if [ -d "$VSCODE_USER" ]; then
    mkdir -p "$APP/vscode"
    for f in settings.json keybindings.json snippets; do
        [ -e "$VSCODE_USER/$f" ] && cp -a "$VSCODE_USER/$f" "$APP/vscode/"
    done
    log "VS Code settings"
fi

# Cursor
CURSOR_USER="$HOME/Library/Application Support/Cursor/User"
if [ -d "$CURSOR_USER" ]; then
    mkdir -p "$APP/cursor"
    for f in settings.json keybindings.json snippets; do
        [ -e "$CURSOR_USER/$f" ] && cp -a "$CURSOR_USER/$f" "$APP/cursor/"
    done
    log "Cursor settings"
fi

# iTerm2
ITERM_PREFS="$HOME/Library/Preferences/com.googlecode.iterm2.plist"
[ -f "$ITERM_PREFS" ] && mkdir -p "$APP/iterm2" && cp "$ITERM_PREFS" "$APP/iterm2/" && log "iTerm2"

# macOS defaults
defaults read > "$APP/macos-defaults-full.txt" 2>/dev/null && log "macOS defaults (full)"

# ── 4. Projects ──────────────────────────────────────────────────────────────
phase "Project Discovery"
PROJ="$BACKUP_DIR/projects"
mkdir -p "$PROJ"

LIST="$PROJ/_project-list.txt"
> "$LIST"

SEARCH_DIRS=(
    "$HOME/Projects" "$HOME/Developer" "$HOME/code" "$HOME/repos"
    "$HOME/src" "$HOME/workspace" "$HOME/dev" "$HOME/work"
    "$HOME/Sites" "$HOME/Documents" "$HOME/Desktop"
)

for d in "${SEARCH_DIRS[@]}"; do
    [ -d "$d" ] && find "$d" -maxdepth 4 -name ".git" -type d 2>/dev/null | \
        while read -r g; do dirname "$g"; done >> "$LIST"
done

sort -u "$LIST" -o "$LIST"
COUNT=$(wc -l < "$LIST" | tr -d ' ')

if [ "$COUNT" -gt 0 ]; then
    log "Found $COUNT projects"
    cat -n "$LIST"
    echo ""
    warn "Projects are backed up WITHOUT node_modules, .venv, build dirs, etc."
    confirm "Back up all projects?" && {
        while IFS= read -r project; do
            [ -d "$project" ] || continue
            rel="${project#$HOME/}"
            dest="$PROJ/$rel"
            mkdir -p "$(dirname "$dest")"
            rsync -a \
                --exclude='node_modules' --exclude='.venv' --exclude='venv' \
                --exclude='__pycache__' --exclude='target' --exclude='build' \
                --exclude='dist' --exclude='.next' --exclude='.nuxt' \
                --exclude='.output' --exclude='*.o' --exclude='*.pyc' \
                --exclude='.gradle' --exclude='.idea' --exclude='.DS_Store' \
                --exclude='Pods' --exclude='DerivedData' --exclude='.cache' \
                "$project/" "$dest/" 2>/dev/null
            log "  $rel"
        done < "$LIST"
    }
else
    info "No projects found"
fi

# ── 5. Personal Files ───────────────────────────────────────────────────────
phase "Personal Files"
FILES="$BACKUP_DIR/files"
mkdir -p "$FILES"

for dir in "$HOME/Documents" "$HOME/Desktop" "$HOME/Downloads" "$HOME/Pictures" "$HOME/Music" "$HOME/Movies"; do
    name=$(basename "$dir")
    [ -d "$dir" ] && [ "$(ls -A "$dir" 2>/dev/null)" ] || continue
    SIZE=$(du -sh "$dir" 2>/dev/null | cut -f1)
    confirm "Back up $name ($SIZE)?" && {
        rsync -a --progress --exclude='.DS_Store' "$dir/" "$FILES/$name/" 2>/dev/null
        log "$name"
    }
done

# ── 6. System ───────────────────────────────────────────────────────────────
phase "System Config"
SYS="$BACKUP_DIR/system"
mkdir -p "$SYS"

crontab -l > "$SYS/crontab.txt" 2>/dev/null && log "Crontab" || info "No crontab"

if [ -d "$HOME/Library/LaunchAgents" ] && [ "$(ls -A "$HOME/Library/LaunchAgents")" ]; then
    cp -a "$HOME/Library/LaunchAgents" "$SYS/LaunchAgents" 2>/dev/null && log "Launch Agents"
fi

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
header "Backup Complete"
TOTAL=$(du -sh "$BACKUP_DIR" 2>/dev/null | cut -f1)
log "Total size: $TOTAL"
log "Location:   $BACKUP_DIR"
echo ""
ls -1 "$BACKUP_DIR" | while read -r item; do
    SIZE=$(du -sh "$BACKUP_DIR/$item" 2>/dev/null | cut -f1)
    printf "  %-8s %s\n" "$SIZE" "$item"
done
echo ""
sensitive "This backup contains SSH keys, GPG keys, and credentials. Keep it secure."
