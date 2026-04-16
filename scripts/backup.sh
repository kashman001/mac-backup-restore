#!/bin/bash
# =============================================================================
# backup.sh — Full Mac backup to an external drive
#
# Assumes an organic/adhoc setup: software installed via Homebrew, Mac App
# Store, direct downloads, standalone .pkg installers, JetBrains Toolbox,
# Docker Desktop, CrossOver, etc. Scans everything and classifies it so the
# restore script can reinstall cleanly via Homebrew where possible.
#
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

# ── 1. Complete Software Inventory ──────────────────────────────────────────
phase "Software Inventory"
INV="$BACKUP_DIR/software-inventory"
mkdir -p "$INV"

# ── 1a. Applications (/Applications and ~/Applications)
ls -1 /Applications > "$INV/applications.txt" 2>/dev/null && \
    log "Applications list ($(wc -l < "$INV/applications.txt" | tr -d ' ') apps)"

[ -d "$HOME/Applications" ] && \
    ls -1 "$HOME/Applications" > "$INV/user-applications.txt" 2>/dev/null && \
    log "User applications list"

# ── 1b. Homebrew (formulae, casks, taps)
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

# ── 1c. Mac App Store
if has mas; then
    mas list > "$INV/mac-app-store.txt" 2>/dev/null && log "Mac App Store apps"
else
    warn "mas not installed — run: brew install mas"
    info "  (needed to capture Mac App Store apps like Final Cut Pro, Logic Pro)"
fi

# ── 1d. Classify apps: what came from Brew, MAS, or manual install
#    This is the key step for an organic setup — we figure out where
#    each app came from so restore can use Brew for as many as possible.
info "Classifying application install sources..."
BREW_CASKS=""
if has brew; then
    BREW_CASKS=$(brew list --cask 2>/dev/null)
fi
MAS_APPS=""
if has mas; then
    MAS_APPS=$(mas list 2>/dev/null | awk '{print $1}')
fi

CLASSIFY="$INV/install-sources.txt"
{
    echo "# Application Install Source Classification"
    echo "# Generated: $(date)"
    echo "# Format: SOURCE | APP NAME | BREW CASK NAME (if available)"
    echo "#"
    echo "# Sources: brew-cask, mas, manual-download, standalone-pkg, bundled"
    echo "# ────────────────────────────────────────────────────────────────"
    echo ""
} > "$CLASSIFY"

# Known brew cask mappings for common apps
declare -A CASK_MAP=(
    ["1Password.app"]="1password"
    ["Anaconda-Navigator.app"]="anaconda"
    ["Arc.app"]="arc"
    ["BBEdit.app"]="bbedit"
    ["Bartender 5.app"]="bartender"
    ["ChatGPT.app"]="chatgpt"
    ["Claude.app"]="claude"
    ["Codex.app"]="codex"
    ["CrossOver.app"]="crossover"
    ["Cursor.app"]="cursor"
    ["Docker.app"]="docker"
    ["Gemini 2.app"]="gemini"
    ["Ghostty.app"]="ghostty"
    ["GitKraken.app"]="gitkraken"
    ["Google Chrome.app"]="google-chrome"
    ["JetBrains Toolbox.app"]="jetbrains-toolbox"
    ["Microsoft Excel.app"]="microsoft-excel"
    ["Microsoft OneNote.app"]="microsoft-onenote"
    ["Microsoft Outlook.app"]="microsoft-outlook"
    ["Microsoft PowerPoint.app"]="microsoft-powerpoint"
    ["Microsoft Teams.app"]="microsoft-teams"
    ["Microsoft Word.app"]="microsoft-word"
    ["Obsidian.app"]="obsidian"
    ["OneDrive.app"]="onedrive"
    ["Opera.app"]="opera"
    ["Perplexity.app"]="perplexity"
    ["PyCharm.app"]="pycharm"
    ["Shottr.app"]="shottr"
    ["Sourcetree.app"]="sourcetree"
    ["Steam.app"]="steam"
    ["TG Pro.app"]="tg-pro"
    ["TextSniper.app"]="textsniper"
    ["TigerVNC.app"]="tigervnc-viewer"
    ["Visual Studio Code.app"]="visual-studio-code"
    ["Warp.app"]="warp"
    ["WhatsApp.app"]="whatsapp"
    ["Wondershare UniConverter 16.app"]="wondershare-uniconverter"
    ["Zed.app"]="zed"
    ["draw.io.app"]="drawio"
    ["iStat Menus.app"]="istat-menus"
    ["iTerm.app"]="iterm2"
    ["logioptionsplus.app"]="logitech-options-plus"
)

# Apple bundled apps (skip in restore — they come with macOS)
BUNDLED_APPS="Compressor.app|Final Cut Pro.app|GarageBand.app|iMovie.app|Keynote.app|Logic Pro.app|MainStage.app|Motion.app|Numbers.app|Pages.app|Safari.app|Utilities"

