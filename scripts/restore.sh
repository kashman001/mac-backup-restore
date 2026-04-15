#!/bin/bash
# =============================================================================
# restore.sh — Set up a new Mac from a backup on an external drive
#
# Best-practice directory layout on the new Mac:
#
#   ~/
#   ├── Developer/          ← all code projects, grouped by context
#   │   ├── personal/
#   │   ├── work/
#   │   └── oss/
#   ├── Documents/          ← personal documents, synced to iCloud
#   ├── Desktop/            ← kept clean, transient items only
#   ├── Downloads/          ← cleared regularly
#   ├── Pictures/
#   ├── Music/
#   ├── .config/            ← XDG-style app configs
#   └── .ssh/               ← SSH keys
#
# Usage: ./scripts/restore.sh /Volumes/MyDrive/mac-backup/20260415_120000
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/helpers.sh"

# ── Validate backup path ────────────────────────────────────────────────────
BACKUP="${1:-}"
if [ -z "$BACKUP" ] || [ ! -d "$BACKUP" ]; then
    err "Usage: ./scripts/restore.sh /Volumes/YourDrive/mac-backup/<timestamp>"
    if [ -d "${1:-}/mac-backup" ]; then
        echo "  Available backups:"
        ls -1 "$1/mac-backup" 2>/dev/null | sed 's/^/    /'
    fi
    exit 1
fi

header "New Mac Setup"
info "Restoring from: $BACKUP"
echo ""

# ── Step 0: macOS preferences ───────────────────────────────────────────────
phase "macOS Preferences"
info "Applying sensible defaults..."

confirm "Apply recommended macOS settings?" && {
    # Finder: show extensions, path bar, status bar
    defaults write com.apple.finder AppleShowAllExtensions -bool true
    defaults write com.apple.finder ShowPathbar -bool true
    defaults write com.apple.finder ShowStatusBar -bool true
    defaults write com.apple.finder _FXShowPosixPathInTitle -bool true

    # Finder: search current folder by default
    defaults write com.apple.finder FXDefaultSearchScope -string "SCcf"

    # Finder: disable warning when changing extension
    defaults write com.apple.finder FXEnableExtensionChangeWarning -bool false

    # Dock: auto-hide, smaller icons, don't rearrange spaces
    defaults write com.apple.dock autohide -bool true
    defaults write com.apple.dock tilesize -int 48
    defaults write com.apple.dock mru-spaces -bool false

    # Trackpad: tap to click
    defaults write com.apple.driver.AppleBluetoothMultitouch.trackpad Clicking -bool true

    # Keyboard: fast key repeat
    defaults write NSGlobalDomain KeyRepeat -int 2
    defaults write NSGlobalDomain InitialKeyRepeat -int 15

    # Screenshots: save to ~/Pictures/Screenshots
    mkdir -p "$HOME/Pictures/Screenshots"
    defaults write com.apple.screencapture location -string "$HOME/Pictures/Screenshots"

    # Disable .DS_Store on network and USB volumes
    defaults write com.apple.desktopservices DSDontWriteNetworkStores -bool true
    defaults write com.apple.desktopservices DSDontWriteUSBStores -bool true

    # Show ~/Library
    chflags nohidden ~/Library

    # Restart affected apps
    killall Finder Dock 2>/dev/null || true

    log "macOS preferences applied"
}

# ── Step 1: Directory structure ──────────────────────────────────────────────
phase "Directory Structure"
info "Creating organized directory layout..."

# Developer directory with context-based grouping
mkdir -p "$HOME/Developer"/{personal,work,oss,experiments}
mkdir -p "$HOME/Pictures/Screenshots"

log "~/Developer/personal   — your personal projects"
log "~/Developer/work       — work/employer projects"
log "~/Developer/oss        — open source contributions"
log "~/Developer/experiments — throwaway experiments"
log "~/Pictures/Screenshots — screenshot destination"

# ── Step 2: Homebrew ─────────────────────────────────────────────────────────
phase "Homebrew"

if ! has brew; then
    info "Installing Homebrew..."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

    # Add to PATH for Apple Silicon
    if [ -f /opt/homebrew/bin/brew ]; then
        eval "$(/opt/homebrew/bin/brew shellenv)"
    fi
    log "Homebrew installed"
else
    log "Homebrew already installed"
fi

BREWFILE="$BACKUP/software-inventory/Brewfile"
if [ -f "$BREWFILE" ]; then
    info "Brewfile found with $(grep -c '' "$BREWFILE") entries"
    echo ""
    info "Categories:"
    echo "    Formulae: $(grep -c '^brew ' "$BREWFILE" 2>/dev/null || echo 0)"
    echo "    Casks:    $(grep -c '^cask ' "$BREWFILE" 2>/dev/null || echo 0)"
    echo "    Taps:     $(grep -c '^tap '  "$BREWFILE" 2>/dev/null || echo 0)"
    echo "    MAS apps: $(grep -c '^mas '  "$BREWFILE" 2>/dev/null || echo 0)"
    echo ""
    confirm "Install all packages from Brewfile?" && {
        brew bundle --file="$BREWFILE" --no-lock 2>&1 | tail -5
        log "Homebrew packages installed"
    }
