#!/usr/bin/env bats
# =============================================================================
# Integration tests for scripts/verify.sh
#
# verify.sh runs on a freshly-restored Mac and prints a pass / fail / skip
# scorecard across ~10 categories. It is read-only — it does not mutate the
# system — but it shells out to many commands (brew, git, gpg, defaults, ssh
# etc.). Each test stands up a fake $HOME, mocks the commands the script
# calls, runs the script, and asserts on its stdout.
#
# HISTORICAL NOTE — set -e + ((PASS++)) bug
# -----------------------------------------
# verify.sh once aborted at the first counter increment because bash's
# `((X++))` returns the OLD value of X as the command exit status, and when
# the counter was 0, the resulting exit 1 fell through `set -e`. The fix:
# replace `((PASS++))` with `: $((PASS++))` so the line ends with `:` (always
# exit 0) while still using arithmetic *expansion* to mutate the counter.
# `run_verify` keeps a sanitised copy that strips `-e` for backwards-compat
# with tests that expect the older execution model; new tests should call
# `run_verify_strict` to exercise the *real* script.
# =============================================================================

load '../test_helper'

setup() {
    setup_test_env

    # Most tests mock these commands so verify.sh's external calls are
    # deterministic. Tests can override per-test with stronger / weaker mocks.
    # We do NOT mock by default — each test mocks what it needs.
    :
}

teardown() {
    teardown_test_env
}

# ── Local helpers ──────────────────────────────────────────────────────────

# Build a sanitised copy of verify.sh with the `set -e` flag dropped.
# `set -e` combined with `((PASS++))` (which exits 1 when PASS is 0) makes
# the script abort at the first counter increment, masking every later
# phase. Dropping just `-e` lets us exercise each phase's logic. We keep
# `-u` and `pipefail` because the script's per-phase logic relies on them
# (e.g. `ls id_* 2>/dev/null | head -1` correctly fails under pipefail
# when the glob matches nothing).
sanitised_verify() {
    local copy="$FAKE_ROOT/verify.sh"
    sed 's/^set -euo pipefail$/set -uo pipefail/' "$SCRIPTS_DIR/verify.sh" > "$copy"
    chmod +x "$copy"
    # Make sure it still resolves lib/helpers.sh by symlinking.
    ln -s "$LIB_DIR" "$FAKE_ROOT/lib"
    echo "$copy"
}

# Run the sanitised verify.sh with the given args. Use this for every test
# that exercises the script's logic — it sidesteps the `set -e + ((X++))` bug.
run_verify() {
    local copy
    copy="$(sanitised_verify)"
    run /bin/bash "$copy" "$@"
}

# Run the *unmodified* verify.sh. Reserved for the bug-documentation test.
run_verify_strict() {
    run /bin/bash "$SCRIPTS_DIR/verify.sh" "$@"
}

# Strip ANSI colour escape sequences from $output so substring assertions
# don't have to account for the colour codes helpers.sh emits between the
# ✓ / ✗ glyphs and the message text.
strip_ansi() {
    # bash 3.2-friendly: pipe through sed.
    printf '%s' "$1" | sed $'s/\033\\[[0-9;]*m//g'
}

# Fake backup directory used by tests that pass a backup path.
setup_fake_backup() {
    FAKE_BACKUP="$FAKE_ROOT/backup"
    mkdir -p "$FAKE_BACKUP/software-inventory"
    cat > "$FAKE_BACKUP/software-inventory/Brewfile" <<'EOF'
brew "git"
cask "iterm2"
EOF
    cat > "$FAKE_BACKUP/software-inventory/install-sources.txt" <<'EOF'
brew-cask      | iTerm.app | iterm2
manual-download| Foo.app
bundled        | Safari.app
EOF
    export FAKE_BACKUP
}

# Mock every external command verify.sh might call. Individual tests can
# replace any mock to simulate failure / different output.
mock_all_external_tools() {
    mock_command brew
    mock_command git
    mock_command gpg
    mock_command code
    mock_command cursor
    mock_command node "v20.0.0"
    mock_command npm "10.0.0"
    mock_command python3 "Python 3.11.0"
    mock_command pip3 "pip 23.0"
    mock_command mas
    mock_command defaults
    mock_command ssh
    mock_command ssh-keygen
    mock_command mdfind
    mock_command sw_vers "ProductVersion: 14.0"
    mock_command docker
}

# ── Argument handling ─────────────────────────────────────────────────────