# Generate Brewfile-addons for apps not currently in Homebrew
BREWFILE_ADDON="$INV/Brewfile.addon"
> "$BREWFILE_ADDON"

while IFS= read -r app; do
    [ -z "$app" ] && continue

    if echo "$app" | grep -qE "^($BUNDLED_APPS)$"; then
        echo "mas-or-bundled | $app" >> "$CLASSIFY"
    elif echo "$BREW_CASKS" | grep -qw "${CASK_MAP[$app]:-__NOMATCH__}" 2>/dev/null; then
        echo "brew-cask      | $app | ${CASK_MAP[$app]}" >> "$CLASSIFY"
    elif [ -n "${CASK_MAP[$app]:-}" ]; then
        # We know the cask name but it wasn't installed via brew — add to addon
        echo "manual (→brew)  | $app | ${CASK_MAP[$app]}" >> "$CLASSIFY"
        echo "cask \"${CASK_MAP[$app]}\"" >> "$BREWFILE_ADDON"
    elif echo "$app" | grep -q "Microsoft"; then
        echo "manual (→brew)  | $app | (part of microsoft-office or individual cask)" >> "$CLASSIFY"
    else
        echo "manual         | $app" >> "$CLASSIFY"
    fi
done < "$INV/applications.txt"

log "Install sources classified → install-sources.txt"

if [ -s "$BREWFILE_ADDON" ]; then
    sort -u "$BREWFILE_ADDON" -o "$BREWFILE_ADDON"
    ADDON_COUNT=$(wc -l < "$BREWFILE_ADDON" | tr -d ' ')
    log "Brewfile.addon: $ADDON_COUNT apps can be migrated to Homebrew"
    info "  These were installed manually but have Homebrew casks available"
fi

# ── 1e. /usr/local/bin inventory (standalone installers, Docker, etc.)
if [ -d /usr/local/bin ]; then
    ls -la /usr/local/bin > "$INV/usr-local-bin.txt" 2>/dev/null && \
        log "/usr/local/bin inventory (standalone tools)"
fi

# ── 1f. Language-specific package managers
has npm    && npm list -g --depth=0 > "$INV/npm-globals.txt" 2>/dev/null       && log "npm globals"
has pip3   && pip3 list --format=freeze > "$INV/pip3-packages.txt" 2>/dev/null  && log "pip3 packages"
has pipx   && pipx list --json > "$INV/pipx-packages.json" 2>/dev/null         && log "pipx packages"
has cargo  && cargo install --list > "$INV/cargo-packages.txt" 2>/dev/null     && log "Cargo packages"
has gem    && gem list --local > "$INV/ruby-gems.txt" 2>/dev/null              && log "Ruby gems"
has code   && code --list-extensions > "$INV/vscode-extensions.txt" 2>/dev/null && log "VS Code extensions"
has cursor && cursor --list-extensions > "$INV/cursor-extensions.txt" 2>/dev/null && log "Cursor extensions"
[ -d "$HOME/go/bin" ] && ls "$HOME/go/bin" > "$INV/go-binaries.txt" 2>/dev/null && log "Go binaries"

# ── 1g. Browser Extensions ───────────────────────────────────────────────────
info "Scanning browser extensions..."
mkdir -p "$INV/browser-extensions"