else
    warn "No Brewfile found in backup"
fi

# ── Step 3: Dotfiles & Config ───────────────────────────────────────────────
phase "Dotfiles & Config"

DOTFILES_SRC="$BACKUP/config/dotfiles"
if [ -d "$DOTFILES_SRC" ]; then
    info "Found backed-up dotfiles:"
    ls -1 "$DOTFILES_SRC" | sed 's/^/    /'
    echo ""
    confirm "Restore dotfiles to home directory?" && {
        for f in "$DOTFILES_SRC"/.*  "$DOTFILES_SRC"/*; do
            [ -e "$f" ] || continue
            name=$(basename "$f")
            [ "$name" = "." ] || [ "$name" = ".." ] && continue
            if [ -e "$HOME/$name" ]; then
                # Back up existing before overwriting
                cp -a "$HOME/$name" "$HOME/${name}.pre-restore" 2>/dev/null
            fi
            cp -a "$f" "$HOME/$name" 2>/dev/null
        done
        log "Dotfiles restored"
    }
else
    warn "No dotfiles found in backup"
fi

# SSH keys
SSH_SRC="$BACKUP/config/ssh"
if [ -d "$SSH_SRC" ] && [ "$(ls -A "$SSH_SRC")" ]; then
    confirm "Restore SSH keys?" && {
        mkdir -p "$HOME/.ssh"
        cp -a "$SSH_SRC/"* "$HOME/.ssh/" 2>/dev/null
        chmod 700 "$HOME/.ssh"
        chmod 600 "$HOME/.ssh/"* 2>/dev/null
        chmod 644 "$HOME/.ssh/"*.pub 2>/dev/null
        chmod 644 "$HOME/.ssh/known_hosts" 2>/dev/null
        chmod 644 "$HOME/.ssh/config" 2>/dev/null
        log "SSH keys restored with correct permissions"
    }
fi

# GPG keys
GPG_SRC="$BACKUP/config/gnupg"
if [ -f "$GPG_SRC/secret-keys.asc" ]; then
    confirm "Restore GPG keys?" && {
        gpg --import "$GPG_SRC/secret-keys.asc" 2>/dev/null
        [ -f "$GPG_SRC/ownertrust.txt" ] && \
            gpg --import-ownertrust "$GPG_SRC/ownertrust.txt" 2>/dev/null
        log "GPG keys restored"
    }
fi

# ~/.config
DOT_CONFIG_SRC="$BACKUP/config/dot-config"
if [ -d "$DOT_CONFIG_SRC" ]; then
    confirm "Restore ~/.config directory?" && {
        rsync -a "$DOT_CONFIG_SRC/" "$HOME/.config/" 2>/dev/null
        log "~/.config restored"
    }
fi

# Cloud/infra configs
for cred_dir in .aws .kube .docker; do
    SRC="$BACKUP/config/$cred_dir"
    if [ -d "$SRC" ]; then
        confirm "Restore $cred_dir config?" && {
            cp -a "$SRC" "$HOME/$cred_dir" 2>/dev/null
            log "$cred_dir config restored"
        }
    fi
done

# ── Step 4: App Settings ────────────────────────────────────────────────────
phase "Application Settings"

APP_SRC="$BACKUP/app-settings"

# VS Code
VSCODE_SRC="$APP_SRC/vscode"
if [ -d "$VSCODE_SRC" ]; then
    VSCODE_DEST="$HOME/Library/Application Support/Code/User"
    confirm "Restore VS Code settings?" && {
        mkdir -p "$VSCODE_DEST"
        cp -a "$VSCODE_SRC/"* "$VSCODE_DEST/" 2>/dev/null
        log "VS Code settings"

        # Restore extensions
        EXT_FILE="$BACKUP/software-inventory/vscode-extensions.txt"
        if [ -f "$EXT_FILE" ] && has code; then
            info "Installing $(wc -l < "$EXT_FILE" | tr -d ' ') VS Code extensions..."
            while IFS= read -r ext; do
                code --install-extension "$ext" --force 2>/dev/null &
            done < "$EXT_FILE"
            wait
            log "VS Code extensions installed"
        fi
    }
fi

# Cursor
CURSOR_SRC="$APP_SRC/cursor"
if [ -d "$CURSOR_SRC" ]; then
    CURSOR_DEST="$HOME/Library/Application Support/Cursor/User"
    confirm "Restore Cursor settings?" && {
        mkdir -p "$CURSOR_DEST"
        cp -a "$CURSOR_SRC/"* "$CURSOR_DEST/" 2>/dev/null
        log "Cursor settings"
    }
fi

# iTerm2
ITERM_SRC="$APP_SRC/iterm2/com.googlecode.iterm2.plist"
if [ -f "$ITERM_SRC" ]; then
    confirm "Restore iTerm2 preferences?" && {
        cp "$ITERM_SRC" "$HOME/Library/Preferences/" 2>/dev/null
        log "iTerm2 preferences"
    }
fi

# ── Step 5: Projects ────────────────────────────────────────────────────────
phase "Projects"

PROJ_SRC="$BACKUP/projects"
if [ -d "$PROJ_SRC" ] && [ "$(ls -A "$PROJ_SRC")" ]; then
    info "Backed-up projects will be reorganized into ~/Developer/"
    info "Suggested layout:"
    echo "    ~/Developer/personal/ — personal projects"
    echo "    ~/Developer/work/     — work projects"
    echo "    ~/Developer/oss/      — open source"
    echo ""

    LIST="$PROJ_SRC/_project-list.txt"
    if [ -f "$LIST" ]; then
        PROJECT_COUNT=$(wc -l < "$LIST" | tr -d ' ')
        info "Found $PROJECT_COUNT projects in backup"
    fi

    confirm "Restore projects to ~/Developer/?" && {
        # Flatten projects into ~/Developer, preserving structure after first level
        # e.g. backup/projects/Documents/myapp → ~/Developer/personal/myapp
        find "$PROJ_SRC" -maxdepth 3 -name ".git" -type d 2>/dev/null | while read -r gitdir; do
            project=$(dirname "$gitdir")
            name=$(basename "$project")
            dest="$HOME/Developer/personal/$name"

            if [ -d "$dest" ]; then
                warn "Skipping $name — already exists at $dest"
            else
                rsync -a "$project/" "$dest/" 2>/dev/null
                log "  $name → ~/Developer/personal/$name"
            fi
        done
        echo ""
        info "Projects restored to ~/Developer/personal/"
        info "Move them to work/ or oss/ as needed"
    }
else
    info "No projects found in backup"
fi

# ── Step 6: Personal Files ──────────────────────────────────────────────────
phase "Personal Files"

FILES_SRC="$BACKUP/files"
if [ -d "$FILES_SRC" ]; then
    for dir in "$FILES_SRC"/*/; do
        [ -d "$dir" ] || continue
        name=$(basename "$dir")
        SIZE=$(du -sh "$dir" 2>/dev/null | cut -f1)
        confirm "Restore $name ($SIZE)?" && {
            rsync -a "$dir" "$HOME/$name/" 2>/dev/null
            log "$name restored"
        }
    done
fi

# ── Step 7: System Config ───────────────────────────────────────────────────
phase "System Config"

SYS_SRC="$BACKUP/system"

if [ -f "$SYS_SRC/crontab.txt" ] && [ -s "$SYS_SRC/crontab.txt" ]; then
    info "Found crontab:"
    cat "$SYS_SRC/crontab.txt" | head -10
    confirm "Restore crontab?" && {
        crontab "$SYS_SRC/crontab.txt" 2>/dev/null
        log "Crontab restored"
    }
fi

if [ -d "$SYS_SRC/LaunchAgents" ]; then
    confirm "Restore Launch Agents?" && {
        mkdir -p "$HOME/Library/LaunchAgents"
        cp -a "$SYS_SRC/LaunchAgents/"* "$HOME/Library/LaunchAgents/" 2>/dev/null
        log "Launch Agents restored"
    }
fi

# ── Step 8: Language Package Managers ────────────────────────────────────────
phase "Language Packages"

# npm globals
NPM_FILE="$BACKUP/software-inventory/npm-globals.txt"
if [ -f "$NPM_FILE" ] && has npm; then
    info "Found npm global packages"
    confirm "Reinstall npm global packages?" && {
        grep -E '├──|└──' "$NPM_FILE" | awk '{print $2}' | cut -d@ -f1 | \
            xargs -I{} npm install -g {} 2>/dev/null
        log "npm globals installed"
    }
fi

# pip packages
PIP_FILE="$BACKUP/software-inventory/pip3-packages.txt"
if [ -f "$PIP_FILE" ] && has pip3; then
    info "Found $(wc -l < "$PIP_FILE" | tr -d ' ') pip packages"
    warn "Consider using a virtualenv instead of global installs"
    confirm "Reinstall pip packages globally?" && {
        pip3 install --break-system-packages -r "$PIP_FILE" 2>/dev/null
        log "pip packages installed"
    }
fi

# ── Summary ──────────────────────────────────────────────────────────────────
header "Setup Complete"

echo ""
log "Your new Mac is ready!"
echo ""
info "Recommended next steps:"
echo "    1. Open System Settings → Apple ID → sign into iCloud"
echo "    2. Open System Settings → Keyboard → adjust to your preference"
echo "    3. Launch your browser and sign in to sync bookmarks/passwords"
echo "    4. Test your SSH keys: ssh -T git@github.com"
echo "    5. Organize ~/Developer/personal into work/oss as needed"
echo "    6. Review ~/Developer/ and reclone any repos that need a fresh start"
echo ""
info "Directory layout:"
echo "    ~/Developer/personal/    — your personal projects"
echo "    ~/Developer/work/        — work projects"
echo "    ~/Developer/oss/         — open source contributions"
echo "    ~/Developer/experiments/ — throwaway experiments"
echo "    ~/Pictures/Screenshots/  — screenshots"
echo ""