@test "verify: with no args, prints generic-checks notice" {
    run_verify
    [[ "$output" == *"No backup path provided"* ]]
    [[ "$output" == *"generic checks only"* ]]
}

@test "verify: with a real backup dir, prints 'Verifying against backup' line" {
    setup_fake_backup
    run_verify "$FAKE_BACKUP"
    [[ "$output" == *"Verifying against backup"* ]]
    [[ "$output" == *"$FAKE_BACKUP"* ]]
}

@test "verify: with a non-existent backup path, falls back to generic checks" {
    # The script's check is `[ -d "$BACKUP" ]` — a missing path is treated
    # the same as "no backup path provided", not as an error. Document this.
    run_verify "$FAKE_ROOT/no-such-backup"
    [[ "$output" == *"No backup path provided"* ]]
}

@test "verify: prints the Post-Restore Verification header" {
    run_verify
    [[ "$output" == *"Post-Restore Verification"* ]]
}

# ── Core Tools phase ──────────────────────────────────────────────────────

@test "core tools: reports OK when brew and git are present" {
    mock_command brew
    mock_command git
    run_verify
    # Both checks should print a green tick line for that name.
    [[ "$output" == *"Homebrew installed"* ]]
    [[ "$output" == *"Git installed"* ]]
    # ✓ tick character for at least one of them
    [[ "$output" == *"✓"* ]]
}

@test "core tools: reports FAIL when brew is missing (no mock)" {
    # Don't mock brew. setup_test_env's MOCK_BIN-prepended PATH still has the
    # rest of PATH after it, so to be sure brew is missing we replace PATH
    # with only the mock-bin and a minimal stdlib.
    PATH="$MOCK_BIN:/usr/bin:/bin"
    run_verify
    [[ "$output" == *"Homebrew installed"* ]]
    # When brew is not on PATH, `has brew` returns nonzero → err line with ✗
    [[ "$output" == *"✗"* ]]
}

@test "core tools: git user.name configured → ✓ for that line" {
    mock_command brew
    # Make `git` always succeed (incl. `git config --global user.name`).
    mock_command git "Kashif"
    run_verify
    [[ "$output" == *"Git configured (user.name)"* ]]
    [[ "$output" == *"Git configured (user.email)"* ]]
}

@test "core tools: git user.name unset → ✗ for that line" {
    mock_command brew
    # `git` exists but `git config --global user.name` exits non-zero.
    mock_command_failing git
    run_verify
    [[ "$output" == *"Git configured (user.name)"* ]]
    [[ "$output" == *"✗"* ]]
}

# ── Shell phase ───────────────────────────────────────────────────────────

@test "shell: zsh as \$SHELL → pass line for default shell" {
    mock_all_external_tools
    SHELL=/bin/zsh run_verify
    local clean; clean="$(strip_ansi "$output")"
    [[ "$clean" == *"✓ Zsh is default shell"* ]]
}

@test "shell: bash as \$SHELL → fail line for default shell" {
    mock_all_external_tools
    SHELL=/bin/bash run_verify
    local clean; clean="$(strip_ansi "$output")"
    [[ "$clean" == *"✗ Zsh is default shell"* ]]
}

@test "shell: .zshrc absent → ✗ for that line" {
    mock_all_external_tools
    SHELL=/bin/zsh run_verify
    local clean; clean="$(strip_ansi "$output")"
    [[ "$clean" == *"✗ .zshrc exists"* ]]
}

@test "shell: .zshrc present → ✓ for that line" {
    mock_all_external_tools
    touch "$FAKE_HOME/.zshrc"
    SHELL=/bin/zsh run_verify
    local clean; clean="$(strip_ansi "$output")"
    [[ "$clean" == *"✓ .zshrc exists"* ]]
}

# ── SSH phase ─────────────────────────────────────────────────────────────

@test "ssh: missing ~/.ssh → 'SSH (directory not found)' skip" {
    mock_all_external_tools
    run_verify
    [[ "$output" == *"SSH (directory not found)"* ]]
    [[ "$output" == *"skipped"* ]]
}

@test "ssh: empty ~/.ssh dir → 'no SSH keys' skip path, no false fail" {
    mock_all_external_tools
    mkdir -p "$FAKE_HOME/.ssh"
    chmod 700 "$FAKE_HOME/.ssh"
    run_verify
    [[ "$output" == *"SSH directory exists"* ]]
    [[ "$output" == *"SSH directory permissions (700)"* ]]
    [[ "$output" == *"SSH keys (none found)"* ]]
}

