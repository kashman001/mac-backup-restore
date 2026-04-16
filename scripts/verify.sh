#!/bin/bash
# =============================================================================
# verify.sh — Post-restore verification checklist
# Run this on the new Mac after restore.sh to confirm everything is working
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/helpers.sh"

header "Post-Restore Verification"

PASS=0
FAIL=0
SKIP=0

check() {
    if eval "$2" 2>/dev/null; then
        log "$1"
        ((PASS++))
    else
        err "$1"
        ((FAIL++))
    fi
}

skip() {
    info "$1 — skipped"
    ((SKIP++))
}

# ── Core Tools ───────────────────────────────────────────────────────────────
phase "Core Tools"

check "Homebrew installed" "has brew"
check "Git installed" "has git"
check "Git configured (user.name)" "git config --global user.name"
check "Git configured (user.email)" "git config --global user.email"

# ── Shell ────────────────────────────────────────────────────────────────────
phase "Shell"

check "Zsh is default shell" "[ \"$SHELL\" = '/bin/zsh' ] || [ \"$SHELL\" = '/opt/homebrew/bin/zsh' ]"
check ".zshrc exists" "[ -f ~/.zshrc ]"

# ── SSH ──────────────────────────────────────────────────────────────────────
phase "SSH"

if [ -d "$HOME/.ssh" ]; then
    check "SSH directory exists" "[ -d ~/.ssh ]"
    check "SSH directory permissions (700)" "[ \$(stat -f '%A' ~/.ssh) = '700' ]"

    if ls ~/.ssh/id_* ~/.ssh/*-GitHub 2>/dev/null | head -1 &>/dev/null; then
        check "SSH keys present" "ls ~/.ssh/id_* ~/.ssh/*-GitHub 2>/dev/null | head -1"

        # Check private key permissions
        for key in ~/.ssh/id_* ~/.ssh/*-GitHub; do
            [ -f "$key" ] || continue
            echo "$key" | grep -q '\.pub$' && continue
            PERM=$(stat -f '%A' "$key" 2>/dev/null)
            if [ "$PERM" = "600" ]; then
                log "  $key permissions OK (600)"
                ((PASS++))
            else
                err "  $key permissions are $PERM (should be 600)"
                ((FAIL++))
            fi
        done
    else
        skip "SSH keys (none found)"
    fi

    if [ -f ~/.ssh/config ]; then
        check "SSH config exists" "[ -f ~/.ssh/config ]"
    fi

    # Test GitHub connectivity
    info "Testing GitHub SSH..."
    if ssh -T git@github.com 2>&1 | grep -q "successfully authenticated"; then
        log "GitHub SSH authentication works"
        ((PASS++))
    else
        warn "GitHub SSH — could not authenticate (may need to add key to GitHub)"
        ((SKIP++))
    fi
else
    skip "SSH (directory not found)"
fi

# ── GPG ──────────────────────────────────────────────────────────────────────
phase "GPG"

if has gpg; then
    if gpg --list-secret-keys 2>/dev/null | grep -q sec; then
        check "GPG secret keys present" "gpg --list-secret-keys 2>/dev/null | grep -q sec"
    else
        skip "GPG keys (none found)"
    fi
else
    skip "GPG (not installed)"
fi

# ── Development Tools ────────────────────────────────────────────────────────
phase "Development Tools"

for tool in node npm python3 pip3; do
    if has "$tool"; then
        VERSION=$($tool --version 2>/dev/null | head -1)
        check "$tool ($VERSION)" "has $tool"
    fi
done

# Editors and their extensions
for editor in code cursor; do
    if has "$editor"; then
        check "$editor CLI available" "has $editor"
        EXT_COUNT=$($editor --list-extensions 2>/dev/null | wc -l | tr -d ' ')
        info "  $editor: $EXT_COUNT extensions installed"
    fi
done

# Docker
if has docker; then
    check "Docker CLI available" "has docker"
    if docker info &>/dev/null; then
        log "Docker daemon running"
        ((PASS++))
    else
        warn "Docker CLI present but daemon not running — open Docker Desktop"
        ((SKIP++))
    fi
fi

# ── Homebrew Health ──────────────────────────────────────────────────────────
phase "Homebrew Health"

if has brew; then
    FORMULA_COUNT=$(brew list --formula 2>/dev/null | wc -l | tr -d ' ')
    CASK_COUNT=$(brew list --cask 2>/dev/null | wc -l | tr -d ' ')
    log "$FORMULA_COUNT formulae, $CASK_COUNT casks installed"
    ((PASS++))

    # Check for common expected tools
    for expected in git gh node python@3.13 ripgrep imagemagick; do
        if brew list --formula "$expected" &>/dev/null; then
            log "  brew: $expected"
            ((PASS++))
        fi
    done

    for expected in visual-studio-code cursor docker iterm2 ghostty; do
        if brew list --cask "$expected" &>/dev/null; then
            log "  cask: $expected"
            ((PASS++))
        fi
    done
fi

# ── Directory Structure ──────────────────────────────────────────────────────
phase "Directory Structure"

check "~/Developer exists" "[ -d ~/Developer ]"
check "~/Developer/personal exists" "[ -d ~/Developer/personal ]"
check "~/Developer/work exists" "[ -d ~/Developer/work ]"
check "~/Developer/oss exists" "[ -d ~/Developer/oss ]"
check "~/Developer/experiments exists" "[ -d ~/Developer/experiments ]"
check "~/Pictures/Screenshots exists" "[ -d ~/Pictures/Screenshots ]"

# Screenshots
SCREENSHOT_FILES=$(find ~/Pictures/Screenshots -type f -name "*.png" 2>/dev/null | wc -l | tr -d ' ')
if [ "$SCREENSHOT_FILES" -gt 0 ]; then
    info "$SCREENSHOT_FILES screenshots in ~/Pictures/Screenshots"
    YEAR_DIRS=$(find ~/Pictures/Screenshots -mindepth 1 -maxdepth 1 -type d -name "[0-9]*" 2>/dev/null | wc -l | tr -d ' ')
    if [ "$YEAR_DIRS" -gt 0 ]; then
        log "Screenshots organized into $YEAR_DIRS year directories"
        ((PASS++))
    fi
else
    info "No screenshots in ~/Pictures/Screenshots (may not have been restored)"
fi

# Count projects
if [ -d "$HOME/Developer" ]; then
    PROJ_COUNT=$(find ~/Developer -maxdepth 3 -name ".git" -type d 2>/dev/null | wc -l | tr -d ' ')
    info "$PROJ_COUNT projects in ~/Developer"
fi

# ── macOS Settings ───────────────────────────────────────────────────────────
phase "macOS Settings"

SCREENSHOT_LOC=$(defaults read com.apple.screencapture location 2>/dev/null || echo "")
if [ "$SCREENSHOT_LOC" = "$HOME/Pictures/Screenshots" ]; then
    log "Screenshots → ~/Pictures/Screenshots"
    ((PASS++))
else
    warn "Screenshots going to: ${SCREENSHOT_LOC:-default (Desktop)}"
    ((SKIP++))
fi

SHOW_EXT=$(defaults read com.apple.finder AppleShowAllExtensions 2>/dev/null || echo "0")
if [ "$SHOW_EXT" = "1" ]; then
    log "Finder: showing file extensions"
    ((PASS++))
else
    info "Finder: file extensions hidden"
    ((SKIP++))
fi

# ── Cloud Configs ────────────────────────────────────────────────────────────
phase "Cloud & Infra"

[ -d ~/.aws ]    && check "AWS config present" "[ -f ~/.aws/config ] || [ -f ~/.aws/credentials ]" || skip "AWS"
[ -d ~/.kube ]   && check "Kubernetes config present" "[ -f ~/.kube/config ]" || skip "Kubernetes"
[ -d ~/.docker ] && check "Docker config present" "[ -d ~/.docker ]" || skip "Docker config"

# ── Applications ─────────────────────────────────────────────────────────────
phase "Key Applications"

EXPECTED_APPS=(
    "1Password.app"
    "Arc.app"
    "Claude.app"
    "Cursor.app"
    "Docker.app"
    "Ghostty.app"
    "Google Chrome.app"
    "JetBrains Toolbox.app"
    "Obsidian.app"
    "Steam.app"
    "Visual Studio Code.app"
    "Warp.app"
    "iTerm.app"
)

for app in "${EXPECTED_APPS[@]}"; do
    if [ -d "/Applications/$app" ]; then
        log "$app"
        ((PASS++))
    else
        warn "Missing: $app"
        ((FAIL++))
    fi
done

# ── Browser Extensions & App Plugins ─────────────────────────────────────────
phase "Extensions & Plugins"

# Chrome extensions
CHROME_EXT="$HOME/Library/Application Support/Google/Chrome/Default/Extensions"
if [ -d "$CHROME_EXT" ]; then
    CHROME_COUNT=$(ls -1d "$CHROME_EXT"/*/ 2>/dev/null | wc -l | tr -d ' ')
    info "Chrome: $CHROME_COUNT extensions installed"