# Helper: extract Chromium extension names from manifest.json files
_scan_chromium_extensions() {
    local browser_name="$1" ext_dir="$2" outfile="$3"
    [ -d "$ext_dir" ] || return 1
    > "$outfile"
    for ext_id_dir in "$ext_dir"/*/; do
        [ -d "$ext_id_dir" ] || continue
        ext_id=$(basename "$ext_id_dir")
        # Skip Chrome internal extensions directory
        [ "$ext_id" = "Temp" ] && continue
        # Find the latest version's manifest.json
        manifest=$(find "$ext_id_dir" -maxdepth 2 -name "manifest.json" -type f 2>/dev/null | head -1)
        if [ -n "$manifest" ] && [ -f "$manifest" ]; then
            name=$(python3 -c "
import json, sys
try:
    m = json.load(open('$manifest'))
    n = m.get('name', '$ext_id')
    # Skip Chrome internal MSG references that need locale lookup
    if n.startswith('__MSG_'):
        n = m.get('short_name', n)
    if n.startswith('__MSG_'):
        n = '$ext_id'
    print(n)
except: print('$ext_id')
" 2>/dev/null)
            version=$(python3 -c "
import json
try: print(json.load(open('$manifest')).get('version','?'))
except: print('?')
" 2>/dev/null)
            echo "$ext_id | $name | $version" >> "$outfile"
        else
            echo "$ext_id | (unknown) |" >> "$outfile"
        fi
    done
    if [ -s "$outfile" ]; then
        count=$(wc -l < "$outfile" | tr -d ' ')
        log "$browser_name extensions ($count)"
        return 0
    fi
    return 1
}

# Chrome
CHROME_EXT="$HOME/Library/Application Support/Google/Chrome/Default/Extensions"
_scan_chromium_extensions "Chrome" "$CHROME_EXT" "$INV/browser-extensions/chrome-extensions.txt" || \
    info "No Chrome extensions found"

# Chrome profiles beyond Default
for profile_dir in "$HOME/Library/Application Support/Google/Chrome"/Profile\ *; do
    [ -d "$profile_dir/Extensions" ] || continue
    pname=$(basename "$profile_dir")
    _scan_chromium_extensions "Chrome ($pname)" "$profile_dir/Extensions" \
        "$INV/browser-extensions/chrome-${pname// /-}-extensions.txt" 2>/dev/null
done

# Arc (Chromium-based)
ARC_EXT="$HOME/Library/Application Support/Arc/User Data/Default/Extensions"
_scan_chromium_extensions "Arc" "$ARC_EXT" "$INV/browser-extensions/arc-extensions.txt" || \
    info "No Arc extensions found"

# Opera (Chromium-based)
OPERA_EXT="$HOME/Library/Application Support/com.operasoftware.Opera/Extensions"
_scan_chromium_extensions "Opera" "$OPERA_EXT" "$INV/browser-extensions/opera-extensions.txt" || \
    info "No Opera extensions found"

# Safari extensions (from preferences)
SAFARI_PREFS="$HOME/Library/Preferences/com.apple.Safari.plist"
if [ -f "$SAFARI_PREFS" ]; then
    SAFARI_OUT="$INV/browser-extensions/safari-extensions.txt"
    # Safari extensions are App Extensions — list them from pluginkit
    pluginkit -mA 2>/dev/null | grep -i safari > "$SAFARI_OUT" 2>/dev/null
    # Also try to get extension names from Safari preferences
    defaults read com.apple.Safari 2>/dev/null | grep -A2 "Enabled Extensions" >> "$SAFARI_OUT" 2>/dev/null
    if [ -s "$SAFARI_OUT" ]; then
        log "Safari extensions"
    else
        rm -f "$SAFARI_OUT"
        info "No Safari extensions detected"
    fi
fi

# Remove empty browser-extensions dir if nothing was found
rmdir "$INV/browser-extensions" 2>/dev/null || true

# ── 1h. Application Plugins ──────────────────────────────────────────────────
info "Scanning application plugins..."
mkdir -p "$INV/app-plugins"

# JetBrains / PyCharm plugins (user-installed, not built-in)
PYCHARM_PLUGINS_DIR=$(find "$HOME/Library/Application Support/JetBrains" -maxdepth 2 -path "*/PyCharm*/plugins" -type d 2>/dev/null | sort -V | tail -1)
if [ -n "$PYCHARM_PLUGINS_DIR" ] && [ -d "$PYCHARM_PLUGINS_DIR" ]; then
    PYCHARM_PLUGIN_LIST="$INV/app-plugins/pycharm-plugins.txt"
    ls -1 "$PYCHARM_PLUGINS_DIR" > "$PYCHARM_PLUGIN_LIST" 2>/dev/null
    if [ -s "$PYCHARM_PLUGIN_LIST" ]; then
        count=$(wc -l < "$PYCHARM_PLUGIN_LIST" | tr -d ' ')
        log "PyCharm user plugins ($count)"
    fi
fi

# Also check for other JetBrains IDEs (IntelliJ, WebStorm, GoLand, etc.)
for ide_dir in "$HOME/Library/Application Support/JetBrains"/*/; do
    [ -d "$ide_dir/plugins" ] || continue
    ide_name=$(basename "$ide_dir")
    # Skip PyCharm (already handled) and non-IDE dirs
    echo "$ide_name" | grep -qi "pycharm" && continue
    PLUGIN_LIST="$INV/app-plugins/${ide_name}-plugins.txt"
    ls -1 "$ide_dir/plugins" > "$PLUGIN_LIST" 2>/dev/null
    if [ -s "$PLUGIN_LIST" ]; then
        count=$(wc -l < "$PLUGIN_LIST" | tr -d ' ')
        log "$ide_name user plugins ($count)"
    else
        rm -f "$PLUGIN_LIST"
    fi
done

# Obsidian community plugins (scan known vault locations)
OBSIDIAN_VAULTS_FOUND=0
OBSIDIAN_PLUGIN_DIR="$INV/app-plugins/obsidian"
for search_dir in "$HOME/Documents" "$HOME/Desktop" "$HOME" "$HOME/Library/Mobile Documents/iCloud~md~obsidian/Documents"; do
    [ -d "$search_dir" ] || continue
    find "$search_dir" -maxdepth 4 -path "*/.obsidian/plugins" -type d \
        -not -path "*/Library/*" \
        -not -path "*/.Trash/*" \
        2>/dev/null | while read -r plugins_dir; do
            vault_dir=$(dirname "$(dirname "$plugins_dir")")
            vault_name=$(basename "$vault_dir")
            mkdir -p "$OBSIDIAN_PLUGIN_DIR"
            VAULT_PLUGINS="$OBSIDIAN_PLUGIN_DIR/${vault_name}-plugins.txt"
            ls -1 "$plugins_dir" > "$VAULT_PLUGINS" 2>/dev/null
            if [ -s "$VAULT_PLUGINS" ]; then
                count=$(wc -l < "$VAULT_PLUGINS" | tr -d ' ')
                log "Obsidian vault '$vault_name' plugins ($count)"
            else
                rm -f "$VAULT_PLUGINS"
            fi
    done
done

# Remove empty app-plugins dir if nothing was found
find "$INV/app-plugins" -type d -empty -delete 2>/dev/null || true

# ── 1i. Anaconda environments
if has conda; then
    conda env list > "$INV/conda-environments.txt" 2>/dev/null && log "Conda environments"
    # Export each environment
    mkdir -p "$INV/conda-envs"
    conda env list --json 2>/dev/null | python3 -c "
import json, sys
data = json.load(sys.stdin)
for env in data.get('envs', []):
    print(env)
" 2>/dev/null | while read -r env_path; do
        env_name=$(basename "$env_path")
        conda env export -n "$env_name" --no-builds > "$INV/conda-envs/${env_name}.yml" 2>/dev/null && \
            log "  Exported conda env: $env_name"
    done
elif [ -d "$HOME/anaconda3" ] || [ -d "/opt/homebrew/anaconda3" ]; then
    warn "Anaconda detected but conda not in PATH"
    info "  Activate conda first: eval \"\$(conda shell.bash hook)\""
fi

# ── 1j. Steam games
phase "Steam Games"
STEAM_DIR="$HOME/Library/Application Support/Steam"
if [ -d "$STEAM_DIR/steamapps" ]; then
    mkdir -p "$INV/steam"

    # Parse all installed game manifests
    STEAM_LIST="$INV/steam/installed-games.txt"
    > "$STEAM_LIST"
    for manifest in "$STEAM_DIR/steamapps"/appmanifest_*.acf; do
        [ -f "$manifest" ] || continue
        appid=$(grep '"appid"' "$manifest" | grep -o '[0-9]*')
        name=$(grep '"name"' "$manifest" | sed 's/.*"\(.*\)"/\1/' | tail -1)
        size=$(grep '"SizeOnDisk"' "$manifest" | grep -o '[0-9]*')
        size_human=$(numfmt --to=iec "$size" 2>/dev/null || \
            awk "BEGIN{s=$size; u=\"BKMGT\"; for(i=0;s>=1024&&i<4;i++)s/=1024; printf \"%.0f%s\",s,substr(u,i+1,1)}" 2>/dev/null || \
            echo "${size}B")
        echo "$appid | $name | $size_human" >> "$STEAM_LIST"
    done

    if [ -s "$STEAM_LIST" ]; then
        log "Steam games installed on this Mac:"
        while IFS= read -r line; do log "  $line"; done < "$STEAM_LIST"
    fi

    # Check for CrossOver/Steam game launchers on Desktop
    CROSSOVER_GAMES="$INV/steam/crossover-games.txt"
    > "$CROSSOVER_GAMES"
    for app in "$HOME/Desktop"/*.app; do
        [ -d "$app" ] || continue
        run_sh="$app/Contents/MacOS/run.sh"
        if [ -f "$run_sh" ] && grep -q "steam://run/" "$run_sh" 2>/dev/null; then
            appid=$(grep -o 'steam://run/[0-9]*' "$run_sh" | grep -o '[0-9]*')
            name=$(basename "$app" .app)
            echo "$appid | $name | via CrossOver" >> "$CROSSOVER_GAMES"
        fi
    done

    if [ -s "$CROSSOVER_GAMES" ]; then
        log "CrossOver/Steam games (Windows via CrossOver):"
        while IFS= read -r line; do log "  $line"; done < "$CROSSOVER_GAMES"
    fi

    # Steam account info
    if [ -f "$STEAM_DIR/config/loginusers.vdf" ]; then
        cp "$STEAM_DIR/config/loginusers.vdf" "$INV/steam/" 2>/dev/null
        log "Steam account info saved"
    fi
else
    info "No Steam installation found"
fi

# ── 1k. CrossOver bottles
CROSSOVER_BOTTLES="$HOME/Library/Application Support/CrossOver/Bottles"
if [ -d "$CROSSOVER_BOTTLES" ]; then
    info "CrossOver bottles found:"
    du -sh "$CROSSOVER_BOTTLES"/* 2>/dev/null | while read -r line; do
        log "  $line"
    done
    ls -1 "$CROSSOVER_BOTTLES" > "$INV/crossover-bottles.txt" 2>/dev/null
    warn "CrossOver bottles can be very large. Back up separately if needed."
    confirm "Back up CrossOver bottles? (may be tens of GB)" && {
        mkdir -p "$BACKUP_DIR/crossover"
        rsync -a --progress "$CROSSOVER_BOTTLES/" "$BACKUP_DIR/crossover/" 2>/dev/null
        log "CrossOver bottles backed up"
    }
fi

# ── 2. Dotfiles & Config ────────────────────────────────────────────────────
phase "Dotfiles & Config"
CFG="$BACKUP_DIR/config"
mkdir -p "$CFG"/{dotfiles,ssh,gnupg}

# Scan ALL dotfiles in ~ (not just a hardcoded list)
# This catches things an organic setup might have that we wouldn't predict
info "Scanning home directory for dotfiles..."
DOTFILE_LIST="$CFG/dotfiles/_manifest.txt"
> "$DOTFILE_LIST"

# Known useful dotfiles (always grab these)
PRIORITY_DOTFILES=(
    .zshrc .zshenv .zprofile .zsh_history
    .bashrc .bash_profile .bash_history .profile
    .gitconfig .gitignore_global
    .vimrc .tmux.conf
    .npmrc .yarnrc .yarnrc.yml
    .gemrc .curlrc .wgetrc
    .editorconfig .hushlogin .mackup.cfg
    .tool-versions .python-version .node-version .ruby-version .nvmrc
    .p10k.zsh .starship.toml
    .nanorc .inputrc
    .condarc
)

copied=0
for f in "${PRIORITY_DOTFILES[@]}"; do
    if [ -e "$HOME/$f" ]; then
        cp -a "$HOME/$f" "$CFG/dotfiles/" 2>/dev/null && ((copied++))
        echo "$f" >> "$DOTFILE_LIST"
    fi
done

# Also grab any other dotfiles (non-directory) in ~ we didn't cover
for f in "$HOME"/.*; do
    [ -f "$f" ] || continue
    name=$(basename "$f")
    # Skip macOS system files and already-copied files
    case "$name" in
        .|..|.DS_Store|.CFUserTextEncoding|.Trash|.localized) continue ;;
    esac
    if ! grep -qxF "$name" "$DOTFILE_LIST" 2>/dev/null; then
        cp -a "$f" "$CFG/dotfiles/" 2>/dev/null && ((copied++))
        echo "$name (discovered)" >> "$DOTFILE_LIST"
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

# Ghostty
GHOSTTY_CFG="$HOME/Library/Application Support/com.mitchellh.ghostty"
if [ -d "$GHOSTTY_CFG" ]; then
    mkdir -p "$APP/ghostty"
    cp -a "$GHOSTTY_CFG/"* "$APP/ghostty/" 2>/dev/null && log "Ghostty config"
fi
# Also check XDG location
[ -f "$HOME/.config/ghostty/config" ] && {
    mkdir -p "$APP/ghostty"
    cp "$HOME/.config/ghostty/config" "$APP/ghostty/config-xdg" 2>/dev/null
}

# iTerm2
ITERM_PREFS="$HOME/Library/Preferences/com.googlecode.iterm2.plist"
[ -f "$ITERM_PREFS" ] && mkdir -p "$APP/iterm2" && cp "$ITERM_PREFS" "$APP/iterm2/" && log "iTerm2"

# Warp
WARP_DIR="$HOME/Library/Application Support/dev.warp.Warp-Stable"
if [ -d "$WARP_DIR" ]; then
    mkdir -p "$APP/warp"
    for f in prefs.json keybindings.yaml launch_configurations.yaml; do
        [ -f "$WARP_DIR/$f" ] && cp "$WARP_DIR/$f" "$APP/warp/" 2>/dev/null
    done
    log "Warp terminal settings"
fi

# JetBrains (PyCharm config)
PYCHARM_DIR=$(find "$HOME/Library/Application Support/JetBrains" -maxdepth 1 -name "PyCharm*" -type d 2>/dev/null | sort -V | tail -1)
if [ -n "$PYCHARM_DIR" ] && [ -d "$PYCHARM_DIR" ]; then
    mkdir -p "$APP/pycharm"
    for subdir in codestyles colors inspection keymaps options templates; do
        [ -d "$PYCHARM_DIR/$subdir" ] && cp -a "$PYCHARM_DIR/$subdir" "$APP/pycharm/" 2>/dev/null
    done
    log "PyCharm settings"
fi

# Obsidian (vaults list — not vault content, that's in Documents)
OBSIDIAN_CFG="$HOME/Library/Application Support/obsidian"
if [ -d "$OBSIDIAN_CFG" ]; then
    mkdir -p "$APP/obsidian"
    cp "$OBSIDIAN_CFG/obsidian.json" "$APP/obsidian/" 2>/dev/null && log "Obsidian config"
fi

# 1Password (settings, not vault data — that syncs via 1Password account)
ONEPASS_CFG="$HOME/Library/Group Containers/2BUA8C4S2C.com.1password"
if [ -d "$ONEPASS_CFG" ]; then
    info "1Password detected — vault data syncs via your 1Password account"
    info "  Just sign in on the new Mac"
fi

# macOS defaults (full export for reference)
defaults read > "$APP/macos-defaults-full.txt" 2>/dev/null && log "macOS defaults (full)"

# ── 3b. License & Activation Data ──────────────────────────────────────────
# Some apps store license keys in preference plists. Copying these to the new
# Mac avoids having to re-enter serial numbers.
phase "License & Activation Data"
LIC="$BACKUP_DIR/licenses"
mkdir -p "$LIC/plists"

# Map of app-name → plist bundle IDs that contain license/registration data
declare -A LICENSE_PLISTS=(
    ["BBEdit"]="com.barebones.bbedit"
    ["Bartender"]="com.surteesstudios.Bartender"
    ["iStat Menus"]="com.bjango.istatmenus"
    ["iStat Menus (helper)"]="com.bjango.istatmenus.agent"
    ["iStat Menus (status)"]="com.bjango.istatmenus.status"
    ["TG Pro"]="com.tunabellysoftware.tgpro"
    ["Gemini 2"]="com.macpaw.site.Gemini2"
    ["Shottr"]="cc.shottr.shottr"
    ["TextSniper"]="com.TextSniper.TextSniper"
    ["CrossOver"]="com.codeweavers.CrossOver"
    ["Sublime Text"]="com.sublimetext.4"
)

LICENSE_COUNT=0
for app_name in "${!LICENSE_PLISTS[@]}"; do
    bundle_id="${LICENSE_PLISTS[$app_name]}"
    plist="$HOME/Library/Preferences/${bundle_id}.plist"
    if [ -f "$plist" ]; then
        cp "$plist" "$LIC/plists/" 2>/dev/null
        log "$app_name license plist (${bundle_id})"
        ((LICENSE_COUNT++))
    fi
done

if [ "$LICENSE_COUNT" -gt 0 ]; then
    info "$LICENSE_COUNT license plists backed up"
    sensitive "These contain license keys — keep secure"
else
    info "No license plists found"
fi

# ── 3c. Migration Manifest ─────────────────────────────────────────────────
# Generate a manifest that classifies every installed app by migration pattern,
# so the restore script (and the user) knows exactly what to do for each app.
info "Generating migration manifest..."
MANIFEST="$BACKUP_DIR/migration-manifest.txt"
{
    echo "# ═══════════════════════════════════════════════════════════════"
    echo "# Migration Manifest — generated $(date)"
    echo "#"
    echo "# Each app is classified by how it should be restored:"
    echo "#   SIGN-IN     → install binary, sign into account, everything syncs"
    echo "#   CONFIG      → install binary, restore config files from backup"
    echo "#   LICENSE-KEY  → install binary, restore license plist (or re-enter key)"
    echo "#   RE-DOWNLOAD → install binary, sign in, re-download content"
    echo "#   EXTENSION   → host app handles it (sync or reinstall from list)"
    echo "#   BREW-AUTO   → fully automated via brew bundle"
    echo "# ═══════════════════════════════════════════════════════════════"
    echo ""

    # Pattern: SIGN-IN (cloud-synced, just need account login)
    echo "## SIGN-IN (install + sign into your account)"
    echo "# These apps sync all data and settings via your account."
    echo "# No config files to restore — just sign in after install."
    for app in "1Password" "OneDrive" "ChatGPT" "Claude" "Codex" "Perplexity" \
               "Microsoft Word" "Microsoft Excel" "Microsoft PowerPoint" \
               "Microsoft Outlook" "Microsoft OneNote" "Microsoft Teams" \
               "WhatsApp"; do
        [ -d "/Applications/${app}.app" ] && echo "  $app"
    done
    echo ""

    # Pattern: CONFIG (install + restore config files)
    echo "## CONFIG (install + restore settings from backup)"
    echo "# These are functional after install but need their config restored."
    for app_cfg in \
        "VS Code|app-settings/vscode/" \
        "Cursor|app-settings/cursor/" \
        "Ghostty|app-settings/ghostty/" \
        "iTerm2|app-settings/iterm2/" \
        "Warp|app-settings/warp/" \
        "PyCharm|app-settings/pycharm/" \
        "Obsidian|app-settings/obsidian/" \
        "Zed|config/dot-config/zed/"; do
        app="${app_cfg%%|*}"
        cfg="${app_cfg##*|}"
        for search_name in "$app" "$(echo "$app" | sed 's/ //')"; do
            if [ -d "/Applications/${search_name}.app" ] || \
               [ -d "/Applications/${app}.app" ]; then
                echo "  $app → $cfg"
                break
            fi
        done 2>/dev/null
    done
    echo ""

    # Pattern: LICENSE-KEY (install + restore plist or re-enter key)
    echo "## LICENSE-KEY (install + restore license plist or re-enter serial)"
    echo "# These apps store license data in ~/Library/Preferences/."
    echo "# Restoring the plist should auto-activate. Keep your keys handy as backup."
    for app_name in "${!LICENSE_PLISTS[@]}"; do
        bundle_id="${LICENSE_PLISTS[$app_name]}"
        if [ -f "$HOME/Library/Preferences/${bundle_id}.plist" ]; then
            echo "  $app_name → licenses/plists/${bundle_id}.plist"
        fi
    done
    echo ""

    # Pattern: RE-DOWNLOAD (install + sign in + reacquire content)
    echo "## RE-DOWNLOAD (install + sign in + re-download content)"
    echo "# These manage large content that must be re-acquired after install."
    [ -d "/Applications/Steam.app" ] && echo "  Steam → sign in, re-download games from library"
    [ -d "/Applications/CrossOver.app" ] && echo "  CrossOver → restore bottles from backup OR re-download"
    [ -d "/Applications/Docker.app" ] && echo "  Docker → pull images (docker pull) after install"
    has conda 2>/dev/null && echo "  Anaconda → recreate envs from conda-envs/*.yml"
    echo ""

    # Pattern: EXTENSION (syncs via host app or reinstall from list)
    echo "## EXTENSION (browser/editor extensions — sync or reinstall from list)"
    echo "# Most sync automatically when you sign into the host app."
    echo "# Extension lists in backup as fallback."
    [ -d "/Applications/Google Chrome.app" ] && echo "  Chrome extensions → sign into Google account to sync"
    [ -d "/Applications/Arc.app" ] && echo "  Arc extensions → sign into Arc account to sync"
    [ -d "/Applications/Opera.app" ] && echo "  Opera extensions → sign into Opera account to sync"
    has code 2>/dev/null && echo "  VS Code extensions → code --install-extension (scripted in restore)"
    has cursor 2>/dev/null && echo "  Cursor extensions → cursor --install-extension (scripted in restore)"
    echo "  JetBrains plugins → Settings → Plugins in each IDE"
    echo "  Obsidian community plugins → restored with vault data"
    echo ""

} > "$MANIFEST"

log "Migration manifest → migration-manifest.txt"
info "Review this file to see exactly what each app needs on the new Mac"

# ── 4. Project Discovery ────────────────────────────────────────────────────
phase "Project Discovery"
PROJ="$BACKUP_DIR/projects"
mkdir -p "$PROJ"

# Scan EVERYWHERE in ~ for git repos, not just known directories
# This is the "organic install" approach — find code wherever it landed
info "Scanning entire home directory for git repos..."
LIST="$PROJ/_project-list.txt"
> "$LIST"

find "$HOME" -maxdepth 5 -name ".git" -type d \
    -not -path "*/Library/*" \
    -not -path "*/.Trash/*" \
    -not -path "*/node_modules/*" \
    -not -path "*/.venv/*" \
    -not -path "*/venv/*" \
    -not -path "*/.cargo/*" \
    -not -path "*/anaconda3/*" \
    2>/dev/null | while read -r g; do dirname "$g"; done | sort -u > "$LIST"

COUNT=$(wc -l < "$LIST" | tr -d ' ')

if [ "$COUNT" -gt 0 ]; then
    log "Found $COUNT git repos across your system:"
    while IFS= read -r project; do
        SIZE=$(du -sh "$project" 2>/dev/null | cut -f1)
        printf "    %-8s %s\n" "$SIZE" "${project#$HOME/}"
    done < "$LIST"
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
    info "No git repos found"
fi

# Also flag code-like files NOT in git repos (orphan scripts, notebooks)
info "Scanning for orphan code files (not in git repos)..."
ORPHANS="$PROJ/_orphan-code-files.txt"
find "$HOME" -maxdepth 4 -type f \( \
    -name "*.py" -o -name "*.ipynb" -o -name "*.js" -o -name "*.ts" \
    -o -name "*.sh" -o -name "*.rb" -o -name "*.go" -o -name "*.rs" \
    -o -name "*.swift" -o -name "*.java" -o -name "*.scala" \
    \) \
    -not -path "*/Library/*" \
    -not -path "*/.Trash/*" \
    -not -path "*/node_modules/*" \
    -not -path "*/anaconda3/*" \
    -not -path "*/.venv/*" \
    2>/dev/null | while read -r f; do
        # Check if this file is inside a git repo we already found
        in_repo=false
        while IFS= read -r repo; do
            if [[ "$f" == "$repo"* ]]; then
                in_repo=true
                break
            fi
        done < "$LIST"
        if ! $in_repo; then
            echo "${f#$HOME/}"
        fi
    done | sort > "$ORPHANS" 2>/dev/null

ORPHAN_COUNT=$(wc -l < "$ORPHANS" 2>/dev/null | tr -d ' ')
if [ "$ORPHAN_COUNT" -gt 0 ]; then
    log "Found $ORPHAN_COUNT orphan code files (not in any git repo):"
    head -20 "$ORPHANS" | sed 's/^/    /'
    [ "$ORPHAN_COUNT" -gt 20 ] && info "  ... and $(( ORPHAN_COUNT - 20 )) more (see _orphan-code-files.txt)"
fi

# ── 5. Personal Files ───────────────────────────────────────────────────────
phase "Personal Files"
FILES="$BACKUP_DIR/files"
mkdir -p "$FILES"

# Warn about iCloud offloading
info "Checking for iCloud Desktop & Documents sync..."
if [ -d "$HOME/Library/Mobile Documents/com~apple~CloudDocs" ]; then
    warn "iCloud Desktop & Documents is ENABLED"
    warn "Files may be offloaded (stubs only). Options:"
    echo "    1. Download all files first: select files in Finder → right-click → Download Now"
    echo "    2. Or rely on iCloud to re-sync on the new Mac (recommended for large libraries)"
    echo "    3. Back up what's local now as insurance"
    echo ""
fi

# Sweep screenshots from Desktop (and other locations) into organized structure
# macOS names them: "Screenshot YYYY-MM-DD at H.MM.SS AM.png"
info "Scanning for screenshots..."
SCREENSHOTS_DIR="$FILES/Screenshots"
mkdir -p "$SCREENSHOTS_DIR"

for search_dir in "$HOME/Desktop" "$HOME/Documents" "$HOME/Downloads"; do
    [ -d "$search_dir" ] || continue
    find "$search_dir" -maxdepth 2 -name "Screenshot *.png" -type f 2>/dev/null | while read -r screenshot; do
        fname=$(basename "$screenshot")
        # Parse date from "Screenshot YYYY-MM-DD at ..."
        if [[ "$fname" =~ ^Screenshot\ ([0-9]{4})-([0-9]{2})-([0-9]{2}) ]]; then
            year="${BASH_REMATCH[1]}"
            month="${BASH_REMATCH[2]}"
            mkdir -p "$SCREENSHOTS_DIR/$year/$month"
            cp -a "$screenshot" "$SCREENSHOTS_DIR/$year/$month/" 2>/dev/null
        else
            # Non-standard name, put in unsorted
            mkdir -p "$SCREENSHOTS_DIR/unsorted"
            cp -a "$screenshot" "$SCREENSHOTS_DIR/unsorted/" 2>/dev/null
        fi
    done
done

SCREENSHOT_COUNT=$(find "$SCREENSHOTS_DIR" -type f -name "*.png" 2>/dev/null | wc -l | tr -d ' ')
if [ "$SCREENSHOT_COUNT" -gt 0 ]; then
    log "Organized $SCREENSHOT_COUNT screenshots by date into backup"
    # Show the year/month breakdown
    find "$SCREENSHOTS_DIR" -mindepth 2 -maxdepth 2 -type d 2>/dev/null | sort | while read -r ym; do
        count=$(find "$ym" -type f 2>/dev/null | wc -l | tr -d ' ')
        rel="${ym#$SCREENSHOTS_DIR/}"
        log "  $rel: $count screenshots"
    done
else
    info "No screenshots found"
fi
echo ""

for dir in "$HOME/Documents" "$HOME/Desktop" "$HOME/Downloads" "$HOME/Pictures" "$HOME/Music" "$HOME/Movies"; do
    name=$(basename "$dir")
    [ -d "$dir" ] && [ "$(ls -A "$dir" 2>/dev/null)" ] || continue
    SIZE=$(du -sh "$dir" 2>/dev/null | cut -f1)
    confirm "Back up $name ($SIZE on disk)?" && {
        rsync -a --progress \
            --exclude='.DS_Store' \
            --exclude='workspace/.metadata' \
            "$dir/" "$FILES/$name/" 2>/dev/null
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
info "Key files for restore:"
echo "    Brewfile:          $INV/Brewfile"
echo "    Brewfile.addon:    $INV/Brewfile.addon"
echo "    Install sources:   $INV/install-sources.txt"
echo "    Steam games:       $INV/steam/installed-games.txt"
echo ""
sensitive "This backup contains SSH keys, GPG keys, and credentials. Keep it secure."