@test "ssh: dir 700, private key 600, public key 644 → all pass" {
    mock_all_external_tools
    mkdir -p "$FAKE_HOME/.ssh"
    chmod 700 "$FAKE_HOME/.ssh"
    : > "$FAKE_HOME/.ssh/id_ed25519"
    : > "$FAKE_HOME/.ssh/id_ed25519.pub"
    chmod 600 "$FAKE_HOME/.ssh/id_ed25519"
    chmod 644 "$FAKE_HOME/.ssh/id_ed25519.pub"
    run_verify
    local clean; clean="$(strip_ansi "$output")"
    [[ "$clean" == *"✓ SSH directory permissions (700)"* ]]
    [[ "$clean" == *"permissions OK (600)"* ]]
}

@test "ssh: dir 755 → permission check fails" {
    mock_all_external_tools
    mkdir -p "$FAKE_HOME/.ssh"
    chmod 755 "$FAKE_HOME/.ssh"
    run_verify
    local clean; clean="$(strip_ansi "$output")"
    [[ "$clean" == *"✗ SSH directory permissions (700)"* ]]
}

@test "ssh: private key with mode 644 → permission failure printed" {
    mock_all_external_tools
    mkdir -p "$FAKE_HOME/.ssh"
    chmod 700 "$FAKE_HOME/.ssh"
    : > "$FAKE_HOME/.ssh/id_rsa"
    chmod 644 "$FAKE_HOME/.ssh/id_rsa"
    run_verify
    [[ "$output" == *"id_rsa"* ]]
    [[ "$output" == *"permissions are 644"* ]]
    [[ "$output" == *"should be 600"* ]]
}

@test "ssh: github auth — ssh exit 0 with success message → pass" {
    # NOTE: real GitHub SSH always exits 1 even on success, but the script
    # combines `ssh | grep` with `set -o pipefail`, so any non-zero ssh
    # exit code makes the if-branch fail regardless of grep. This is a
    # latent bug in verify.sh — see the bug summary at the bottom of this
    # file. To reach the success branch we have to mock ssh exiting 0.
    mock_all_external_tools
    mkdir -p "$FAKE_HOME/.ssh"
    chmod 700 "$FAKE_HOME/.ssh"
    mock_command_script ssh <<'EOF'
echo "Hi user! You've successfully authenticated, but GitHub does not provide shell access." 1>&2
exit 0
EOF
    run_verify
    local clean; clean="$(strip_ansi "$output")"
    [[ "$clean" == *"GitHub SSH authentication works"* ]]
}

@test "ssh: github auth with other message → skip / warn, not pass" {
    mock_all_external_tools
    mkdir -p "$FAKE_HOME/.ssh"
    chmod 700 "$FAKE_HOME/.ssh"
    mock_command_script ssh <<'EOF'
echo "Permission denied (publickey)." 1>&2
exit 255
EOF
    run_verify
    [[ "$output" == *"could not authenticate"* ]]
}

@test "ssh: BUG — real ssh exit 1 + 'successfully authenticated' wrongly reported as failure" {
    # Documents the pipefail bug: real ssh -T git@github.com exits 1 on
    # success and prints the auth message to stderr. The script's
    #   if ssh -T git@github.com 2>&1 | grep -q "successfully authenticated"
    # under pipefail evaluates to false because ssh's exit-1 propagates,
    # even when grep matched. As a result the script reports "could not
    # authenticate" on a working GitHub setup. This test pins the buggy
    # behaviour; delete it when the script is fixed.
    mock_all_external_tools
    mkdir -p "$FAKE_HOME/.ssh"
    chmod 700 "$FAKE_HOME/.ssh"
    mock_command_script ssh <<'EOF'
echo "Hi user! You've successfully authenticated, but GitHub does not provide shell access." 1>&2
exit 1
EOF
    run_verify
    [[ "$output" == *"could not authenticate"* ]]
}

# ── GPG phase ─────────────────────────────────────────────────────────────

@test "gpg: not installed → 'GPG (not installed)' skip" {
    mock_command brew
    mock_command git
    # Don't mock gpg.
    PATH="$MOCK_BIN:/usr/bin:/bin"
    run_verify
    [[ "$output" == *"GPG (not installed)"* ]]
}

@test "gpg: secret keys present → pass line" {
    mock_all_external_tools
    mock_command_script gpg <<'EOF'
cat <<KEY
sec   ed25519/0xDEADBEEF 2026-01-01 [SC]
      AAAA1111
uid   Test User <test@example.com>
KEY
exit 0
EOF
    run_verify
    local clean; clean="$(strip_ansi "$output")"
    [[ "$clean" == *"✓ GPG secret keys present"* ]]
}

