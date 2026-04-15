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
    info "$1 — skipped (not applicable)"
    ((SKIP++))
}

# ── Homebrew ─────────────────────────────────────────────────────────────────
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

    # Check for at least one key pair
    if ls ~/.ssh/id_* &>/dev/null; then
        check "SSH keys present" "ls ~/.ssh/id_* &>/dev/null"
        check "SSH key permissions" "[ \$(stat -f '%A' ~/.ssh/id_ed25519 2>/dev/null || stat -f '%A' ~/.ssh/id_rsa 2>/dev/null) = '600' ]"
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

# Editors
for editor in code cursor; do
    if has "$editor"; then
        check "$editor CLI available" "has $editor"
    fi
done

# ── Directory Structure ──────────────────────────────────────────────────────
phase "Directory Structure"

check "~/Developer exists" "[ -d ~/Developer ]"
check "~/Developer/personal exists" "[ -d ~/Developer/personal ]"
check "~/Developer/work exists" "[ -d ~/Developer/work ]"
check "~/Pictures/Screenshots exists" "[ -d ~/Pictures/Screenshots ]"

# Count projects
if [ -d "$HOME/Developer" ]; then
    PROJ_COUNT=$(find ~/Developer -maxdepth 3 -name ".git" -type d 2>/dev/null | wc -l | tr -d ' ')
    info "$PROJ_COUNT projects found in ~/Developer"
fi

# ── Cloud Configs ────────────────────────────────────────────────────────────
phase "Cloud & Infra"

[ -d ~/.aws ]    && check "AWS config present" "[ -f ~/.aws/config ] || [ -f ~/.aws/credentials ]" || skip "AWS"
[ -d ~/.kube ]   && check "Kubernetes config present" "[ -f ~/.kube/config ]" || skip "Kubernetes"
[ -d ~/.docker ] && check "Docker config present" "[ -d ~/.docker ]" || skip "Docker"

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