fi

# Arc extensions
ARC_EXT="$HOME/Library/Application Support/Arc/User Data/Default/Extensions"
if [ -d "$ARC_EXT" ]; then
    ARC_COUNT=$(ls -1d "$ARC_EXT"/*/ 2>/dev/null | wc -l | tr -d ' ')
    info "Arc: $ARC_COUNT extensions installed"
fi

# PyCharm plugins
PYCHARM_PLUGINS=$(find "$HOME/Library/Application Support/JetBrains" -maxdepth 2 -path "*/PyCharm*/plugins" -type d 2>/dev/null | sort -V | tail -1)
if [ -n "$PYCHARM_PLUGINS" ] && [ -d "$PYCHARM_PLUGINS" ]; then
    PC_COUNT=$(ls -1 "$PYCHARM_PLUGINS" 2>/dev/null | wc -l | tr -d ' ')
    info "PyCharm: $PC_COUNT user plugins installed"
fi

# ── Steam ────────────────────────────────────────────────────────────────────
phase "Steam & Games"

if [ -d "/Applications/Steam.app" ]; then
    check "Steam installed" "[ -d /Applications/Steam.app ]"
    STEAM_MANIFESTS=$(ls "$HOME/Library/Application Support/Steam/steamapps"/appmanifest_*.acf 2>/dev/null | wc -l | tr -d ' ')
    info "$STEAM_MANIFESTS games currently installed in Steam"
fi

if [ -d "/Applications/CrossOver.app" ]; then
    check "CrossOver installed" "[ -d /Applications/CrossOver.app ]"
    BOTTLE_COUNT=$(ls "$HOME/Library/Application Support/CrossOver/Bottles/" 2>/dev/null | wc -l | tr -d ' ')
    info "$BOTTLE_COUNT CrossOver bottles present"
fi

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
header "Verification Results"
echo ""
echo -e "  ${GREEN}Passed:  $PASS${NC}"
echo -e "  ${RED}Failed:  $FAIL${NC}"
echo -e "  ${BLUE}Skipped: $SKIP${NC}"
echo ""

if [ "$FAIL" -eq 0 ]; then
    log "Everything looks good! Your new Mac is ready."
else
    warn "$FAIL items need attention. Review the failures above."
fi