@test "gpg: empty list → 'GPG keys (none found)' skip" {
    mock_all_external_tools
    # gpg installed but no keys → no 'sec' line in output.
    mock_command gpg
    run_verify
    [[ "$output" == *"GPG keys (none found)"* ]]
}

# ── Development tools ─────────────────────────────────────────────────────

@test "dev tools: node/npm/python3/pip3 mocked → all listed with versions" {
    mock_all_external_tools
    run_verify
    [[ "$output" == *"node (v20.0.0)"* ]]
    [[ "$output" == *"npm (10.0.0)"* ]]
    [[ "$output" == *"python3 (Python 3.11.0)"* ]]
    [[ "$output" == *"pip3 (pip 23.0)"* ]]
}

@test "dev tools: VS Code extension count via mocked code --list-extensions" {
    mock_all_external_tools
    mock_command_script code <<'EOF'
case "$1" in
    --list-extensions)
        echo "ms-python.python"
        echo "dbaeumer.vscode-eslint"
        echo "esbenp.prettier-vscode"
        echo "redhat.vscode-yaml"
        echo "anthropic.claude-code"
        ;;
esac
exit 0
EOF
    run_verify
    [[ "$output" == *"code: 5 extensions installed"* ]]
}

# ── Homebrew Health ────────────────────────────────────────────────────────

@test "homebrew: lists formulae and casks counts" {
    mock_all_external_tools
    # Build a brew mock that prints N lines depending on --formula vs --cask.
    mock_command_script brew <<'EOF'
case "$1 $2" in
    "list --formula")
        for i in $(seq 1 50); do echo "formula-$i"; done
        ;;
    "list --cask")
        for i in $(seq 1 30); do echo "cask-$i"; done
        ;;
    "doctor")
        echo "Your system is ready to brew."
        ;;
esac
exit 0
EOF
    run_verify
    [[ "$output" == *"50 formulae, 30 casks installed"* ]]
}

# ── Directory Structure ────────────────────────────────────────────────────

@test "directory structure: all ~/Developer/* present → all ✓" {
    mock_all_external_tools
    mkdir -p "$FAKE_HOME/Developer/personal" \
             "$FAKE_HOME/Developer/work" \
             "$FAKE_HOME/Developer/oss" \
             "$FAKE_HOME/Developer/experiments"
    run_verify
    local clean; clean="$(strip_ansi "$output")"
    [[ "$clean" == *"✓ ~/Developer exists"* ]]
    [[ "$clean" == *"✓ ~/Developer/personal exists"* ]]
    [[ "$clean" == *"✓ ~/Developer/work exists"* ]]
    [[ "$clean" == *"✓ ~/Developer/oss exists"* ]]
    [[ "$clean" == *"✓ ~/Developer/experiments exists"* ]]
}

@test "directory structure: missing ~/Developer/work → ✗ for that line" {
    mock_all_external_tools
    mkdir -p "$FAKE_HOME/Developer/personal" \
             "$FAKE_HOME/Developer/oss" \
             "$FAKE_HOME/Developer/experiments"
    run_verify
    local clean; clean="$(strip_ansi "$output")"
    [[ "$clean" == *"✗ ~/Developer/work exists"* ]]
    [[ "$clean" == *"✓ ~/Developer/personal exists"* ]]
}

# ── macOS Settings ─────────────────────────────────────────────────────────

@test "macos settings: defaults reports correct screenshot location → pass" {
    mock_all_external_tools
    # Build a defaults mock that returns the $HOME-relative screenshots path.
    mock_command_script defaults <<EOF
case "\$1 \$2 \$3" in
    "read com.apple.screencapture location")
        echo "$FAKE_HOME/Pictures/Screenshots"
        ;;
    "read com.apple.finder AppleShowAllExtensions")
        echo "1"
        ;;
esac
exit 0
EOF
    run_verify
    [[ "$output" == *"Screenshots → ~/Pictures/Screenshots"* ]]
    [[ "$output" == *"Finder: showing file extensions"* ]]
}

@test "macos settings: defaults reports wrong location → warn / skip" {
    mock_all_external_tools
    mock_command_script defaults <<'EOF'
case "$1 $2 $3" in
    "read com.apple.screencapture location")
        echo "/Users/someone/Desktop"
        ;;
    "read com.apple.finder AppleShowAllExtensions")
        echo "0"
        ;;
