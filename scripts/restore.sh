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

header "New Mac Setup — Clean Install"
info "Restoring from: $BACKUP"
echo ""

# Track what needs manual attention
MANUAL_TODO="$BACKUP/_manual-todo.txt"
> "$MANUAL_TODO"

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
    echo "    Formulae: $(grep -c '^brew ' "$BREWFILE" 2>/dev/null || echo 0)"
    echo "    Casks:    $(grep -c '^cask ' "$BREWFILE" 2>/dev/null || echo 0)"
    echo "    Taps:     $(grep -c '^tap '  "$BREWFILE" 2>/dev/null || echo 0)"
    echo "    MAS apps: $(grep -c '^mas '  "$BREWFILE" 2>/dev/null || echo 0)"
    echo ""
    confirm "Install from original Brewfile?" && {
        brew bundle --file="$BREWFILE" --no-lock 2>&1 | tail -10
        log "Original Brewfile packages installed"
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
    confirm "Install these via Homebrew? (recommended — cleaner updates)" && {
        brew bundle --file="$BREWFILE_ADDON" --no-lock 2>&1 | tail -10
        log "Addon apps installed via Homebrew"
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
    info "Open JetBrains Toolbox to reinstall PyCharm and other IDEs"
    info "Your settings sync via JetBrains account"

    # Restore PyCharm settings if available
    PYCHARM_SRC="$BACKUP/app-settings/pycharm"
    if [ -d "$PYCHARM_SRC" ]; then
        confirm "Restore PyCharm settings?" && {
            # Find the PyCharm config dir (created after first launch)
            PYCHARM_DEST=$(find "$HOME/Library/Application Support/JetBrains" -maxdepth 1 -name "PyCharm*" -type d 2>/dev/null | sort -V | tail -1)
            if [ -n "$PYCHARM_DEST" ]; then
                rsync -a "$PYCHARM_SRC/" "$PYCHARM_DEST/" 2>/dev/null
                log "PyCharm settings restored"
            else
                warn "PyCharm not yet launched — open it first via JetBrains Toolbox, then re-run"
                echo "  - Restore PyCharm settings after first launch" >> "$MANUAL_TODO"
            fi
        }
    fi
else
    echo "  - Install JetBrains Toolbox: brew install --cask jetbrains-toolbox" >> "$MANUAL_TODO"
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
        echo "  - Reinstall CrossOver games: Blue Prince, Cyberpunk 2077, Frostpunk 2" >> "$MANUAL_TODO"
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
    ls -1 "$DOTFILES_SRC" | grep -v '^_' | sed 's/^/    /'
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
        log "~/.config restored (gh, Zed, Ghostty, etc.)"
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

# ── Step 9: Application Settings ────────────────────────────────────────────
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

        # Install extensions in parallel
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

        # Install Cursor extensions too
        CURSOR_EXT="$BACKUP/software-inventory/cursor-extensions.txt"
        if [ -f "$CURSOR_EXT" ] && has cursor; then
            info "Installing Cursor extensions..."
            while IFS= read -r ext; do
                cursor --install-extension "$ext" --force 2>/dev/null &
            done < "$CURSOR_EXT"
            wait
            log "Cursor extensions installed"
        fi
    }
fi

# Ghostty
GHOSTTY_SRC="$APP_SRC/ghostty"
if [ -d "$GHOSTTY_SRC" ]; then
    confirm "Restore Ghostty config?" && {
        GHOSTTY_DEST="$HOME/Library/Application Support/com.mitchellh.ghostty"
        mkdir -p "$GHOSTTY_DEST"
        cp -a "$GHOSTTY_SRC/"* "$GHOSTTY_DEST/" 2>/dev/null
        log "Ghostty config"
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

# Warp
WARP_SRC="$APP_SRC/warp"
if [ -d "$WARP_SRC" ]; then
    confirm "Restore Warp terminal settings?" && {
        WARP_DEST="$HOME/Library/Application Support/dev.warp.Warp-Stable"
        mkdir -p "$WARP_DEST"
        cp -a "$WARP_SRC/"* "$WARP_DEST/" 2>/dev/null
        log "Warp terminal settings"
    }
fi

# Obsidian
OBSIDIAN_SRC="$APP_SRC/obsidian"
if [ -d "$OBSIDIAN_SRC" ]; then
    confirm "Restore Obsidian config?" && {
        OBSIDIAN_DEST="$HOME/Library/Application Support/obsidian"
        mkdir -p "$OBSIDIAN_DEST"
        cp -a "$OBSIDIAN_SRC/"* "$OBSIDIAN_DEST/" 2>/dev/null
        log "Obsidian config"
    }
fi

# ── Step 10: Browser Extensions & App Plugins ──────────────────────────────
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

# ── Step 11: Screenshots → ~/Pictures/Screenshots/YYYY/MM/ ──────────────────
phase "Screenshots"

SCREENSHOTS_SRC="$BACKUP/files/Screenshots"
if [ -d "$SCREENSHOTS_SRC" ] && [ "$(find "$SCREENSHOTS_SRC" -type f 2>/dev/null | head -1)" ]; then
    SCREENSHOT_COUNT=$(find "$SCREENSHOTS_SRC" -type f -name "*.png" 2>/dev/null | wc -l | tr -d ' ')
    info "Found $SCREENSHOT_COUNT screenshots organized by date in backup:"
    find "$SCREENSHOTS_SRC" -mindepth 2 -maxdepth 2 -type d 2>/dev/null | sort | while read -r ym; do
        count=$(find "$ym" -type f 2>/dev/null | wc -l | tr -d ' ')
        rel="${ym#$SCREENSHOTS_SRC/}"
        log "  $rel: $count screenshots"
    done
    echo ""
    confirm "Restore screenshots to ~/Pictures/Screenshots/?" && {
        rsync -a "$SCREENSHOTS_SRC/" "$HOME/Pictures/Screenshots/" 2>/dev/null
        log "Screenshots restored to ~/Pictures/Screenshots/"
        info "macOS is already configured to save new screenshots here"
    }
else
    info "No screenshots found in backup"
fi

# ── Step 12: Projects → ~/Developer/ ────────────────────────────────────────
phase "Projects → Clean Layout"

PROJ_SRC="$BACKUP/projects"
if [ -d "$PROJ_SRC" ] && [ "$(ls -A "$PROJ_SRC" 2>/dev/null | grep -v '^_')" ]; then
    info "Projects from your old Mac will be reorganized into ~/Developer/"
    info ""
    info "On the old Mac, projects were scattered across:"

    # Show where projects came from
    LIST="$PROJ_SRC/_project-list.txt"
    if [ -f "$LIST" ]; then
        cat "$LIST" | sed "s|$HOME/||" | cut -d/ -f1 | sort | uniq -c | sort -rn | \
            sed 's/^/    /'
        echo ""
    fi

    info "They'll all go into ~/Developer/personal/ for now."
    info "After restore, sort them into work/ or oss/ as needed."
    echo ""

    confirm "Restore projects to ~/Developer/?" && {
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
        done
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

# ── Step 13: Personal Files ──────────────────────────────────────────────────
phase "Personal Files"

info "Note: if you sign into iCloud, Documents and Desktop will sync automatically."
info "Restoring from backup is useful for files that weren't in iCloud."
echo ""

FILES_SRC="$BACKUP/files"
if [ -d "$FILES_SRC" ]; then
    for dir in "$FILES_SRC"/*/; do
        [ -d "$dir" ] || continue
        name=$(basename "$dir")
        # Screenshots already handled in Step 10
        [ "$name" = "Screenshots" ] && continue
        SIZE=$(du -sh "$dir" 2>/dev/null | cut -f1)
        confirm "Restore $name ($SIZE)?" && {
            rsync -a "$dir" "$HOME/$name/" 2>/dev/null
            log "$name restored"
        }
    done
fi

# ── Step 14: Anaconda / Conda Environments ───────────────────────────────────
phase "Python & Conda"

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
        grep -E '├──|└──' "$NPM_FILE" | awk '{print $2}' | cut -d@ -f1 | \
            xargs -I{} npm install -g {} 2>/dev/null
        log "npm globals installed"
    }
fi

# ── Step 15: System Config ───────────────────────────────────────────────────
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
fi

info "Recommended next steps:"
echo "    1. Sign into Apple ID → iCloud → let Documents/Desktop sync"
echo "    2. Sign into the App Store → redownload purchased apps"
echo "    3. Open browsers and sign in to sync bookmarks/passwords"
echo "    4. Test SSH: ssh -T git@github.com"
echo "    5. Open Steam → sign in → redownload games"
echo "    6. Sort ~/Developer/personal/ into work/ and oss/"
echo "    7. Open JetBrains Toolbox → install PyCharm"
echo "    8. Run ./scripts/verify.sh to check everything"
echo ""
info "Directory layout:"
echo "    ~/Developer/personal/    — your personal projects"
echo "    ~/Developer/work/        — work projects"
echo "    ~/Developer/oss/         — open source contributions"
echo "    ~/Developer/experiments/ — throwaway experiments"
echo "    ~/Pictures/Screenshots/  — macOS screenshot destination"
echo ""
