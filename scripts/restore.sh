#!/bin/bash
# =============================================================================
# restore.sh — Set up a clean, organized Mac from an organic backup
#
# Strategy: install everything possible via Homebrew (even if it was
# originally installed via .dmg or .pkg), organize files into a clean
# directory layout, and flag anything that needs manual attention.
#
# Directory layout on the new Mac:
#
#   ~/
#   ├── Developer/              ← all code, grouped by context
#   │   ├── personal/
#   │   ├── work/
#   │   └── oss/
#   ├── Documents/              ← synced to iCloud
#   ├── Desktop/                ← kept clean
#   ├── Pictures/Screenshots/   ← screenshot destination
#   ├── .config/                ← XDG-style configs
#   └── .ssh/                   ← SSH keys
#
# Usage: ./scripts/restore.sh /Volumes/MyDrive/mac-backup/20260415_120000
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/helpers.sh"

# ── Load user-customizable config ───────────────────────────────────────────
CONFIG_DIR="$REPO_DIR/config"
[ -f "$CONFIG_DIR/app-settings.sh" ]       && source "$CONFIG_DIR/app-settings.sh"
[ -f "$CONFIG_DIR/migration-patterns.sh" ] && source "$CONFIG_DIR/migration-patterns.sh"

# Ensure arrays exist even if config files are missing
declare -a APP_SETTINGS 2>/dev/null || true
declare -a SIGN_IN_APPS 2>/dev/null || true
declare -a JETBRAINS_IDES 2>/dev/null || true
declare -a JETBRAINS_SUBDIRS 2>/dev/null || true
[ ${#JETBRAINS_SUBDIRS[@]} -eq 0 ] && JETBRAINS_SUBDIRS=(codestyles colors inspection keymaps options templates)

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

# Tee everything to a log file so failures (especially in long phases like
# brew bundle) can be post-mortemed without scrollback hunting. Append so
# repeated runs build up a history; banner separates each run.
LOG_FILE="$HOME/.mac-restore.log"
exec > >(tee -a "$LOG_FILE") 2>&1
echo "=== mac-restore: $(date) — backup: $BACKUP ==="

header "New Mac Setup — Clean Install"
info "Restoring from: $BACKUP"
info "Logging to:     $LOG_FILE"
echo ""

# Track what needs manual attention (write to HOME, not the backup drive)
MANUAL_TODO="$HOME/.mac-restore-todo.txt"
> "$MANUAL_TODO"

# Pre-flight reminder for things `brew bundle` can't satisfy on a fresh Mac:
# VSCode extensions need the `code` CLI on PATH, and MAS apps need the user
# signed into the App Store. Detecting these up-front turns a confusing
# post-failure hunt into a one-time checklist.
preflight_for_brewfile() {
    local brewfile="$1"
    [ -f "$brewfile" ] || return 0
    local vscode_count mas_count
    vscode_count=$(grep -c '^vscode ' "$brewfile" 2>/dev/null || true)
    mas_count=$(grep -c    '^mas '    "$brewfile" 2>/dev/null || true)
    : "${vscode_count:=0}"; : "${mas_count:=0}"

    local printed=0
    if [ "$vscode_count" -gt 0 ] && ! has code; then
        warn "First-run prerequisites detected:"
        echo "    • $vscode_count VSCode extension(s) in this Brewfile, but the 'code' CLI is not on PATH."
        echo "      Open Visual Studio Code, then Cmd+Shift+P → 'Shell Command: Install code command in PATH'."
        printed=1
    fi
    if [ "$mas_count" -gt 0 ]; then
        [ "$printed" -eq 0 ] && warn "First-run prerequisites detected:"
        echo "    • $mas_count Mac App Store app(s) in this Brewfile."
        echo "      Open the App Store and sign in with the same Apple ID used on the old Mac."
        printed=1
    fi
    [ "$printed" -eq 1 ] && echo ""
    return 0
}

# ── Step 0: macOS Preferences ───────────────────────────────────────────────
phase "macOS Preferences"
info "Applying sensible defaults..."

confirm "Apply recommended macOS settings?" && {
    # Finder: show extensions, path bar, status bar, full POSIX path in title
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

    # Screenshots: save to ~/Pictures/Screenshots (not Desktop)
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

# ── Step 1: Directory Structure ──────────────────────────────────────────────
phase "Directory Structure"
info "Creating organized layout..."

mkdir -p "$HOME/Developer"/{personal,work,oss,experiments}
mkdir -p "$HOME/Pictures/Screenshots"

log "Created ~/Developer/ with context-based subdirectories:"
log "  ~/Developer/personal/    — side projects, personal tools"
log "  ~/Developer/work/        — employer/client projects"
log "  ~/Developer/oss/         — open source contributions"
log "  ~/Developer/experiments/ — throwaway spikes and tests"

# ── Step 2: Homebrew — Install Everything Possible via Brew ──────────────────
phase "Homebrew (Package Manager)"

if ! has brew; then
    info "Installing Homebrew..."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

    # Add to PATH for Apple Silicon
    if [ -f /opt/homebrew/bin/brew ]; then
        eval "$(/opt/homebrew/bin/brew shellenv)"
        # Persist in shell config
        echo '' >> "$HOME/.zprofile"
        echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> "$HOME/.zprofile"
    fi
    log "Homebrew installed"
else
    log "Homebrew already installed"
fi

# Install from the original Brewfile (things that were already in Brew)
BREWFILE="$BACKUP/software-inventory/Brewfile"
if [ -f "$BREWFILE" ]; then
    info "Original Brewfile: $(grep -c '' "$BREWFILE") entries"
    # `|| true` (not `|| echo 0`): grep -c already prints "0" on no-match before
    # exiting 1, so `|| echo 0` would print a spurious second "0" line.
    echo "    Formulae: $(grep -c '^brew ' "$BREWFILE" 2>/dev/null || true)"
    echo "    Casks:    $(grep -c '^cask ' "$BREWFILE" 2>/dev/null || true)"
    echo "    Taps:     $(grep -c '^tap '  "$BREWFILE" 2>/dev/null || true)"
    echo "    MAS apps: $(grep -c '^mas '  "$BREWFILE" 2>/dev/null || true)"
    echo ""
    preflight_for_brewfile "$BREWFILE"
    confirm "Install from original Brewfile?" && {
        if brew bundle --file="$BREWFILE"; then
            log "Original Brewfile packages installed"
        else
            warn "brew bundle reported unsatisfied dependencies (full output in $LOG_FILE)"
            warn "Continuing with restore — handle them and re-run brew bundle later"
            echo "  - Re-run: brew bundle install --file=\"$BREWFILE\"" >> "$MANUAL_TODO"
        fi
    }
fi

# Install the addon Brewfile (apps that WERE manual but CAN be Brew casks)
BREWFILE_ADDON="$BACKUP/software-inventory/Brewfile.addon"
if [ -f "$BREWFILE_ADDON" ] && [ -s "$BREWFILE_ADDON" ]; then
    echo ""
    info "Brewfile.addon: $(wc -l < "$BREWFILE_ADDON" | tr -d ' ') apps to migrate to Homebrew"
    info "These were installed manually on the old Mac but have Brew casks:"
    cat "$BREWFILE_ADDON" | sed 's/^/    /'
    echo ""
    preflight_for_brewfile "$BREWFILE_ADDON"
    confirm "Install these via Homebrew? (recommended — cleaner updates)" && {
        if brew bundle --file="$BREWFILE_ADDON"; then
            log "Addon apps installed via Homebrew"
        else
            warn "brew bundle reported unsatisfied addon dependencies (full output in $LOG_FILE)"
            warn "Continuing with restore — handle them and re-run brew bundle later"
            echo "  - Re-run: brew bundle install --file=\"$BREWFILE_ADDON\"" >> "$MANUAL_TODO"
        fi
    }
fi

# ── Step 3: Mac App Store Apps ───────────────────────────────────────────────
phase "Mac App Store"

# Install mas if not present (needed for MAS installs)
if ! has mas; then
    brew install mas 2>/dev/null && log "mas CLI installed"
fi

MAS_FILE="$BACKUP/software-inventory/mac-app-store.txt"
if [ -f "$MAS_FILE" ] && has mas; then
    info "Mac App Store apps from backup:"
    cat "$MAS_FILE" | sed 's/^/    /'
    echo ""
    info "Make sure you're signed into the App Store first"
    confirm "Reinstall Mac App Store apps?" && {
        while IFS= read -r line; do
            appid=$(echo "$line" | awk '{print $1}')
            appname=$(echo "$line" | cut -d' ' -f2-)
            mas install "$appid" 2>/dev/null && log "  $appname" || \
                warn "  Failed: $appname (may need manual install from App Store)"
        done < "$MAS_FILE"
    }
else
    info "No Mac App Store list found — check App Store → Purchased for your apps"
    echo "    Apps like Final Cut Pro, Logic Pro, Keynote, etc. are there" >> "$MANUAL_TODO"
fi

# ── Step 4: Apps That Need Manual Install ────────────────────────────────────
phase "Manual Install Check"

SOURCES="$BACKUP/software-inventory/install-sources.txt"
if [ -f "$SOURCES" ]; then
    # Find apps that couldn't be handled by Brew or MAS
    MANUAL_APPS=$(grep '^manual ' "$SOURCES" 2>/dev/null | grep -v '→brew' || true)
    if [ -n "$MANUAL_APPS" ]; then
        warn "These apps need manual download/install:"
        echo "$MANUAL_APPS" | while IFS='|' read -r source app rest; do
            app=$(echo "$app" | xargs)
            echo "    $app"
            echo "  - Download and install: $app" >> "$MANUAL_TODO"
        done
        echo ""
        info "Most can be found by searching their name + 'mac download'"
    else
        log "All apps covered by Homebrew and Mac App Store"
    fi
fi

# ── Step 5: Docker Desktop ──────────────────────────────────────────────────
phase "Docker & Containers"

if has docker; then
    log "Docker already installed (via Homebrew)"
    info "Docker Desktop installs docker, docker-compose, and kubectl automatically"
    info "No need to install these separately"
else
    info "Docker not found — install with: brew install --cask docker"
    echo "  - Install Docker Desktop: brew install --cask docker" >> "$MANUAL_TODO"
fi

# ── Step 6: JetBrains ───────────────────────────────────────────────────────
phase "JetBrains IDEs"

if [ -d "/Applications/JetBrains Toolbox.app" ]; then
    log "JetBrains Toolbox installed"
    info "Open JetBrains Toolbox to reinstall your IDEs"
    info "IDE settings are restored in Step 9 (Application Settings)"
    info "Settings also sync via JetBrains account"
else
    # Check if any JetBrains IDE settings exist in backup
    HAS_JB_SETTINGS=false
    for ide_entry in "${JETBRAINS_IDES[@]}"; do
        IFS='|' read -r ide_name ide_prefix <<< "$ide_entry"
        ide_subdir=$(echo "$ide_name" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')
        [ -d "$BACKUP/app-settings/$ide_subdir" ] && HAS_JB_SETTINGS=true && break
    done
    if $HAS_JB_SETTINGS; then
        info "JetBrains IDE settings found in backup but Toolbox not installed"
        echo "  - Install JetBrains Toolbox: brew install --cask jetbrains-toolbox" >> "$MANUAL_TODO"
    fi
fi

# ── Step 7: Steam & Games ───────────────────────────────────────────────────
phase "Steam & Games"

STEAM_GAMES="$BACKUP/software-inventory/steam/installed-games.txt"
CROSSOVER_GAMES="$BACKUP/software-inventory/steam/crossover-games.txt"

if [ -f "$STEAM_GAMES" ] && [ -s "$STEAM_GAMES" ]; then
    info "Steam games from old Mac (native macOS):"
    while IFS='|' read -r appid name size; do
        name=$(echo "$name" | xargs)
        size=$(echo "$size" | xargs)
        log "  $name ($size) — steam://install/$(echo "$appid" | xargs)"
    done < "$STEAM_GAMES"
    echo ""
    info "After installing Steam, sign in and redownload these games"
fi

if [ -f "$CROSSOVER_GAMES" ] && [ -s "$CROSSOVER_GAMES" ]; then
    echo ""
    info "CrossOver/Steam games (Windows games via CrossOver):"
    while IFS='|' read -r appid name rest; do
        name=$(echo "$name" | xargs)
        log "  $name (App ID: $(echo "$appid" | xargs))"
    done < "$CROSSOVER_GAMES"
    echo ""
    warn "These require CrossOver + Steam for Windows to be set up"

    # Restore CrossOver bottles if backed up
    BOTTLES_SRC="$BACKUP/crossover"
    if [ -d "$BOTTLES_SRC" ]; then
        confirm "Restore CrossOver bottles? (saves redownloading games)" && {
            BOTTLES_DEST="$HOME/Library/Application Support/CrossOver/Bottles"
            mkdir -p "$BOTTLES_DEST"
            rsync -a --progress "$BOTTLES_SRC/" "$BOTTLES_DEST/" 2>/dev/null
            log "CrossOver bottles restored"
        }
    else
        info "CrossOver bottles were not backed up"
        info "You'll need to reinstall games through CrossOver after setup"
        echo "  - Reinstall CrossOver games (see backup's crossover-games.txt for list)" >> "$MANUAL_TODO"
    fi
fi

if [ ! -f "$STEAM_GAMES" ] && [ ! -f "$CROSSOVER_GAMES" ]; then
    info "No Steam game data found in backup"
fi

# ── Step 8: Dotfiles & Config ───────────────────────────────────────────────
phase "Dotfiles & Config"

DOTFILES_SRC="$BACKUP/config/dotfiles"
if [ -d "$DOTFILES_SRC" ]; then
    info "Found backed-up dotfiles:"
    # `|| true` — grep -v exits 1 if every entry begins with `_` (manifest only); pipefail would kill the script
    ls -1 "$DOTFILES_SRC" | grep -v '^_' | sed 's/^/    /' || true
    echo ""
    confirm "Restore dotfiles to home directory?" && {
        for f in "$DOTFILES_SRC"/.*  "$DOTFILES_SRC"/*; do
            [ -e "$f" ] || continue
            name=$(basename "$f")
            [ "$name" = "." ] || [ "$name" = ".." ] || [ "$name" = "_manifest.txt" ] && continue
            if [ -e "$HOME/$name" ]; then
                cp -a "$HOME/$name" "$HOME/${name}.pre-restore" 2>/dev/null
            fi
            cp -a "$f" "$HOME/$name" 2>/dev/null
        done
        log "Dotfiles restored"
    }
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
            mkdir -p "$HOME/$cred_dir"
            rsync -a "$SRC/" "$HOME/$cred_dir/" 2>/dev/null
            log "$cred_dir config restored"
        }
    fi
done

# ── Step 9: Application Settings ────────────────────────────────────────────
phase "Application Settings"

APP_SRC="$BACKUP/app-settings"

# Config-driven app settings restore (loaded from config/app-settings.sh)
for entry in "${APP_SETTINGS[@]}"; do
    IFS='|' read -r name src_path backup_subdir files_to_copy <<< "$entry"
    SRC="$APP_SRC/$backup_subdir"
    [ -d "$SRC" ] || [ -f "$SRC" ] || continue

    DEST="$HOME/$src_path"
    confirm "Restore $name settings?" && {
        if [ -d "$SRC" ]; then
            mkdir -p "$DEST"
            cp -a "$SRC/"* "$DEST/" 2>/dev/null
        else
            mkdir -p "$(dirname "$DEST")"
            cp -a "$SRC" "$DEST" 2>/dev/null
        fi
        log "$name settings"
    }
done

# JetBrains IDEs (restore settings to matching version directories)
if [ -d "$HOME/Library/Application Support/JetBrains" ]; then
    for ide_entry in "${JETBRAINS_IDES[@]}"; do
        IFS='|' read -r ide_name ide_prefix <<< "$ide_entry"
        ide_subdir=$(echo "$ide_name" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')
        IDE_SRC="$APP_SRC/$ide_subdir"
        [ -d "$IDE_SRC" ] || continue

        confirm "Restore $ide_name settings?" && {
            IDE_DEST=$(find "$HOME/Library/Application Support/JetBrains" -maxdepth 1 -name "${ide_prefix}*" -type d 2>/dev/null | sort -V | tail -1)
            if [ -n "$IDE_DEST" ]; then
                rsync -a "$IDE_SRC/" "$IDE_DEST/" 2>/dev/null
                log "$ide_name settings restored"
            else
                warn "$ide_name not yet launched — open it first, then re-run"
                echo "  - Restore $ide_name settings after first launch" >> "$MANUAL_TODO"
            fi
        }
    done
fi

# Install VS Code / Cursor extensions from backup lists (in parallel)
for editor in code cursor; do
    EXT_FILE="$BACKUP/software-inventory/${editor}-extensions.txt"
    [ "$editor" = "code" ] && EXT_FILE="$BACKUP/software-inventory/vscode-extensions.txt"
    if [ -f "$EXT_FILE" ] && has "$editor"; then
        EXT_COUNT=$(wc -l < "$EXT_FILE" | tr -d ' ')
        info "Installing $EXT_COUNT $editor extensions..."
        while IFS= read -r ext; do
            "$editor" --install-extension "$ext" --force 2>/dev/null &
        done < "$EXT_FILE"
        wait
        log "$editor extensions installed"
    fi
done

# ── Step 10: License Keys & Activation ──────────────────────────────────────
phase "License Keys & Activation"

LIC_SRC="$BACKUP/licenses/plists"
if [ -d "$LIC_SRC" ] && [ "$(ls -A "$LIC_SRC" 2>/dev/null)" ]; then
    info "License plists from backup (these contain serial numbers / activation data):"
    for plist in "$LIC_SRC"/*.plist; do
        [ -f "$plist" ] || continue
        bundle_id=$(basename "$plist" .plist)
        echo "    $bundle_id"
    done
    echo ""
    confirm "Restore license plists to ~/Library/Preferences/?" && {
        for plist in "$LIC_SRC"/*.plist; do
            [ -f "$plist" ] || continue
            bundle_id=$(basename "$plist" .plist)
            cp "$plist" "$HOME/Library/Preferences/" 2>/dev/null && \
                log "  $bundle_id"
        done
        info "Apps should auto-activate when launched. If not, re-enter your license key."
    }
else
    info "No license plists found in backup"
fi

# Show migration manifest if available
MANIFEST="$BACKUP/migration-manifest.txt"
if [ -f "$MANIFEST" ]; then
    echo ""
    info "Migration manifest available at: $MANIFEST"
    info "It classifies every app by what it needs (sign-in, config, license, etc.)"
fi

# ── Step 11: Browser Extensions & App Plugins ──────────────────────────────
phase "Browser Extensions & App Plugins"

BROWSER_EXT="$BACKUP/software-inventory/browser-extensions"
if [ -d "$BROWSER_EXT" ] && [ "$(ls -A "$BROWSER_EXT" 2>/dev/null)" ]; then
    info "Browser extensions from your old Mac:"
    echo ""
    for ext_file in "$BROWSER_EXT"/*-extensions.txt; do
        [ -f "$ext_file" ] || continue
        browser=$(basename "$ext_file" -extensions.txt | sed 's/-/ /g; s/\b\(.\)/\u\1/g')
        count=$(wc -l < "$ext_file" | tr -d ' ')
        info "$browser ($count extensions):"
        while IFS='|' read -r eid name version; do
            name=$(echo "$name" | xargs)
            [ -n "$name" ] && echo "    $name"
        done < "$ext_file"
        echo ""
    done
    warn "Browser extensions cannot be installed automatically."
    info "Sign into each browser to sync extensions, or reinstall from the lists above."
    info "Extension lists saved at: $BROWSER_EXT/"
    echo "  - Reinstall browser extensions (see $BROWSER_EXT/)" >> "$MANUAL_TODO"
else
    info "No browser extension data found in backup"
fi

APP_PLUGINS="$BACKUP/software-inventory/app-plugins"
if [ -d "$APP_PLUGINS" ] && [ "$(ls -A "$APP_PLUGINS" 2>/dev/null)" ]; then
    echo ""
    info "Application plugins from your old Mac:"

    # PyCharm / JetBrains plugins
    for plugin_file in "$APP_PLUGINS"/*-plugins.txt; do
        [ -f "$plugin_file" ] || continue
        ide_name=$(basename "$plugin_file" -plugins.txt)
        count=$(wc -l < "$plugin_file" | tr -d ' ')
        info "$ide_name plugins ($count):"
        cat "$plugin_file" | sed 's/^/    /'
        echo ""
    done

    # Obsidian vault plugins
    if [ -d "$APP_PLUGINS/obsidian" ]; then
        for vault_file in "$APP_PLUGINS/obsidian"/*-plugins.txt; do
            [ -f "$vault_file" ] || continue
            vault_name=$(basename "$vault_file" -plugins.txt)
            count=$(wc -l < "$vault_file" | tr -d ' ')
            info "Obsidian vault '$vault_name' plugins ($count):"
            cat "$vault_file" | sed 's/^/    /'
            echo ""
        done
        info "Obsidian community plugins will be restored with your vault data"
    fi

    warn "JetBrains plugins: open Settings → Plugins in each IDE to reinstall"
    echo "  - Reinstall JetBrains IDE plugins (see plugin lists in backup)" >> "$MANUAL_TODO"
fi

# ── Step 12: Screenshots → ~/Pictures/Screenshots/YYYY/MM/ ──────────────────
phase "Screenshots"

SCREENSHOTS_SRC="$BACKUP/files/Screenshots"
if [ -d "$SCREENSHOTS_SRC" ] && [ "$(find "$SCREENSHOTS_SRC" -type f 2>/dev/null | head -1)" ]; then
    SCREENSHOT_COUNT=$(find "$SCREENSHOTS_SRC" -type f -name "*.png" 2>/dev/null | wc -l | tr -d ' ')
    info "Found $SCREENSHOT_COUNT screenshots organized by date in backup:"
    find "$SCREENSHOTS_SRC" -mindepth 2 -maxdepth 2 -type d 2>/dev/null | sort | while read -r ym; do
        count=$(find "$ym" -type f 2>/dev/null | wc -l | tr -d ' ')
        rel="${ym#$SCREENSHOTS_SRC/}"
        log "  $rel: $count screenshots"
    done || true
    echo ""
    confirm "Restore screenshots to ~/Pictures/Screenshots/?" && {
        rsync -a "$SCREENSHOTS_SRC/" "$HOME/Pictures/Screenshots/" 2>/dev/null
        log "Screenshots restored to ~/Pictures/Screenshots/"
        info "macOS is already configured to save new screenshots here"
    }
else
    info "No screenshots found in backup"
fi

# ── Step 13: Projects → ~/Developer/ ────────────────────────────────────────
phase "Projects → Clean Layout"

PROJ_SRC="$BACKUP/projects"
if [ -d "$PROJ_SRC" ] && [ "$(ls -A "$PROJ_SRC" 2>/dev/null | grep -v '^_')" ]; then
    info "Projects from your old Mac will be reorganized into ~/Developer/"
    info ""
    info "On the old Mac, projects were scattered across:"

    # Show where projects came from (detect old home dir from paths)
    LIST="$PROJ_SRC/_project-list.txt"
    if [ -f "$LIST" ]; then
        # Strip any /Users/<name>/ prefix (handles username changes between machines)
        sed 's|^/Users/[^/]*/||; s|^/home/[^/]*/||' "$LIST" | \
            cut -d/ -f1 | sort | uniq -c | sort -rn | sed 's/^/    /'
        echo ""
    fi

    info "They'll all go into ~/Developer/personal/ for now."
    info "After restore, sort them into work/ or oss/ as needed."
    echo ""

    confirm "Restore projects to ~/Developer/?" && {
        # `|| true` — find on a backup tree can exit non-zero on perm/xattr quirks; pipefail would abort restore
        find "$PROJ_SRC" -maxdepth 4 -name ".git" -type d 2>/dev/null | while read -r gitdir; do
            project=$(dirname "$gitdir")
            name=$(basename "$project")
            dest="$HOME/Developer/personal/$name"

            if [ -d "$dest" ]; then
                warn "Skipping $name — already exists"
            else
                rsync -a "$project/" "$dest/" 2>/dev/null
                log "  $name → ~/Developer/personal/$name"
            fi
        done || true
        echo ""
        log "Projects consolidated into ~/Developer/personal/"
    }

    # Flag orphan code files
    ORPHANS="$PROJ_SRC/_orphan-code-files.txt"
    if [ -f "$ORPHANS" ] && [ -s "$ORPHANS" ]; then
        echo ""
        warn "Orphan code files found (not in any git repo):"
        head -15 "$ORPHANS" | sed 's/^/    /'
        TOTAL=$(wc -l < "$ORPHANS" | tr -d ' ')
        [ "$TOTAL" -gt 15 ] && info "  ... and more (see _orphan-code-files.txt)"
        info "These will be in your Documents/Desktop backup if you restored personal files"
    fi
else
    info "No projects found in backup"
fi

# ── Step 14: Personal Files (classified by data type) ───────────────────────
phase "Personal Files"

FILES_SRC="$BACKUP/files"

# Show data classification if available
DATA_CLASS="$FILES_SRC/_data-classification.txt"
if [ -f "$DATA_CLASS" ]; then
    echo ""
    info "Your backup classified data into categories:"
    echo ""

    # Show stale data (multi-machine sync artifacts)
    STALE_COUNT=$(grep -c "^STALE" "$DATA_CLASS" 2>/dev/null || true)
    if [ "$STALE_COUNT" -gt 0 ]; then
        warn "Stale data (old device sync artifacts):"
        grep "^STALE" "$DATA_CLASS" | while IFS='|' read -r tag name size; do
            name=$(echo "$name" | xargs)
            size=$(echo "$size" | xargs)
            echo "    $name ($size)"
        done
        info "  Recommendation: skip these. They're from old Macs and will clutter the new one."
        echo ""
    fi

    # Show archival data
    ARCHIVAL_COUNT=$(grep -c "^ARCHIVAL" "$DATA_CLASS" 2>/dev/null || true)
    if [ "$ARCHIVAL_COUNT" -gt 0 ]; then
        warn "Archival data (large, rarely accessed):"
        grep "^ARCHIVAL" "$DATA_CLASS" | while IFS='|' read -r tag name size note; do
            name=$(echo "$name" | xargs)
            size=$(echo "$size" | xargs)
            note=$(echo "$note" | xargs)
            echo "    $name ($size) — $note"
        done
        info "  Recommendation: keep on external drive or move to cloud storage."
        echo ""
    fi

    # Show app-generated data
    APP_DATA_COUNT=$(grep -c "^APP-DATA" "$DATA_CLASS" 2>/dev/null || true)
    if [ "$APP_DATA_COUNT" -gt 0 ]; then
        info "App-generated data:"
        grep "^APP-DATA" "$DATA_CLASS" | while IFS='|' read -r tag name size note; do
            name=$(echo "$name" | xargs)
            size=$(echo "$size" | xargs)
            echo "    $name ($size)"
        done
        info "  These directories are created by specific apps — restore only if the app is installed."
        echo ""
    fi

    # Show cloud-synced data — already restoring via account sign-in
    CLOUD_COUNT=$(grep -c "^CLOUD-SYNCED" "$DATA_CLASS" 2>/dev/null || true)
    if [ "$CLOUD_COUNT" -gt 0 ]; then
        info "☁ Cloud-synced sources present in backup but skipped by default:"
        grep "^CLOUD-SYNCED" "$DATA_CLASS" | while IFS='|' read -r tag name size note; do
            name=$(echo "$name" | xargs)
            size=$(echo "$size" | xargs)
            note=$(echo "$note" | xargs)
            echo "    $name ($size) — $note"
        done || true
        info "  These will re-sync from iCloud after you sign in (preferred)."
        info "  To copy from the backup drive instead, re-run with:"
        info "    MBR_RESTORE_CLOUD=1 bash <restore-command>"
        echo ""
    fi
fi

# iCloud sync advisory
info "If you sign into iCloud, Documents and Desktop will sync automatically."
info "Restoring from backup is insurance for files that weren't in iCloud."
echo ""

if [ -d "$FILES_SRC" ]; then
    # Restore scattered credentials first (most important)
    CREDS_SRC="$FILES_SRC/scattered-credentials"
    if [ -d "$CREDS_SRC" ] && [ -f "$CREDS_SRC/_found.txt" ] && [ -s "$CREDS_SRC/_found.txt" ]; then
        warn "Scattered credential files found in backup:"
        cat "$CREDS_SRC/_found.txt" | sed 's/^/    /'
        echo ""
        confirm "Restore these credential files to their original locations?" && {
            while IFS= read -r rel; do
                [ -n "$rel" ] || continue
                src="$CREDS_SRC/$rel"
                dest="$HOME/$rel"
                [ -f "$src" ] || continue
                mkdir -p "$(dirname "$dest")"
                cp -a "$src" "$dest" 2>/dev/null
            done < "$CREDS_SRC/_found.txt"
            log "Scattered credentials restored"
            sensitive "Review these files and rotate any exposed secrets"
        }
    fi

    # Restore auth tokens
    AUTH_SRC="$FILES_SRC/auth-tokens"
    if [ -d "$AUTH_SRC" ] && [ "$(ls -A "$AUTH_SRC" 2>/dev/null)" ]; then
        info "Auth tokens from backup:"
        find "$AUTH_SRC" -type f -not -name '.*' 2>/dev/null | sed "s|$AUTH_SRC/||" | sed 's/^/    /'
        confirm "Restore auth tokens (GitHub CLI, Sourcery, etc.)?" && {
            # GitHub CLI
            if [ -f "$AUTH_SRC/gh/hosts.yml" ]; then
                mkdir -p "$HOME/.config/gh"
                cp "$AUTH_SRC/gh/hosts.yml" "$HOME/.config/gh/" 2>/dev/null
                chmod 600 "$HOME/.config/gh/hosts.yml" 2>/dev/null
                log "GitHub CLI auth restored"
            fi
            # Sourcery
            if [ -f "$AUTH_SRC/sourcery/auth.yaml" ]; then
                mkdir -p "$HOME/.config/sourcery"
                cp "$AUTH_SRC/sourcery/auth.yaml" "$HOME/.config/sourcery/" 2>/dev/null
                chmod 600 "$HOME/.config/sourcery/auth.yaml" 2>/dev/null
                log "Sourcery auth restored"
            fi
        }
    fi

    # Restore loose photos from Desktop to ~/Pictures/
    DESKTOP_SRC="$FILES_SRC/Desktop"
    if [ -d "$DESKTOP_SRC" ]; then
        PHOTO_COUNT=$(find "$DESKTOP_SRC" -maxdepth 1 -type f \( -iname "*.jpg" -o -iname "*.jpeg" -o -iname "*.heic" -o -iname "*.raw" -o -iname "*.cr2" -o -iname "*.arw" \) 2>/dev/null | wc -l | tr -d ' ')
        if [ "$PHOTO_COUNT" -gt 0 ]; then
            info "Found $PHOTO_COUNT loose photos on the old Desktop"
            confirm "Move these to ~/Pictures/ instead of Desktop? (keeps Desktop clean)" && {
                mkdir -p "$HOME/Pictures/Imported"
                # `|| true` — find can exit non-zero on perm/xattr quirks; pipefail would abort restore mid-step
                find "$DESKTOP_SRC" -maxdepth 1 -type f \( -iname "*.jpg" -o -iname "*.jpeg" -o -iname "*.heic" -o -iname "*.raw" -o -iname "*.cr2" -o -iname "*.arw" \) 2>/dev/null | while read -r photo; do
                    cp -a "$photo" "$HOME/Pictures/Imported/" 2>/dev/null
                done || true
                log "Photos moved to ~/Pictures/Imported/"
            }
        fi
    fi

    echo ""

    # Restore remaining personal files (skip already-handled items)
    for dir in "$FILES_SRC"/*/; do
        [ -d "$dir" ] || continue
        name=$(basename "$dir")
        # Skip items handled in other steps
        case "$name" in
            Screenshots|scattered-credentials|auth-tokens) continue ;;
        esac
        # Skip items the backup classified as CLOUD-SYNCED unless user opted in.
        # The grep pattern anchors on the exact column-2 value "<name>/ |" so
        # that a Branch-2 row like "Pictures/Photos Library.photoslibrary/"
        # does NOT cause the "Pictures" parent to be skipped (C1 regression fix).
        if [ -f "$DATA_CLASS" ] \
           && [ "${MBR_RESTORE_CLOUD:-}" != "1" ] \
           && grep -q "^CLOUD-SYNCED *| *${name}/ *|" "$DATA_CLASS" 2>/dev/null; then
            info "  ☁ skipping $name — cloud-synced (re-syncs from iCloud)"
            continue
        fi
        SIZE=$(du -sh "$dir" 2>/dev/null | cut -f1)

        # Special handling for Documents — warn about stale/archival subdirs
        if [ "$name" = "Documents" ] && [ -f "$DATA_CLASS" ]; then
            HAS_STALE=$(grep "^STALE\|^ARCHIVAL" "$DATA_CLASS" 2>/dev/null | head -1 || true)
            if [ -n "$HAS_STALE" ]; then
                warn "Documents ($SIZE) contains stale/archival data (see classification above)"
                confirm "Restore Documents? (you can skip stale subdirs after)" && {
                    rsync -a "$dir" "$HOME/$name/" 2>/dev/null
                    log "$name restored"
                    info "Consider removing old sync artifacts from ~/Documents/ after review"
                }
                continue
            fi
        fi

        confirm "Restore $name ($SIZE)?" && {
            rsync -a "$dir" "$HOME/$name/" 2>/dev/null
            log "$name restored"
        }
    done
fi

# ── Step 15: Anaconda / Conda Environments ───────────────────────────────────
phase "Language Package Managers"

CONDA_ENVS="$BACKUP/software-inventory/conda-envs"
if [ -d "$CONDA_ENVS" ] && [ "$(ls -A "$CONDA_ENVS")" ]; then
    info "Conda environments from backup:"
    ls -1 "$CONDA_ENVS" | sed 's/.yml$//' | sed 's/^/    /'
    echo ""

    if has conda; then
        confirm "Recreate conda environments?" && {
            for yml in "$CONDA_ENVS"/*.yml; do
                [ -f "$yml" ] || continue
                env_name=$(basename "$yml" .yml)
                info "Creating conda env: $env_name"
                conda env create -f "$yml" 2>/dev/null && \
                    log "  $env_name" || warn "  Failed: $env_name"
            done
        }
    else
        warn "conda not in PATH"
        info "After Anaconda is installed, run:"
        echo "    eval \"\$(conda shell.zsh hook)\""
        echo "    conda env create -f $CONDA_ENVS/<name>.yml"
        echo "  - Restore conda environments after Anaconda setup" >> "$MANUAL_TODO"
    fi
fi

# npm globals
NPM_FILE="$BACKUP/software-inventory/npm-globals.txt"
if [ -f "$NPM_FILE" ] && has npm; then
    info "npm global packages from backup"
    confirm "Reinstall npm global packages?" && {
        # Filter to valid npm package name characters before passing to xargs to
        # prevent injection from a tampered backup file.
        grep -E '├──|└──' "$NPM_FILE" | awk '{print $2}' | cut -d@ -f1 | \
            grep -E '^(@[a-zA-Z0-9_-]+/)?[a-zA-Z0-9][a-zA-Z0-9_.-]*$' | \
            xargs -I{} npm install -g {} 2>/dev/null
        log "npm globals installed"
    }
fi

# pip3 packages (user-installed only)
PIP_FILE="$BACKUP/software-inventory/pip3-packages.txt"
if [ -f "$PIP_FILE" ] && has pip3; then
    PIP_COUNT=$(wc -l < "$PIP_FILE" | tr -d ' ')
    info "pip3 packages from backup ($PIP_COUNT packages)"
    info "  Recommendation: use virtual environments instead of global pip install"
    confirm "Reinstall pip3 packages globally?" && {
        pip3 install --break-system-packages -r "$PIP_FILE" 2>/dev/null || \
            pip3 install -r "$PIP_FILE" 2>/dev/null
        log "pip3 packages installed"
    }
fi

# pipx packages (isolated CLI tools)
PIPX_FILE="$BACKUP/software-inventory/pipx-packages.json"
if [ -f "$PIPX_FILE" ] && has pipx; then
    info "pipx packages from backup:"
    # Pass the file path via an env var (not interpolated into the script string)
    # to prevent injection if the backup path contains special characters.
    PYPIPX="$PIPX_FILE" python3 -c '
import json, os
data = json.load(open(os.environ["PYPIPX"]))
for pkg in data.get("venvs", {}):
    print(f"    {pkg}")
' 2>/dev/null
    confirm "Reinstall pipx packages?" && {
        PYPIPX="$PIPX_FILE" python3 -c '
import json, os
data = json.load(open(os.environ["PYPIPX"]))
for pkg in data.get("venvs", {}):
    print(pkg)
' 2>/dev/null | while read -r pkg; do
            pipx install "$pkg" 2>/dev/null && log "  $pkg" || warn "  Failed: $pkg"
        done
    }
elif [ -f "$PIPX_FILE" ]; then
    info "pipx packages found in backup but pipx not installed"
    info "  Install with: brew install pipx && pipx ensurepath"
fi

# Cargo packages (Rust)
CARGO_FILE="$BACKUP/software-inventory/cargo-packages.txt"
if [ -f "$CARGO_FILE" ] && has cargo; then
    CARGO_COUNT=$(grep -c '^[a-z]' "$CARGO_FILE" 2>/dev/null || true)
    info "Cargo packages from backup ($CARGO_COUNT packages)"
    confirm "Reinstall Cargo packages?" && {
        grep '^[a-z]' "$CARGO_FILE" | awk '{print $1}' | sed 's/:$//' | while read -r pkg; do
            cargo install "$pkg" 2>/dev/null && log "  $pkg" || warn "  Failed: $pkg"
        done || true
    }
fi

# Ruby gems
GEM_FILE="$BACKUP/software-inventory/ruby-gems.txt"
if [ -f "$GEM_FILE" ] && has gem; then
    GEM_COUNT=$(wc -l < "$GEM_FILE" | tr -d ' ')
    info "Ruby gems from backup ($GEM_COUNT gems)"
    info "  Note: system gems are managed by macOS — only user gems will be reinstalled"
    confirm "Reinstall Ruby gems?" && {
        while IFS= read -r line; do
            name=$(echo "$line" | awk '{print $1}')
            [ -z "$name" ] && continue
            gem install "$name" 2>/dev/null
        done < "$GEM_FILE"
        log "Ruby gems installed"
    }
fi

# ── Step 16: System Config ───────────────────────────────────────────────────
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

# ── Summary ──────────────────────────────────────────────────────────────────
header "Setup Complete"

echo ""
log "Your new Mac is ready!"
echo ""

# Show manual TODO if anything accumulated
if [ -s "$MANUAL_TODO" ]; then
    warn "Manual steps still needed:"
    cat "$MANUAL_TODO" | sed 's/^/    /'
    echo ""
    info "  Saved to: $MANUAL_TODO"
fi

info "Full session log: $LOG_FILE"
info "  View with colors: less -R $LOG_FILE"
echo ""

info "What the restore script handled automatically:"
echo "    ✓ Homebrew packages and casks (including migrated manual installs)"
echo "    ✓ Mac App Store apps"
echo "    ✓ Dotfiles, SSH keys, GPG keys, cloud credentials"
echo "    ✓ App settings (from config/app-settings.sh)"
echo "    ✓ License plists for registered apps"
echo "    ✓ Projects → ~/Developer/"
echo "    ✓ Screenshots → ~/Pictures/Screenshots/"
echo "    ✓ Conda environments, npm/pip/pipx/cargo/gem packages"
echo ""

info "Sign-in apps — open each and log into your account:"
echo "    1. Apple ID → System Settings → sign in → iCloud syncs Documents/Desktop"
echo "    2. App Store → sign in → redownload purchased apps"
# Dynamically list sign-in apps that are actually installed
STEP_NUM=3
for app in "${SIGN_IN_APPS[@]}"; do
    if [ -d "/Applications/${app}.app" ]; then
        printf "    %d. %s → sign in\n" "$STEP_NUM" "$app"
        ((STEP_NUM++))
    fi
done
# Always remind about browsers for extension sync
echo "    $STEP_NUM. Browsers → sign in → extensions sync automatically"
((STEP_NUM++))
echo ""

info "Verify and organize:"
printf "   %d. Test SSH: ssh -T git@github.com\n" "$STEP_NUM"; ((STEP_NUM++))
printf "   %d. Sort ~/Developer/personal/ into work/ and oss/\n" "$STEP_NUM"; ((STEP_NUM++))
printf "   %d. Launch license-key apps to confirm activation\n" "$STEP_NUM"; ((STEP_NUM++))
printf "   %d. Run ./scripts/verify.sh to check everything\n" "$STEP_NUM"
echo ""

if [ -f "$BACKUP/migration-manifest.txt" ]; then
    info "Full migration manifest: $BACKUP/migration-manifest.txt"
    info "  Lists every app and exactly what it needs (sign-in, config, license, etc.)"
    echo ""
fi

info "Directory layout:"
echo "    ~/Developer/personal/    — your personal projects"
echo "    ~/Developer/work/        — work projects"
echo "    ~/Developer/oss/         — open source contributions"
echo "    ~/Developer/experiments/ — throwaway experiments"
echo "    ~/Pictures/Screenshots/  — macOS screenshot destination"
echo ""