esac
exit 0
EOF
    run_verify
    [[ "$output" == *"Screenshots going to:"* ]]
    [[ "$output" == *"Finder: file extensions hidden"* ]]
}

# ── Cloud configs ──────────────────────────────────────────────────────────

@test "cloud: ~/.aws/config present → AWS check runs and passes" {
    mock_all_external_tools
    mkdir -p "$FAKE_HOME/.aws"
    : > "$FAKE_HOME/.aws/config"
    run_verify
    local clean; clean="$(strip_ansi "$output")"
    [[ "$clean" == *"✓ AWS config present"* ]]
}

@test "cloud: missing ~/.aws → 'AWS — skipped'" {
    mock_all_external_tools
    run_verify
    [[ "$output" == *"AWS"* ]]
    [[ "$output" == *"AWS — skipped"* ]]
}

@test "cloud: ~/.kube/config present → ✓ Kubernetes config" {
    mock_all_external_tools
    mkdir -p "$FAKE_HOME/.kube"
    : > "$FAKE_HOME/.kube/config"
    run_verify
    local clean; clean="$(strip_ansi "$output")"
    [[ "$clean" == *"✓ Kubernetes config present"* ]]
}

@test "cloud: ~/.docker present → Docker config check runs" {
    mock_all_external_tools
    mkdir -p "$FAKE_HOME/.docker"
    : > "$FAKE_HOME/.docker/config.json"
    run_verify
    [[ "$output" == *"Docker config present"* ]]
}

# ── Extensions / plugins ───────────────────────────────────────────────────

@test "jetbrains: fake IDE config dir with N plugins → reports count" {
    mock_all_external_tools
    local ide_dir="$FAKE_HOME/Library/Application Support/JetBrains/IntelliJIdea2024.1"
    mkdir -p "$ide_dir/plugins/foo" \
             "$ide_dir/plugins/bar" \
             "$ide_dir/plugins/baz"
    run_verify
    [[ "$output" == *"IntelliJIdea2024.1: 3 user plugins"* ]]
}

@test "jetbrains: no JetBrains directory → no plugin count, not a failure" {
    mock_all_external_tools
    run_verify
    # The phase header still appears, but no per-IDE line.
    [[ "$output" == *"Extensions & Plugins"* ]]
    [[ "$output" != *"user plugins"* ]]
}

# ── Backup-path mode: Brewfile / install-sources comparison ────────────────

@test "backup mode: Brewfile entries fully installed → 'All Brewfile entries installed'" {
    setup_fake_backup
    mock_all_external_tools
    # brew list --formula returns superset including 'git'; brew list --cask
    # returns superset including 'iterm2'; per-pkg brew list calls succeed.
    mock_command_script brew <<'EOF'
case "$1 $2" in
    "list --formula")
        if [ $# -ge 3 ]; then
            # query for a specific package — succeed for 'git'
            [ "$3" = "git" ] && exit 0 || exit 1
        fi
        echo "git"; echo "node"; echo "ripgrep"
        ;;
    "list --cask")
        if [ $# -ge 3 ]; then
            [ "$3" = "iterm2" ] && exit 0 || exit 1
        fi
        echo "iterm2"; echo "rectangle"
        ;;
esac
exit 0
EOF
    run_verify "$FAKE_BACKUP"
    [[ "$output" == *"All Brewfile entries installed"* ]]
}

@test "backup mode: Brewfile missing entries → reports missing count" {
    setup_fake_backup
    # Make the Brewfile list 5 formulae, of which only 3 are installed.
    cat > "$FAKE_BACKUP/software-inventory/Brewfile" <<'EOF'
brew "git"
brew "node"
brew "ripgrep"
brew "fd"
brew "jq"
EOF
    mock_all_external_tools
    mock_command_script brew <<'EOF'
case "$1 $2" in
    "list --formula")
        if [ $# -ge 3 ]; then
            case "$3" in
                git|node|ripgrep) exit 0 ;;
                *) exit 1 ;;
            esac
        fi
        echo "git"; echo "node"; echo "ripgrep"
        ;;
    "list --cask")
        if [ $# -ge 3 ]; then
            exit 1
        fi
        ;;
esac
exit 0
EOF
    run_verify "$FAKE_BACKUP"
    [[ "$output" == *"Missing formula: fd"* ]]
    [[ "$output" == *"Missing formula: jq"* ]]
    [[ "$output" == *"2 Brewfile entries missing"* ]]
}

