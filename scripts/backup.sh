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
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/helpers.sh"

# ── Load user-customizable config ───────────────────────────────────────────
CONFIG_DIR="$REPO_DIR/config"
[ -f "$CONFIG_DIR/cask-map.sh" ]           && source "$CONFIG_DIR/cask-map.sh"
[ -f "$CONFIG_DIR/license-plists.sh" ]     && source "$CONFIG_DIR/license-plists.sh"
[ -f "$CONFIG_DIR/app-settings.sh" ]       && source "$CONFIG_DIR/app-settings.sh"
[ -f "$CONFIG_DIR/migration-patterns.sh" ] && source "$CONFIG_DIR/migration-patterns.sh"

# Ensure arrays exist even if config files are missing
declare -a CASK_MAP 2>/dev/null || true
declare -a LICENSE_PLISTS 2>/dev/null || true
declare -a APP_SETTINGS 2>/dev/null || true
declare -a SIGN_IN_APPS 2>/dev/null || true
declare -a RE_DOWNLOAD_APPS 2>/dev/null || true
declare -a JETBRAINS_IDES 2>/dev/null || true
declare -a JETBRAINS_SUBDIRS 2>/dev/null || true
[ ${#JETBRAINS_SUBDIRS[@]} -eq 0 ] && JETBRAINS_SUBDIRS=(codestyles colors inspection keymaps options templates)

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
chmod 700 "$BACKUP_DIR"
# Also restrict the parent mac-backup container so directory listing is owner-only
chmod 700 "$DRIVE/mac-backup" 2>/dev/null || true

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

# CASK_MAP is loaded from config/cask-map.sh above.
# For apps not in the map, we try auto-discovery via brew search.

# Auto-discover bundled apps from /System/Applications (always present on macOS)
SYSTEM_APPS=""
if [ -d /System/Applications ]; then
    SYSTEM_APPS=$(ls -1 /System/Applications/ 2>/dev/null | grep '\.app$' || true)
fi
# Also consider apps that come with macOS but live in /Applications
APPLE_BUNDLED_PATTERN="Safari.app|Utilities"

# Helper: try to find the Homebrew cask name for an app
_find_cask_name() {
    local app="$1"
    # 1. Check the user's CASK_MAP first
    # Guard ${arr[@]} expansion: bash 3.2 + set -u errors on empty arrays.
    local mapped
    if [ "${#CASK_MAP[@]}" -gt 0 ] && mapped=$(lookup "$app" "${CASK_MAP[@]}"); then
        echo "$mapped"
        return 0
    fi
    # 2. Try simple name derivation (lowercase, strip .app, replace spaces with dashes)
    local guess
    guess=$(echo "${app%.app}" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')
    if brew info --cask "$guess" &>/dev/null; then
        echo "$guess"
        return 0
    fi
    return 1
}

# Helper: check if an app is bundled with macOS
_is_bundled_app() {
    local app="$1"
    # Check /System/Applications
    echo "$SYSTEM_APPS" | grep -qxF "$app" 2>/dev/null && return 0
    # Check known Apple bundled pattern
    echo "$app" | grep -qE "^($APPLE_BUNDLED_PATTERN)$" 2>/dev/null && return 0
    return 1
}

# Generate Brewfile-addons for apps not currently in Homebrew
BREWFILE_ADDON="$INV/Brewfile.addon"
> "$BREWFILE_ADDON"

info "  (auto-discovering Homebrew cask names for apps not in config...)"
while IFS= read -r app; do
    [ -z "$app" ] && continue

    # 1. Check if bundled with macOS
    if _is_bundled_app "$app"; then
        echo "bundled        | $app" >> "$CLASSIFY"
        continue
    fi

    # 2. Check if it's a Mac App Store app
    if has mas && echo "$MAS_APPS" | grep -q . 2>/dev/null; then
        # MAS apps have receipts in /Applications/<app>/Contents/_MASReceipt
        if [ -d "/Applications/$app/Contents/_MASReceipt" ]; then
            echo "mas            | $app" >> "$CLASSIFY"
            continue
        fi
    fi

    # 3. Check if already installed via Homebrew cask
    cask_name=$(_find_cask_name "$app" 2>/dev/null || echo "")
    if [ -n "$cask_name" ]; then
        if echo "$BREW_CASKS" | grep -qw "$cask_name" 2>/dev/null; then
            echo "brew-cask      | $app | $cask_name" >> "$CLASSIFY"
        else
            # Known cask but was installed manually — add to addon
            echo "manual (→brew)  | $app | $cask_name" >> "$CLASSIFY"
            echo "cask \"$cask_name\"" >> "$BREWFILE_ADDON"
        fi
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
            # Pass values via env vars (not interpolated into the script) to prevent
            # shell injection if a manifest path or extension ID contains special chars.
            name=$(PYMANIFEST="$manifest" PYEXTID="$ext_id" python3 -c '
import json, os
mp, eid = os.environ["PYMANIFEST"], os.environ["PYEXTID"]
try:
    m = json.load(open(mp))
    n = m.get("name", eid)
    # Skip Chrome internal MSG references that need locale lookup
    if n.startswith("__MSG_"):
        n = m.get("short_name", n)
    if n.startswith("__MSG_"):
        n = eid
    print(n)
except:
    print(eid)
' 2>/dev/null)
            version=$(PYMANIFEST="$manifest" python3 -c '
import json, os
try: print(json.load(open(os.environ["PYMANIFEST"])).get("version", "?"))
except: print("?")
' 2>/dev/null)
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

# JetBrains IDE plugins (scan all IDEs found)
if [ -d "$HOME/Library/Application Support/JetBrains" ]; then
    for ide_dir in "$HOME/Library/Application Support/JetBrains"/*/; do
        [ -d "$ide_dir/plugins" ] || continue
        ide_name=$(basename "$ide_dir")
        PLUGIN_LIST="$INV/app-plugins/${ide_name}-plugins.txt"
        ls -1 "$ide_dir/plugins" > "$PLUGIN_LIST" 2>/dev/null
        if [ -s "$PLUGIN_LIST" ]; then
            count=$(wc -l < "$PLUGIN_LIST" | tr -d ' ')
            log "$ide_name user plugins ($count)"
        else
            rm -f "$PLUGIN_LIST"
        fi
    done
fi

# Obsidian community plugins (scan known vault locations)
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
        # Validate size is a pure integer before using in arithmetic (guards awk injection
        # if the .acf file were ever maliciously crafted).
        if [[ "$size" =~ ^[0-9]+$ ]]; then
            size_human=$(numfmt --to=iec "$size" 2>/dev/null || \
                awk -v s="$size" 'BEGIN{u="BKMGT"; for(i=0;s>=1024&&i<4;i++)s/=1024; printf "%.0f%s",s,substr(u,i+1,1)}' 2>/dev/null || \
                echo "${size}B")
        else
            size_human="?"
        fi
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

# Config-driven app settings backup (loaded from config/app-settings.sh)
for entry in "${APP_SETTINGS[@]}"; do
    IFS='|' read -r name src_path backup_subdir files_to_copy <<< "$entry"
    src_full="$HOME/$src_path"

    # Handle both files and directories
    if [ -e "$src_full" ]; then
        mkdir -p "$APP/$backup_subdir"
        if [ -n "$files_to_copy" ]; then
            # Copy only specific files
            for f in $files_to_copy; do
                [ -e "$src_full/$f" ] && cp -a "$src_full/$f" "$APP/$backup_subdir/" 2>/dev/null
            done
        elif [ -d "$src_full" ]; then
            cp -a "$src_full/"* "$APP/$backup_subdir/" 2>/dev/null
        else
            # Single file (like a .plist)
            cp -a "$src_full" "$APP/$backup_subdir/" 2>/dev/null
        fi
        log "$name settings"
    fi
done

# JetBrains IDEs (finds latest version of each IDE automatically)
if [ -d "$HOME/Library/Application Support/JetBrains" ]; then
    for ide_entry in "${JETBRAINS_IDES[@]}"; do
        IFS='|' read -r ide_name ide_prefix <<< "$ide_entry"
        IDE_DIR=$(find "$HOME/Library/Application Support/JetBrains" -maxdepth 1 -name "${ide_prefix}*" -type d 2>/dev/null | sort -V | tail -1)
        if [ -n "$IDE_DIR" ] && [ -d "$IDE_DIR" ]; then
            ide_subdir=$(echo "$ide_name" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')
            mkdir -p "$APP/$ide_subdir"
            for subdir in "${JETBRAINS_SUBDIRS[@]}"; do
                [ -d "$IDE_DIR/$subdir" ] && cp -a "$IDE_DIR/$subdir" "$APP/$ide_subdir/" 2>/dev/null
            done
            log "$ide_name settings"
        fi
    done
fi

# macOS defaults (full export for reference)
defaults read > "$APP/macos-defaults-full.txt" 2>/dev/null && log "macOS defaults (full)"

# ── 3b. License & Activation Data ──────────────────────────────────────────
# Some apps store license keys in preference plists. Copying these to the new
# Mac avoids having to re-enter serial numbers.
phase "License & Activation Data"
LIC="$BACKUP_DIR/licenses"
mkdir -p "$LIC/plists"

# LICENSE_PLISTS is loaded from config/license-plists.sh above.

LICENSE_COUNT=0
# Guard ${arr[@]} expansion: bash 3.2 + set -u errors on empty arrays.
if [ "${#LICENSE_PLISTS[@]}" -gt 0 ]; then
    for entry in "${LICENSE_PLISTS[@]}"; do
        app_name="${entry%%|*}"
        bundle_id="${entry#*|}"
        plist="$HOME/Library/Preferences/${bundle_id}.plist"
        if [ -f "$plist" ]; then
            cp "$plist" "$LIC/plists/" 2>/dev/null
            log "$app_name license plist (${bundle_id})"
            ((LICENSE_COUNT++))
        fi
    done
fi

if [ "$LICENSE_COUNT" -gt 0 ]; then
    info "$LICENSE_COUNT license plists backed up"
    sensitive "These contain license keys — keep secure"
else
    info "No license plists found"
fi

# ── 3c. Migration Manifest ─────────────────────────────────────────────────
# Generate a manifest that classifies every installed app by migration pattern.
# Uses config/migration-patterns.sh for sign-in apps, and auto-detects the rest
# from what was actually backed up.
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

    # Pattern: SIGN-IN — from config/migration-patterns.sh
    echo "## SIGN-IN (install + sign into your account)"
    echo "# These apps sync all data and settings via your account."
    echo "# No config files to restore — just sign in after install."
    for app in "${SIGN_IN_APPS[@]}"; do
        [ -d "/Applications/${app}.app" ] && echo "  $app"
    done
    echo ""

    # Pattern: CONFIG — auto-detected from what was actually backed up
    echo "## CONFIG (install + restore settings from backup)"
    echo "# These are functional after install but need their config restored."
    for entry in "${APP_SETTINGS[@]}"; do
        IFS='|' read -r name src_path backup_subdir files_to_copy <<< "$entry"
        [ -d "$APP/$backup_subdir" ] && [ "$(ls -A "$APP/$backup_subdir" 2>/dev/null)" ] && \
            echo "  $name → app-settings/$backup_subdir/"
    done
    # Add any JetBrains IDEs that were backed up
    for ide_entry in "${JETBRAINS_IDES[@]}"; do
        IFS='|' read -r ide_name ide_prefix <<< "$ide_entry"
        ide_subdir=$(echo "$ide_name" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')
        [ -d "$APP/$ide_subdir" ] && echo "  $ide_name → app-settings/$ide_subdir/"
    done
    echo ""

    # Pattern: LICENSE-KEY — auto-detected from LICENSE_PLISTS that were found
    echo "## LICENSE-KEY (install + restore license plist or re-enter serial)"
    echo "# These apps store license data in ~/Library/Preferences/."
    echo "# Restoring the plist should auto-activate. Keep your keys handy as backup."
    if [ "${#LICENSE_PLISTS[@]}" -gt 0 ]; then
        for entry in "${LICENSE_PLISTS[@]}"; do
            app_name="${entry%%|*}"
            bundle_id="${entry#*|}"
            if [ -f "$HOME/Library/Preferences/${bundle_id}.plist" ]; then
                echo "  $app_name → licenses/plists/${bundle_id}.plist"
            fi
        done
    fi
    echo ""

    # Pattern: RE-DOWNLOAD — from config + auto-detected
    echo "## RE-DOWNLOAD (install + sign in + re-download content)"
    echo "# These manage large content that must be re-acquired after install."
    for rd_entry in "${RE_DOWNLOAD_APPS[@]}"; do
        IFS='|' read -r rd_app rd_instructions <<< "$rd_entry"
        [ -d "/Applications/${rd_app}.app" ] && echo "  $rd_app → $rd_instructions"
    done
    has conda 2>/dev/null && echo "  Anaconda → recreate envs from conda-envs/*.yml"
    echo ""

    # Pattern: EXTENSION — auto-detected from browser-extensions/ and app-plugins/
    echo "## EXTENSION (browser/editor extensions — sync or reinstall from list)"
    echo "# Most sync automatically when you sign into the host app."
    echo "# Extension lists in backup as fallback."
    # Scan for any Chromium browser extensions we found
    if [ -d "$INV/browser-extensions" ]; then
        for ext_file in "$INV/browser-extensions"/*-extensions.txt; do
            [ -f "$ext_file" ] || continue
            browser=$(basename "$ext_file" -extensions.txt | sed 's/-/ /g; s/\b\(.\)/\u\1/g')
            echo "  $browser extensions → sign into account to sync"
        done
    fi
    # Editor extensions
    has code 2>/dev/null && echo "  VS Code extensions → code --install-extension (scripted in restore)"
    has cursor 2>/dev/null && echo "  Cursor extensions → cursor --install-extension (scripted in restore)"
    # JetBrains and Obsidian plugins
    if [ -d "$INV/app-plugins" ]; then
        [ "$(find "$INV/app-plugins" -maxdepth 1 -name '*-plugins.txt' 2>/dev/null | head -1)" ] && \
            echo "  JetBrains plugins → Settings → Plugins in each IDE"
        [ -d "$INV/app-plugins/obsidian" ] && \
            echo "  Obsidian community plugins → restored with vault data"
    fi
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

# ── 5. Personal Files (classified by data type) ───────────────────────────
phase "Personal Files"
FILES="$BACKUP_DIR/files"
mkdir -p "$FILES"

# Warn about iCloud offloading
info "Checking for iCloud Desktop & Documents sync..."
ICLOUD_ENABLED=false
if [ -d "$HOME/Library/Mobile Documents/com~apple~CloudDocs" ]; then
    ICLOUD_ENABLED=true
    warn "iCloud Desktop & Documents is ENABLED"
    warn "Files may be offloaded (stubs only). Options:"
    echo "    1. Download all files first: select files in Finder → right-click → Download Now"
    echo "    2. Or rely on iCloud to re-sync on the new Mac (recommended for large libraries)"
    echo "    3. Back up what's local now as insurance"
    echo ""
fi

# ── 5a-pre. Detect other cloud sync folders ──────────────────────────────────
# OneDrive, Google Drive, Dropbox, Box sync locally but are already safe in the
# cloud. They'll re-sync automatically on the new Mac, so we skip them by default.
# Files may also be online-only stubs (not fully downloaded), same as iCloud.
info "Checking for other cloud sync folders..."
CLOUD_SYNC_DIRS=()
CLOUD_SYNC_NAMES=()

# OneDrive — ~/Library/CloudStorage/OneDrive-* or ~/OneDrive
for od_dir in \
    "$HOME/Library/CloudStorage"/OneDrive-* \
    "$HOME/OneDrive" \
    "$HOME/OneDrive - "*; do
    [ -d "$od_dir" ] || continue
    CLOUD_SYNC_DIRS+=("$od_dir")
    CLOUD_SYNC_NAMES+=("OneDrive")
done

# Google Drive — ~/Library/CloudStorage/GoogleDrive-*
for gd_dir in "$HOME/Library/CloudStorage"/GoogleDrive-*; do
    [ -d "$gd_dir" ] || continue
    CLOUD_SYNC_DIRS+=("$gd_dir")
    CLOUD_SYNC_NAMES+=("Google Drive ($(basename "$gd_dir" | sed 's/GoogleDrive-//'))")
done

# Dropbox
[ -d "$HOME/Dropbox" ] && {
    CLOUD_SYNC_DIRS+=("$HOME/Dropbox")
    CLOUD_SYNC_NAMES+=("Dropbox")
}

# Box
for box_dir in "$HOME/Box" "$HOME/Library/CloudStorage"/Box-*; do
    [ -d "$box_dir" ] || continue
    CLOUD_SYNC_DIRS+=("$box_dir")
    CLOUD_SYNC_NAMES+=("Box")
done

if [ ${#CLOUD_SYNC_DIRS[@]} -gt 0 ]; then
    info "Cloud sync folders found:"
    for i in "${!CLOUD_SYNC_DIRS[@]}"; do
        SIZE=$(du -sh "${CLOUD_SYNC_DIRS[$i]}" 2>/dev/null | cut -f1)
        echo "    ${CLOUD_SYNC_NAMES[$i]} → ${CLOUD_SYNC_DIRS[$i]} ($SIZE)"
    done
    echo ""
    warn "Skipping cloud sync folders — they will re-sync automatically on the new Mac."
    warn "Files may be online-only stubs (not fully downloaded locally)."
    echo ""
    confirm "Include cloud sync folders in backup anyway? (may be large — belt-and-suspenders)" && {
        mkdir -p "$FILES/cloud-sync"
        for i in "${!CLOUD_SYNC_DIRS[@]}"; do
            dir="${CLOUD_SYNC_DIRS[$i]}"
            name="${CLOUD_SYNC_NAMES[$i]}"
            SIZE=$(du -sh "$dir" 2>/dev/null | cut -f1)
            confirm "  Back up $name ($SIZE)?" && {
                dest=$(echo "$name" | tr ' ()/' '----' | tr -s '-' | sed 's/-*$//')
                rsync -a --progress \
                    --exclude='.DS_Store' \
                    "$dir/" "$FILES/cloud-sync/$dest/" 2>/dev/null
                log "$name backed up to cloud-sync/$dest/"
            }
        done
    }
    echo ""
else
    info "No other cloud sync folders found"
    echo ""
fi

# ── 5a. Screenshots — organized by date
info "Scanning for screenshots..."
SCREENSHOTS_DIR="$FILES/Screenshots"
mkdir -p "$SCREENSHOTS_DIR"

for search_dir in "$HOME/Desktop" "$HOME/Documents" "$HOME/Downloads"; do
    [ -d "$search_dir" ] || continue
    find "$search_dir" -maxdepth 2 -name "Screenshot *.png" -type f 2>/dev/null | while read -r screenshot; do
        fname=$(basename "$screenshot")
        if [[ "$fname" =~ ^Screenshot\ ([0-9]{4})-([0-9]{2})-([0-9]{2}) ]]; then
            year="${BASH_REMATCH[1]}"
            month="${BASH_REMATCH[2]}"
            mkdir -p "$SCREENSHOTS_DIR/$year/$month"
            cp -a "$screenshot" "$SCREENSHOTS_DIR/$year/$month/" 2>/dev/null
        else
            mkdir -p "$SCREENSHOTS_DIR/unsorted"
            cp -a "$screenshot" "$SCREENSHOTS_DIR/unsorted/" 2>/dev/null
        fi
    done
done

SCREENSHOT_COUNT=$(find "$SCREENSHOTS_DIR" -type f -name "*.png" 2>/dev/null | wc -l | tr -d ' ')
if [ "$SCREENSHOT_COUNT" -gt 0 ]; then
    log "Organized $SCREENSHOT_COUNT screenshots by date into backup"
    find "$SCREENSHOTS_DIR" -mindepth 2 -maxdepth 2 -type d 2>/dev/null | sort | while read -r ym; do
        count=$(find "$ym" -type f 2>/dev/null | wc -l | tr -d ' ')
        rel="${ym#$SCREENSHOTS_DIR/}"
        log "  $rel: $count screenshots"
    done
else
    info "No screenshots found"
fi
echo ""

# ── 5b. Scattered credentials — find secrets outside ~/.ssh and ~/.gnupg
info "Scanning for scattered credentials and secrets..."
CREDS="$FILES/scattered-credentials"
mkdir -p "$CREDS"
CRED_COUNT=0

# Sensitive files by name pattern (backup codes, tokens, key files)
find "$HOME/Documents" "$HOME/Desktop" "$HOME/Downloads" -maxdepth 4 -type f \( \
    -iname "*backup-code*" -o -iname "*recovery-code*" -o -iname "*secret*key*" \
    -o -iname "*api*key*" -o -iname "*token*" -o -iname "*.pem" \
    -o -iname "*.key" -o -iname "*credential*" -o -iname "*license*key*" \
    \) \
    -not -path "*/.Trash/*" \
    -not -path "*/node_modules/*" \
    2>/dev/null | while read -r f; do
        rel="${f#$HOME/}"
        mkdir -p "$CREDS/$(dirname "$rel")"
        cp -a "$f" "$CREDS/$rel" 2>/dev/null
        echo "$rel"
    done > "$CREDS/_found.txt" 2>/dev/null

CRED_COUNT=$(wc -l < "$CREDS/_found.txt" 2>/dev/null | tr -d ' ')
if [ "$CRED_COUNT" -gt 0 ]; then
    warn "Found $CRED_COUNT credential/secret files scattered in your Documents:"
    cat "$CREDS/_found.txt" | sed 's/^/    /'
    sensitive "These have been backed up to scattered-credentials/"
else
    info "No scattered credentials found"
    rm -rf "$CREDS"
fi

# App-specific auth tokens in ~/.config
info "Scanning ~/.config for auth tokens..."
AUTH_TOKENS="$FILES/auth-tokens"
mkdir -p "$AUTH_TOKENS"

# GitHub CLI (OAuth tokens)
[ -f "$HOME/.config/gh/hosts.yml" ] && {
    mkdir -p "$AUTH_TOKENS/gh"
    cp "$HOME/.config/gh/hosts.yml" "$AUTH_TOKENS/gh/" 2>/dev/null
    sensitive "GitHub CLI auth token"
}

# Sourcery
[ -f "$HOME/.config/sourcery/auth.yaml" ] && {
    mkdir -p "$AUTH_TOKENS/sourcery"
    cp "$HOME/.config/sourcery/auth.yaml" "$AUTH_TOKENS/sourcery/" 2>/dev/null
    sensitive "Sourcery auth token"
}

echo ""

# ── 5c. Classify Documents content before backing up
info "Analyzing Documents folder structure..."
DOC="$HOME/Documents"
if [ -d "$DOC" ]; then
    DATA_CLASS="$FILES/_data-classification.txt"
    {
        echo "# ═══════════════════════════════════════════════════════════════"
        echo "# Data Classification — generated $(date)"
        echo "#"
        echo "# How your data will be organized on the new Mac:"
        echo "#   CLOUD-SYNCED → will re-sync via iCloud/OneDrive (backup = insurance)"
        echo "#   DOCUMENTS    → personal and work files → ~/Documents/"
        echo "#   ARCHIVAL     → large old data (Zoom, recordings) → consider cloud/external"
        echo "#   APP-DATA     → created by specific apps → restored with the app"
        echo "#   MEDIA        → photos, videos → ~/Pictures/ or ~/Movies/"
        echo "#   STALE        → multi-machine sync artifacts, temp folders → review before migrating"
        echo "# ═══════════════════════════════════════════════════════════════"
        echo ""
    } > "$DATA_CLASS"

    # Detect multi-machine sync artifacts
    STALE_DIRS=""
    for sync_dir in "$DOC"/Documents\ -\ *; do
        [ -d "$sync_dir" ] || continue
        name=$(basename "$sync_dir")
        SIZE=$(du -sh "$sync_dir" 2>/dev/null | cut -f1)
        STALE_DIRS="$STALE_DIRS\n  STALE | $name | $SIZE | Old device sync — review before migrating"
        echo "STALE          | $name | $SIZE" >> "$DATA_CLASS"
    done
    for sync_dir in "$HOME/Desktop"/Desktop\ -\ *; do
        [ -d "$sync_dir" ] || continue
        name=$(basename "$sync_dir")
        SIZE=$(du -sh "$sync_dir" 2>/dev/null | cut -f1)
        STALE_DIRS="$STALE_DIRS\n  STALE | $name | $SIZE | Old device sync — review before migrating"
        echo "STALE          | $name | $SIZE" >> "$DATA_CLASS"
    done

    if [ -n "$STALE_DIRS" ]; then
        echo ""
        warn "Multi-machine sync artifacts found (old device data):"
        echo -e "$STALE_DIRS"
        echo ""
        info "These are from iCloud syncing files from other Macs."
        info "You likely don't need these on the new Mac."
    fi

    # Detect Zoom recordings (archival data)
    ZOOM_DIR="$DOC/Zoom"
    if [ -d "$ZOOM_DIR" ]; then
        ZOOM_SIZE=$(du -sh "$ZOOM_DIR" 2>/dev/null | cut -f1)
        ZOOM_COUNT=$(find "$ZOOM_DIR" -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
        echo ""
        warn "Zoom recordings: $ZOOM_COUNT folders, $ZOOM_SIZE total"
        info "These are archival — consider moving to cloud storage instead of the new Mac"
        echo "ARCHIVAL       | Zoom/ | $ZOOM_SIZE | $ZOOM_COUNT meeting recordings" >> "$DATA_CLASS"
    fi

    # Detect app-generated data directories
    for app_dir in \
        "Adobe"  "Blackmagic Design" "DaVinci Resolve" \
        "Snagit" "Hook" "NoMachine" "WebEx"; do
        if [ -d "$DOC/$app_dir" ]; then
            SIZE=$(du -sh "$DOC/$app_dir" 2>/dev/null | cut -f1)
            echo "APP-DATA       | $app_dir/ | $SIZE | Restore only if app is installed" >> "$DATA_CLASS"
        fi
    done

    # Everything else is user documents
    for item in "$DOC"/*/; do
        [ -d "$item" ] || continue
        name=$(basename "$item")
        # Skip already-classified directories
        case "$name" in
            Zoom|Adobe*|"Blackmagic Design"|"DaVinci Resolve"|Snagit|Hook|NoMachine|WebEx) continue ;;
            Documents\ -\ *) continue ;;
            mac-backup-restore) continue ;;
        esac
        SIZE=$(du -sh "$item" 2>/dev/null | cut -f1)
        echo "DOCUMENTS      | $name/ | $SIZE" >> "$DATA_CLASS"
    done

    log "Data classification → _data-classification.txt"
    echo ""
fi

# ── 5d. Back up personal files (with classification awareness)
if $ICLOUD_ENABLED; then
    info "Since iCloud is enabled, Documents and Desktop will re-sync on the new Mac."
    info "This backup serves as insurance and for organizing data on restore."
    echo ""
fi

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

# ── 5e. Loose photos on Desktop (not screenshots)
PHOTO_COUNT=$(find "$HOME/Desktop" -maxdepth 1 -type f \( -iname "*.jpg" -o -iname "*.jpeg" -o -iname "*.heic" -o -iname "*.raw" -o -iname "*.cr2" -o -iname "*.arw" \) 2>/dev/null | wc -l | tr -d ' ')
if [ "$PHOTO_COUNT" -gt 0 ]; then
    echo ""
    info "Found $PHOTO_COUNT loose photos on Desktop (not screenshots)"
    info "These will be moved to ~/Pictures/ during restore"
fi

# ── 5f. Network Drives ───────────────────────────────────────────────────────
# Network drives mount at /Volumes/ (outside $HOME) so they are not scanned by
# any of the steps above. Detect them and offer to include their contents.
phase "Network Drives"
NET_DRIVES=()

# Parse mount output for network file systems (SMB, AFP, NFS, WebDAV)
while IFS= read -r mount_line; do
    mount_path=$(echo "$mount_line" | awk '{print $3}')
    mount_from=$(echo "$mount_line" | awk '{print $1}')
    # Skip the backup destination drive itself
    [[ "$mount_path" == "$DRIVE"* ]] && continue
    [ -d "$mount_path" ] || continue
    NET_DRIVES+=("$mount_path|$mount_from")
done < <(mount 2>/dev/null | grep -E '^(afp|smb|nfs|cifs|webdav)://')

if [ ${#NET_DRIVES[@]} -gt 0 ]; then
    info "Network drives currently mounted:"
    for nd in "${NET_DRIVES[@]}"; do
        IFS='|' read -r nd_path nd_from <<< "$nd"
        SIZE=$(du -sh "$nd_path" 2>/dev/null | cut -f1)
        echo "    $(basename "$nd_path") ($nd_from) — $SIZE"
    done
    echo ""
    info "Network drives typically reconnect automatically on the new Mac (same network)."
    info "Back up their contents only if the server won't be accessible during the migration,"
    info "or if you want a local snapshot of the data."
    echo ""
    confirm "Include network drive contents in backup?" && {
        for nd in "${NET_DRIVES[@]}"; do
            IFS='|' read -r nd_path nd_from <<< "$nd"
            nd_name=$(basename "$nd_path")
            SIZE=$(du -sh "$nd_path" 2>/dev/null | cut -f1)
            confirm "  Back up $nd_name ($SIZE from $nd_from)?" && {
                mkdir -p "$FILES/network-drives/$nd_name"
                rsync -a --progress \
                    --exclude='.DS_Store' \
                    "$nd_path/" "$FILES/network-drives/$nd_name/" 2>/dev/null
                log "Network drive: $nd_name"
            }
        done
    }
else
    info "No network drives found"
fi

# ── 6. System ───────────────────────────────────────────────────────────────
phase "System Config"
SYS="$BACKUP_DIR/system"
mkdir -p "$SYS"

crontab -l > "$SYS/crontab.txt" 2>/dev/null && log "Crontab" || info "No crontab"

if [ -d "$HOME/Library/LaunchAgents" ] && [ "$(ls -A "$HOME/Library/LaunchAgents")" ]; then
    cp -a "$HOME/Library/LaunchAgents" "$SYS/LaunchAgents" 2>/dev/null && log "Launch Agents"
fi

# ── 7. Copy this toolkit onto the drive ─────────────────────────────────────
# So the new Mac can run restore.sh directly from the drive without needing
# git, internet, or anything pre-installed.
phase "Packaging Restore Toolkit"
TOOLKIT_DEST="$DRIVE/mac-backup-restore"
info "Copying restore toolkit to drive so you can run it on the new Mac..."
rsync -a --delete \
    --exclude='.git' \
    --exclude='*.DS_Store' \
    "$REPO_DIR/" "$TOOLKIT_DEST/" 2>/dev/null
chmod +x "$TOOLKIT_DEST/scripts/"*.sh "$TOOLKIT_DEST/scripts/lib/"*.sh 2>/dev/null || true
log "Toolkit copied → $TOOLKIT_DEST"

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
info "To restore on the new Mac, plug in this drive and run:"
echo ""
echo "    bash $TOOLKIT_DEST/scripts/restore.sh $BACKUP_DIR"
echo ""
sensitive "This backup contains SSH keys, GPG keys, and credentials. Keep it secure."