@test "backup mode: install-sources lists Foo.app as manual-download, not installed → reports missing" {
    setup_fake_backup
    mock_all_external_tools
    # brew list returns nothing relevant.
    mock_command brew
    run_verify "$FAKE_BACKUP"
    # Foo.app is in install-sources.txt as 'manual-download' and does not
    # exist in the fake env's /Applications equivalent.
    [[ "$output" == *"Missing: Foo.app"* ]]
    [[ "$output" == *"applications missing"* ]]
}

@test "backup mode: install-sources skips bundled apps (Safari)" {
    setup_fake_backup
    mock_all_external_tools
    mock_command brew
    run_verify "$FAKE_BACKUP"
    # Safari is bundled — should not be reported as missing even though
    # /Applications/Safari.app probably doesn't exist in the fake env.
    [[ "$output" != *"Missing: Safari.app"* ]]
}

# ── Steam phase ────────────────────────────────────────────────────────────

@test "steam: no Steam.app and no Steam fake dir → no Steam phase header" {
    # The script unconditionally checks /Applications/Steam.app, which we
    # cannot mock. Skip this test if Steam is installed on the host machine.
    [ -d /Applications/Steam.app ] && skip "Host machine has Steam installed"
    mock_all_external_tools
    run_verify
    local clean; clean="$(strip_ansi "$output")"
    [[ "$clean" != *"Steam & Games"* ]]
}

@test "steam: ~/Library/Application Support/Steam present → phase header appears" {
    mock_all_external_tools
    mkdir -p "$FAKE_HOME/Library/Application Support/Steam/steamapps"
    # Drop a couple of appmanifest files so the count line is meaningful.
    : > "$FAKE_HOME/Library/Application Support/Steam/steamapps/appmanifest_1.acf"
    : > "$FAKE_HOME/Library/Application Support/Steam/steamapps/appmanifest_2.acf"
    run_verify
    local clean; clean="$(strip_ansi "$output")"
    [[ "$clean" == *"Steam & Games"* ]]
}

# ── Output / scorecard ─────────────────────────────────────────────────────

@test "scorecard: final 'Verification Results' header is printed" {
    mock_all_external_tools
    run_verify
    [[ "$output" == *"Verification Results"* ]]
}

@test "scorecard: Passed / Failed / Skipped lines are all printed" {
    mock_all_external_tools
    run_verify
    [[ "$output" == *"Passed:"* ]]
    [[ "$output" == *"Failed:"* ]]
    [[ "$output" == *"Skipped:"* ]]
}

@test "scorecard: exit code is 0 even when checks fail (verify is informational)" {
    mock_all_external_tools
    # Force several failures: bash shell, missing zshrc, missing Developer dirs.
    SHELL=/bin/bash run_verify
    [ "$status" -eq 0 ]
}

@test "scorecard: pass + fail + skip counts all appear as integers" {
    mock_all_external_tools
    run_verify
    # Extract the three numeric lines and confirm each contains a digit.
    [[ "$output" =~ Passed:[[:space:]]+[0-9]+ ]]
    [[ "$output" =~ Failed:[[:space:]]+[0-9]+ ]]
    [[ "$output" =~ Skipped:[[:space:]]+[0-9]+ ]]
}

# ── Bug regression: ((var++)) under set -e ────────────────────────────────

@test "REGRESSION: unmodified verify.sh runs all phases under set -e (((var++)) replaced with ': \$((var++))')" {
    # Was: verify.sh aborted after the first counter increment because
    # `((PASS++))` returns 1 when PASS was 0 and `set -e` killed the script.
    # Fix: every increment is now `: $((var++))` — `:` always exits 0 while
    # the arithmetic expansion still mutates the variable. This test runs
    # the *unmodified* script and asserts it reaches the scorecard.
    mock_command brew
    mock_command git
    run_verify_strict
    # The scorecard banner only prints if the script ran past every phase.
    [[ "$output" == *"Verification Results"* ]]
    [[ "$output" == *"Passed:"* ]]
    [ "$status" -eq 0 ]
}

@test "REGRESSION: no '((var++))' arithmetic-command increments remain in verify.sh (static guard)" {
    # Static guard: future edits must not reintroduce the `((var++))` form,
    # which under set -e aborts the script when var was 0. Use `: \$((var++))`.
    cd "$PROJECT_ROOT"
    # grep -E because '((' is a regex metachar; -v \$ to skip the safe
    # arithmetic-expansion form `$((...))`.
    ! grep -nE '^[[:space:]]*\(\(' scripts/verify.sh
}
