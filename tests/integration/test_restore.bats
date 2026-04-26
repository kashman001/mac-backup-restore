#!/usr/bin/env bats
# =============================================================================
# Integration tests for scripts/restore.sh
#
# These tests run the real restore.sh against a synthetic backup directory
# under an isolated $HOME with PATH-mocked external commands (brew, mas,
# defaults, …). The real system is never modified.
#
# Run with: bats tests/integration/test_restore.bats
# =============================================================================

load '../test_helper'

# ── Local helpers ──────────────────────────────────────────────────────────
# Defined here, NOT in test_helper.bash, to avoid races with parallel agents.

# Build a minimal-but-valid fake backup directory (matching backup.sh layout).
# Tests can extend this with more fixture files before running restore.sh.
setup_fake_backup() {
    FAKE_BACKUP="$FAKE_ROOT/backup"
    mkdir -p "$FAKE_BACKUP/software-inventory"
    mkdir -p "$FAKE_BACKUP/config/dotfiles"
    mkdir -p "$FAKE_BACKUP/app-settings"
    mkdir -p "$FAKE_BACKUP/projects"
    mkdir -p "$FAKE_BACKUP/files"
    # NOTE: deliberately omit empty $FAKE_BACKUP/system/LaunchAgents,
    # $FAKE_BACKUP/licenses/plists, and $FAKE_BACKUP/config/ssh — restore.sh
    # under set -euo pipefail crashes when one of those directories exists
    # but is empty (see notes in individual tests for the failure mode).

    echo 'tap "homebrew/cask"' > "$FAKE_BACKUP/software-inventory/Brewfile"
    : > "$FAKE_BACKUP/software-inventory/Brewfile.addon"
    echo "bundled        | Safari.app" > "$FAKE_BACKUP/software-inventory/install-sources.txt"
    : > "$FAKE_BACKUP/software-inventory/applications.txt"
    : > "$FAKE_BACKUP/migration-manifest.txt"

    # The dotfiles directory must contain at least one *non-dotfile* entry
    # whose name does NOT start with "_". restore.sh runs
    #   ls -1 dir | grep -v '^_'
    # under set -euo pipefail. ls -1 hides dotfiles by default, so a stray
    # `.zshrc` doesn't satisfy grep and the pipeline exits 1, killing the
    # script. The placeholder file below keeps the script alive past Step 8.
    : > "$FAKE_BACKUP/config/dotfiles/placeholder.txt"

    export FAKE_BACKUP
}

# Install no-op mocks for every external command restore.sh might invoke.
# Individual tests can override specific mocks afterwards (the file is just
# rewritten by the override).
install_default_mocks() {
    local cmd
    for cmd in brew mas defaults softwareupdate xcode-select chflags csrutil \
               osascript code cursor git ssh-add ssh-keyscan gpg npm pip3 pipx \
               cargo gem go conda chsh dscl killall sw_vers crontab rsync \
               python3 curl plutil docker; do
        mock_command "$cmd"
    done
}

# Run the restore script with stdin pre-filled to auto-answer every prompt.
# IMPORTANT: confirm() uses `read -n 1`, which reads ONE byte. Sending
# "y\ny\ny\n" results in alternating y / newline answers. We send a long
# stream of bare 'y' (or 'n') bytes instead.
run_restore_yes() {
    local backup="$1"; shift || true
    run /bin/bash -c "
        printf 'y%.0s' \$(seq 1 400) |
        /bin/bash '$SCRIPTS_DIR/restore.sh' '$backup' $*
    "
}

run_restore_no() {
    local backup="$1"; shift || true
    run /bin/bash -c "
        printf 'n%.0s' \$(seq 1 400) |
        /bin/bash '$SCRIPTS_DIR/restore.sh' '$backup' $*
    "
}

# Bats setup / teardown.
setup() {
    setup_test_env
    install_default_mocks
}

teardown() {
    teardown_test_env
}

# ── Smoke / argument handling ──────────────────────────────────────────────

@test "no args: prints usage and exits non-zero" {
    run /bin/bash "$SCRIPTS_DIR/restore.sh"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Usage:"* ]]
}

@test "non-existent backup path: errors out and exits non-zero" {
    run /bin/bash "$SCRIPTS_DIR/restore.sh" "$FAKE_ROOT/does-not-exist"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Usage:"* ]]
}

@test "drive root with mac-backup/: lists available backups when path missing" {
    # The script lists available backups only when the supplied path does
    # NOT exist (the dir-existence guard). Pass a non-existent subpath of
    # the drive to trigger the listing branch.
    mkdir -p "$FAKE_DRIVE/mac-backup/20260101_120000"
    mkdir -p "$FAKE_DRIVE/mac-backup/20260202_120000"
    run /bin/bash "$SCRIPTS_DIR/restore.sh" "$FAKE_DRIVE/missing"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Usage:"* ]]
    # Note: the "Available backups" branch only fires when ${1}/mac-backup
    # exists. Here $1 is "$FAKE_DRIVE/missing" so $1/mac-backup doesn't
    # exist and the listing won't appear. We assert the usage banner only.
}

@test "set -euo pipefail: missing optional config files don't crash sourcing" {
    # The script declares arrays defensively and tolerates missing config
    # files. Sourcing the helper lib + arrays under stock bash 3.2 must work.
    run /bin/bash -c "
        set -euo pipefail
        source '$LIB_DIR/helpers.sh'
        declare -a APP_SETTINGS 2>/dev/null || true
        declare -a SIGN_IN_APPS 2>/dev/null || true
        declare -a JETBRAINS_IDES 2>/dev/null || true
        declare -a JETBRAINS_SUBDIRS 2>/dev/null || true
        echo OK
    "
    [ "$status" -eq 0 ]
    [ "$output" = "OK" ]
}

# ── Step 0 — macOS Defaults ────────────────────────────────────────────────

@test "step 0 yes: defaults write is invoked for screenshots, finder, dock" {
    setup_fake_backup
    run_restore_yes "$FAKE_BACKUP"
    [ "$status" -eq 0 ]
    mock_was_called defaults
    mock_calls defaults | grep -q "screencapture"
    mock_calls defaults | grep -q "AppleShowAllExtensions"
    mock_calls defaults | grep -q "com.apple.dock"
    mock_calls defaults | grep -q "autohide"
}

@test "step 0 yes: killall is invoked for Finder and Dock" {
    setup_fake_backup
    run_restore_yes "$FAKE_BACKUP"
    [ "$status" -eq 0 ]
    mock_was_called killall
    mock_calls killall | grep -qE "Finder.*Dock|Dock.*Finder|Finder Dock"
}

@test "step 0 no: defaults write is NOT invoked when user declines" {
    setup_fake_backup
    run_restore_no "$FAKE_BACKUP"
    [ "$status" -eq 0 ]
    # The defaults mock should not have a calls file (or should be empty).
    if mock_was_called defaults; then
        # If the mock was somehow touched, none of the Step 0 calls should
        # be present.
        ! mock_calls defaults | grep -q "AppleShowAllExtensions"
        ! mock_calls defaults | grep -q "screencapture"
    fi
}

# ── Step 1 — Directory Structure ───────────────────────────────────────────

@test "step 1: ~/Developer/{personal,work,oss,experiments} are created" {
    setup_fake_backup
    run_restore_yes "$FAKE_BACKUP"
    [ "$status" -eq 0 ]
    [ -d "$HOME/Developer/personal" ]
    [ -d "$HOME/Developer/work" ]
    [ -d "$HOME/Developer/oss" ]
    [ -d "$HOME/Developer/experiments" ]
}

@test "step 1: ~/Pictures/Screenshots is created" {
    setup_fake_backup
    run_restore_yes "$FAKE_BACKUP"
    [ "$status" -eq 0 ]
    [ -d "$HOME/Pictures/Screenshots" ]
}

@test "step 1: re-running over an existing layout is idempotent" {
    setup_fake_backup
    mkdir -p "$HOME/Developer/personal/already-here"
    mkdir -p "$HOME/Pictures/Screenshots"
    run_restore_yes "$FAKE_BACKUP"
    [ "$status" -eq 0 ]
    [ -d "$HOME/Developer/personal/already-here" ]
}

# ── Step 2 — Homebrew ──────────────────────────────────────────────────────

@test "step 2 bootstrap: brew install git/gh/claude-code is invoked before Brewfile" {
    setup_fake_backup
    run_restore_yes "$FAKE_BACKUP"
    [ "$status" -eq 0 ]
    # The bootstrap line is `brew install git gh claude-code`. mock_calls
    # records the argv on each invocation, one line per call.
    mock_calls brew | grep -q "install git gh claude-code"
    [[ "$output" == *"bootstrap essentials"* ]]
}

@test "step 2 bootstrap: SSH keys are restored before the Brewfile install" {
    setup_fake_backup
    mkdir -p "$FAKE_BACKUP/config/ssh"
    echo "fake-private-key" > "$FAKE_BACKUP/config/ssh/id_ed25519"
    echo "fake-pub" > "$FAKE_BACKUP/config/ssh/id_ed25519.pub"
    run_restore_yes "$FAKE_BACKUP"
    [ "$status" -eq 0 ]
    [ -f "$HOME/.ssh/id_ed25519" ]
    [ "$(stat -f '%Lp' "$HOME/.ssh/id_ed25519")" = "600" ]
    [[ "$output" == *"SSH keys restored (bootstrap"* ]]
}

@test "step 2 bootstrap: gh hosts.yml is restored before the Brewfile install" {
    setup_fake_backup
    mkdir -p "$FAKE_BACKUP/files/auth-tokens/gh"
    echo 'github.com: { user: foo }' > "$FAKE_BACKUP/files/auth-tokens/gh/hosts.yml"
    run_restore_yes "$FAKE_BACKUP"
    [ "$status" -eq 0 ]
    [ -f "$HOME/.config/gh/hosts.yml" ]
    [ "$(stat -f '%Lp' "$HOME/.config/gh/hosts.yml")" = "600" ]
    [[ "$output" == *"GitHub CLI auth restored (bootstrap"* ]]
}

@test "step 2 bootstrap: ssh-keyscan adds github.com to known_hosts when missing" {
    setup_fake_backup
    # Make ssh-keyscan emit a fake github.com entry so the script appends it.
    mock_command_script ssh-keyscan <<'EOF'
echo "github.com ssh-rsa FAKEKEYDATA"
EOF
    run_restore_yes "$FAKE_BACKUP"
    [ "$status" -eq 0 ]
    [ -f "$HOME/.ssh/known_hosts" ]
    grep -q "^github.com " "$HOME/.ssh/known_hosts"
}

@test "step 2: brew bundle is invoked when Brewfile exists" {
    setup_fake_backup
    run_restore_yes "$FAKE_BACKUP"
    [ "$status" -eq 0 ]
    mock_was_called brew
    # The exact call form is: bundle --file=<backup>/software-inventory/Brewfile
    mock_calls brew | grep -q "bundle"
    mock_calls brew | grep -q "/software-inventory/Brewfile"
}

@test "step 2: preflight warns about VSCode extensions when 'code' is not on PATH" {
    setup_fake_backup
    # Brewfile contains a vscode extension; remove the default `code` mock and
    # restrict PATH so a real `code` (e.g. /usr/local/bin/code installed on the
    # host) doesn't satisfy `has code`. Without this restriction, the test is
    # host-dependent and silently skips the warning we're trying to assert.
    echo 'vscode "github.copilot"' >> "$FAKE_BACKUP/software-inventory/Brewfile"
    rm -f "$MOCK_BIN/code"
    run /bin/bash -c "
        export PATH='$MOCK_BIN:/usr/bin:/bin:/usr/sbin:/sbin'
        printf 'y%.0s' \$(seq 1 400) |
        /bin/bash '$SCRIPTS_DIR/restore.sh' '$FAKE_BACKUP'
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"First-run prerequisites detected"* ]]
    [[ "$output" == *"VSCode extension"* ]]
    [[ "$output" == *"Install code command in PATH"* ]]
}

@test "step 2: preflight does NOT warn about VSCode when 'code' is on PATH" {
    setup_fake_backup
    echo 'vscode "github.copilot"' >> "$FAKE_BACKUP/software-inventory/Brewfile"
    # Default mock for `code` is present, so `has code` returns true.
    run_restore_yes "$FAKE_BACKUP"
    [ "$status" -eq 0 ]
    [[ "$output" != *"VSCode extension"* ]]
}

@test "step 2: preflight warns about MAS apps in the Brewfile" {
    setup_fake_backup
    # Brewfile contains a `mas` line; preflight should always remind the user
    # to sign into the App Store (we can't reliably detect sign-in state).
    echo 'mas "Keynote", id: 409183694' >> "$FAKE_BACKUP/software-inventory/Brewfile"
    run_restore_yes "$FAKE_BACKUP"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Mac App Store app"* ]]
    [[ "$output" == *"sign in"* ]]
}

@test "step 2: preflight prints nothing when Brewfile has no vscode/mas entries" {
    setup_fake_backup
    # Default Brewfile only has `tap "homebrew/cask"`. Preflight stays silent.
    run_restore_yes "$FAKE_BACKUP"
    [ "$status" -eq 0 ]
    [[ "$output" != *"First-run prerequisites detected"* ]]
}

@test "session log file is created at \$HOME/.mac-restore.log and captures script output" {
    setup_fake_backup
    run_restore_yes "$FAKE_BACKUP"
    [ "$status" -eq 0 ]
    [ -f "$HOME/.mac-restore.log" ]
    # The session banner and a known phase header should both be in the log.
    grep -q "=== mac-restore:" "$HOME/.mac-restore.log"
    grep -q "New Mac Setup" "$HOME/.mac-restore.log"
}

@test "step 2: brew bundle failure does NOT abort the restore" {
    setup_fake_backup
    # Make `brew bundle ...` exit non-zero, but keep `brew` itself usable for
    # `has brew` and any other invocation.
    mock_command_script brew <<'EOF'
if [ "${1:-}" = "bundle" ]; then
    echo "fake: brew bundle dependencies failed" >&2
    exit 1
fi
exit 0
EOF
    run_restore_yes "$FAKE_BACKUP"
    [ "$status" -eq 0 ]
    [[ "$output" == *"unsatisfied dependencies"* ]]
    # Script must reach a later phase, proving it didn't exit at step 2.
    [[ "$output" == *"Mac App Store"* ]]
}

@test "step 2: Homebrew install path NOT taken when brew is on PATH" {
    setup_fake_backup
    # The default mock for brew is present, so `has brew` returns true.
    run_restore_yes "$FAKE_BACKUP"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Homebrew already installed"* ]]
    [[ "$output" != *"Installing Homebrew..."* ]]
}

@test "step 2: when brew is missing, attempts to install it" {
    setup_fake_backup
    # Remove the brew mock so `has brew` returns false. Mock curl so the
    # install pipe doesn't reach the network. Restrict PATH so the real
    # /opt/homebrew/bin/brew on the host machine isn't found.
    rm -f "$MOCK_BIN/brew"
    mock_command curl "echo '# fake install script'"
    run /bin/bash -c "
        export PATH='$MOCK_BIN:/usr/bin:/bin:/usr/sbin:/sbin'
        printf 'n%.0s' \$(seq 1 400) |
        /bin/bash '$SCRIPTS_DIR/restore.sh' '$FAKE_BACKUP'
    "
    [[ "$output" == *"Installing Homebrew..."* ]]
}

@test "step 2: empty Brewfile.addon does NOT trigger addon install branch" {
    setup_fake_backup
    # Brewfile.addon is created empty by setup_fake_backup. The script
    # checks `[ -s file ]` (size > 0), so the branch must not fire.
    run_restore_yes "$FAKE_BACKUP"
    [ "$status" -eq 0 ]
    [[ "$output" != *"apps to migrate to Homebrew"* ]]
}

@test "step 2: non-empty Brewfile.addon triggers addon install branch" {
    setup_fake_backup
    echo 'cask "rectangle"' > "$FAKE_BACKUP/software-inventory/Brewfile.addon"
    run_restore_yes "$FAKE_BACKUP"
    [ "$status" -eq 0 ]
    [[ "$output" == *"apps to migrate to Homebrew"* ]]
    mock_calls brew | grep -q "Brewfile.addon"
}

# ── Step 3 — Mac App Store ─────────────────────────────────────────────────

@test "step 3: mas install is called for each id in mac-app-store.txt" {
    setup_fake_backup
    cat > "$FAKE_BACKUP/software-inventory/mac-app-store.txt" <<EOF
409183694 Keynote (12.0)
682658836 GarageBand (10.4)
EOF
    run_restore_yes "$FAKE_BACKUP"
    [ "$status" -eq 0 ]
    mock_was_called mas
    mock_calls mas | grep -q "install 409183694"
    mock_calls mas | grep -q "install 682658836"
}

@test "step 3: when mas missing, brew install mas is attempted" {
    setup_fake_backup
    rm -f "$MOCK_BIN/mas"
    # Restrict PATH so that a real mas installation (e.g. /opt/homebrew/bin/mas)
    # is not visible to restore.sh. setup_mock_path only prepends MOCK_BIN; without
    # this override, removing the mock stub falls through to the real binary and
    # `has mas` returns true, skipping the `brew install mas` call.
    export PATH="$MOCK_BIN:/usr/bin:/bin"
    cat > "$FAKE_BACKUP/software-inventory/mac-app-store.txt" <<EOF
409183694 Keynote
EOF
    run_restore_yes "$FAKE_BACKUP"
    [ "$status" -eq 0 ]
    mock_calls brew | grep -q "install mas"
}

# ── Step 4 — Manual Install Check ──────────────────────────────────────────

@test "step 4: manual-download apps appear in the manual-todo summary" {
    setup_fake_backup
    cat > "$FAKE_BACKUP/software-inventory/install-sources.txt" <<EOF
manual         | NeverHomebrewApp.app
bundled        | Safari.app
manual         | AnotherManual.app
EOF
    run_restore_yes "$FAKE_BACKUP"
    [ "$status" -eq 0 ]
    [[ "$output" == *"NeverHomebrewApp.app"* ]]
    [[ "$output" == *"AnotherManual.app"* ]]
}

@test "step 4: bundled apps do NOT appear as manual-install items" {
    setup_fake_backup
    cat > "$FAKE_BACKUP/software-inventory/install-sources.txt" <<EOF
bundled        | Safari.app
bundled        | Mail.app
EOF
    run_restore_yes "$FAKE_BACKUP"
    [ "$status" -eq 0 ]
    [[ "$output" == *"All apps covered by Homebrew and Mac App Store"* ]]
}

# ── Step 5 — Docker ────────────────────────────────────────────────────────

@test "step 5: runs without crashing when docker is not installed" {
    setup_fake_backup
    rm -f "$MOCK_BIN/docker"
    run_restore_yes "$FAKE_BACKUP"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Docker"* ]]
}

@test "step 5: runs without crashing when docker IS installed" {
    setup_fake_backup
    # docker mock is installed by default
    run_restore_yes "$FAKE_BACKUP"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Docker already installed"* ]]
}

# ── Step 6 — JetBrains ─────────────────────────────────────────────────────

@test "step 6: runs without crashing whether Toolbox is present or not" {
    setup_fake_backup
    # No /Applications/JetBrains Toolbox.app on the synthetic system.
    run_restore_yes "$FAKE_BACKUP"
    [ "$status" -eq 0 ]
    [[ "$output" == *"JetBrains IDEs"* ]]
}

# ── Step 7 — Steam & Games ─────────────────────────────────────────────────

@test "step 7: runs without crashing on missing steam data" {
    setup_fake_backup
    run_restore_yes "$FAKE_BACKUP"
    [ "$status" -eq 0 ]
    [[ "$output" == *"No Steam game data found in backup"* ]]
}

@test "step 7: lists steam games when installed-games.txt exists" {
    setup_fake_backup
    mkdir -p "$FAKE_BACKUP/software-inventory/steam"
    cat > "$FAKE_BACKUP/software-inventory/steam/installed-games.txt" <<EOF
220|Half-Life 2|3.2 GB
EOF
    run_restore_yes "$FAKE_BACKUP"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Half-Life 2"* ]]
}

@test "REGRESSION step 7: game name with apostrophe does NOT crash xargs/trim" {
    # Real bug: when a Steam game name contains a single or double quote
    # (e.g. "Don't Starve"), the old `echo "\$name" | xargs` whitespace-trim
    # trick blew up with "xargs: unterminated quote" and the script exited
    # mid-restore with set -euo pipefail. Pure-bash trim() handles it.
    setup_fake_backup
    mkdir -p "$FAKE_BACKUP/software-inventory/steam"
    cat > "$FAKE_BACKUP/software-inventory/steam/installed-games.txt" <<EOF
219740|Don't Starve|400 MB
EOF
    run_restore_yes "$FAKE_BACKUP"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Don't Starve"* ]]
}

# ── Step 8 — Dotfiles & Config ─────────────────────────────────────────────

@test "step 8: dotfile is restored to \$HOME" {
    setup_fake_backup
    echo 'export PS1=test' > "$FAKE_BACKUP/config/dotfiles/.zshrc"
    run_restore_yes "$FAKE_BACKUP"
    [ "$status" -eq 0 ]
    [ -f "$HOME/.zshrc" ]
    grep -q "export PS1=test" "$HOME/.zshrc"
}

@test "step 8: existing dotfile is backed up to .pre-restore before overwrite" {
    setup_fake_backup
    echo 'export PS1=new' > "$FAKE_BACKUP/config/dotfiles/.zshrc"
    echo 'export PS1=old' > "$HOME/.zshrc"
    run_restore_yes "$FAKE_BACKUP"
    [ "$status" -eq 0 ]
    [ -f "$HOME/.zshrc.pre-restore" ]
    grep -q "old" "$HOME/.zshrc.pre-restore"
    grep -q "new" "$HOME/.zshrc"
}

@test "step 8: ssh keys restored with 700/600/644 permissions" {
    setup_fake_backup
    mkdir -p "$FAKE_BACKUP/config/ssh"
    cat > "$FAKE_BACKUP/config/ssh/id_rsa" <<EOF
-----BEGIN OPENSSH PRIVATE KEY-----
fake
-----END OPENSSH PRIVATE KEY-----
EOF
    echo 'ssh-rsa AAAA fake' > "$FAKE_BACKUP/config/ssh/id_rsa.pub"
    run_restore_yes "$FAKE_BACKUP"
    [ "$status" -eq 0 ]
    [ -d "$HOME/.ssh" ]
    [ "$(stat -f '%Lp' "$HOME/.ssh")" = "700" ]
    [ "$(stat -f '%Lp' "$HOME/.ssh/id_rsa")" = "600" ]
    [ "$(stat -f '%Lp' "$HOME/.ssh/id_rsa.pub")" = "644" ]
}

@test "step 8: gpg secret keys imported when present in backup" {
    setup_fake_backup
    mkdir -p "$FAKE_BACKUP/config/gnupg"
    echo 'fake-gpg-secret' > "$FAKE_BACKUP/config/gnupg/secret-keys.asc"
    run_restore_yes "$FAKE_BACKUP"
    [ "$status" -eq 0 ]
    mock_was_called gpg
    mock_calls gpg | grep -q "import"
}

@test "step 8: ~/.config rsync'd from backup" {
    setup_fake_backup
    mkdir -p "$FAKE_BACKUP/config/dot-config/myapp"
    echo 'cfg' > "$FAKE_BACKUP/config/dot-config/myapp/conf.toml"
    run_restore_yes "$FAKE_BACKUP"
    [ "$status" -eq 0 ]
    mock_was_called rsync
    mock_calls rsync | grep -q "dot-config"
}

@test "step 8: cloud cred dirs (.aws/.kube/.docker) restored when present" {
    setup_fake_backup
    mkdir -p "$FAKE_BACKUP/config/.aws"
    mkdir -p "$FAKE_BACKUP/config/.kube"
    echo 'creds' > "$FAKE_BACKUP/config/.aws/credentials"
    echo 'kubeconfig' > "$FAKE_BACKUP/config/.kube/config"
    run_restore_yes "$FAKE_BACKUP"
    [ "$status" -eq 0 ]
    mock_calls rsync | grep -q "\\.aws"
    mock_calls rsync | grep -q "\\.kube"
}

# ── Step 9 — App Settings ──────────────────────────────────────────────────

@test "step 9: VS Code user settings restored" {
    setup_fake_backup
    mkdir -p "$FAKE_BACKUP/app-settings/vscode"
    echo '{"editor.fontSize":14}' > "$FAKE_BACKUP/app-settings/vscode/settings.json"
    run_restore_yes "$FAKE_BACKUP"
    [ "$status" -eq 0 ]
    [ -f "$HOME/Library/Application Support/Code/User/settings.json" ]
    grep -q "fontSize" "$HOME/Library/Application Support/Code/User/settings.json"
}

@test "step 9: Cursor user settings restored" {
    setup_fake_backup
    mkdir -p "$FAKE_BACKUP/app-settings/cursor"
    echo '{"workbench.colorTheme":"dark"}' > "$FAKE_BACKUP/app-settings/cursor/settings.json"
    run_restore_yes "$FAKE_BACKUP"
    [ "$status" -eq 0 ]
    [ -f "$HOME/Library/Application Support/Cursor/User/settings.json" ]
    grep -q "colorTheme" "$HOME/Library/Application Support/Cursor/User/settings.json"
}

@test "step 9: VS Code extensions installed via mocked code --install-extension" {
    setup_fake_backup
    cat > "$FAKE_BACKUP/software-inventory/vscode-extensions.txt" <<EOF
ms-python.python
esbenp.prettier-vscode
EOF
    run_restore_yes "$FAKE_BACKUP"
    [ "$status" -eq 0 ]
    mock_was_called code
    # At least one --install-extension call should have happened.
    mock_calls code | grep -q -- "--install-extension"
}

@test "step 9: JetBrains settings restored to latest version directory" {
    setup_fake_backup
    mkdir -p "$FAKE_BACKUP/app-settings/pycharm/options"
    echo '<options/>' > "$FAKE_BACKUP/app-settings/pycharm/options/editor.xml"
    # Pretend two versioned IDE dirs exist; the script picks the latest.
    mkdir -p "$HOME/Library/Application Support/JetBrains/PyCharm2024.1"
    mkdir -p "$HOME/Library/Application Support/JetBrains/PyCharm2024.3"
    run_restore_yes "$FAKE_BACKUP"
    [ "$status" -eq 0 ]
    mock_calls rsync | grep -q "PyCharm2024.3"
}

# ── Step 10 — License Plists ───────────────────────────────────────────────

@test "step 10: license plist copied to ~/Library/Preferences/" {
    setup_fake_backup
    mkdir -p "$FAKE_BACKUP/licenses/plists"
    cat > "$FAKE_BACKUP/licenses/plists/com.foo.bar.plist" <<EOF
<?xml version="1.0"?><plist version="1.0"><dict><key>license</key><string>XYZ</string></dict></plist>
EOF
    # The script does `cp ... ~/Library/Preferences/ 2>/dev/null` without
    # creating the destination first. On a synthetic $HOME, that dir
    # doesn't exist and cp silently fails. Pre-create it for the test.
    mkdir -p "$HOME/Library/Preferences"
    run_restore_yes "$FAKE_BACKUP"
    [ "$status" -eq 0 ]
    [ -f "$HOME/Library/Preferences/com.foo.bar.plist" ]
}

@test "step 10: sensitive marker logged when license plists present" {
    setup_fake_backup
    mkdir -p "$FAKE_BACKUP/licenses/plists"
    cat > "$FAKE_BACKUP/licenses/plists/com.example.app.plist" <<EOF
<?xml version="1.0"?><plist/>
EOF
    run_restore_yes "$FAKE_BACKUP"
    [ "$status" -eq 0 ]
    # Helpers' sensitive() prefixes lines visibly. The script uses log() for
    # plist names, but it always prints a serial-numbers reminder.
    [[ "$output" == *"serial numbers"* ]] || [[ "$output" == *"License Keys"* ]]
}

# ── Step 11 — Browser Extensions / Plugin Lists ────────────────────────────

@test "step 11: browser extensions list is displayed (no auto-install)" {
    setup_fake_backup
    mkdir -p "$FAKE_BACKUP/software-inventory/browser-extensions"
    cat > "$FAKE_BACKUP/software-inventory/browser-extensions/chrome-extensions.txt" <<EOF
abcdef|MyExtension|1.2.3
ghijkl|Another One|0.9
EOF
    run_restore_yes "$FAKE_BACKUP"
    [ "$status" -eq 0 ]
    [[ "$output" == *"MyExtension"* ]]
    [[ "$output" == *"Another One"* ]]
    [[ "$output" == *"cannot be installed automatically"* ]]
}

@test "step 11: jetbrains plugin lists are displayed" {
    setup_fake_backup
    mkdir -p "$FAKE_BACKUP/software-inventory/app-plugins"
    cat > "$FAKE_BACKUP/software-inventory/app-plugins/PyCharm-plugins.txt" <<EOF
.ignore
Mypy
EOF
    run_restore_yes "$FAKE_BACKUP"
    [ "$status" -eq 0 ]
    [[ "$output" == *"PyCharm"* ]]
    [[ "$output" == *"Mypy"* ]]
}

# ── Step 12 — Screenshots ──────────────────────────────────────────────────

@test "step 12: screenshots copied to ~/Pictures/Screenshots/YYYY/MM/" {
    setup_fake_backup
    mkdir -p "$FAKE_BACKUP/files/Screenshots/2025/06"
    : > "$FAKE_BACKUP/files/Screenshots/2025/06/foo.png"
    run_restore_yes "$FAKE_BACKUP"
    [ "$status" -eq 0 ]
    # rsync is mocked, so verify the call rather than the destination.
    mock_calls rsync | grep -q "files/Screenshots"
    mock_calls rsync | grep -q "Pictures/Screenshots"
}

# ── Step 13 — Projects ─────────────────────────────────────────────────────

@test "step 13: project under projects/<scope>/myproj/.git/ is restored" {
    setup_fake_backup
    # restore.sh does `find -maxdepth 4 -name .git`. Counting the start
    # path as depth 0, .git must sit at depth 4 or shallower under
    # $PROJ_SRC. projects/personal/myproj/.git is depth 3. Anything deeper
    # (e.g. projects/Users/old/repos/myproj/.git) won't be found.
    mkdir -p "$FAKE_BACKUP/projects/personal/myproj/.git"
    run_restore_yes "$FAKE_BACKUP"
    [ "$status" -eq 0 ]
    mock_calls rsync | grep -q "myproj"
}

@test "step 13: original-path manifest is displayed in script output" {
    setup_fake_backup
    mkdir -p "$FAKE_BACKUP/projects/Users/old/repos/myproj/.git"
    cat > "$FAKE_BACKUP/projects/_project-list.txt" <<EOF
/Users/old/repos/myproj
EOF
    run_restore_yes "$FAKE_BACKUP"
    [ "$status" -eq 0 ]
    # After stripping /Users/<name>/, "repos" should appear in the summary.
    [[ "$output" == *"repos"* ]]
}

# ── Step 14 — Personal Files ───────────────────────────────────────────────

@test "step 14: scattered credentials restored before generic file dirs" {
    setup_fake_backup
    mkdir -p "$FAKE_BACKUP/files/scattered-credentials/some/path"
    echo "secret=42" > "$FAKE_BACKUP/files/scattered-credentials/some/path/secrets.env"
    echo "some/path/secrets.env" > "$FAKE_BACKUP/files/scattered-credentials/_found.txt"
    run_restore_yes "$FAKE_BACKUP"
    [ "$status" -eq 0 ]
    [ -f "$HOME/some/path/secrets.env" ]
    grep -q "secret=42" "$HOME/some/path/secrets.env"
}

@test "step 14: gh hosts.yml restored to ~/.config/gh/ with mode 600" {
    setup_fake_backup
    mkdir -p "$FAKE_BACKUP/files/auth-tokens/gh"
    echo 'github.com: { user: foo }' > "$FAKE_BACKUP/files/auth-tokens/gh/hosts.yml"
    run_restore_yes "$FAKE_BACKUP"
    [ "$status" -eq 0 ]
    [ -f "$HOME/.config/gh/hosts.yml" ]
    [ "$(stat -f '%Lp' "$HOME/.config/gh/hosts.yml")" = "600" ]
}

@test "step 14: gh-only auth-tokens (no sourcery) does NOT abort restore" {
    # The auth-tokens block's two inner [ -f ... ] && {} guards used to leave
    # the outer && {} block returning the failing test's exit status when only
    # one of the two files was present. set -e exempted &&-chains so the script
    # didn't actually die, but the if/fi rewrite removes the trap entirely —
    # this test pins down that the gh-only path runs to completion.
    setup_fake_backup
    mkdir -p "$FAKE_BACKUP/files/auth-tokens/gh"
    echo 'github.com: { user: foo }' > "$FAKE_BACKUP/files/auth-tokens/gh/hosts.yml"
    # Deliberately do NOT create sourcery/auth.yaml.
    run_restore_yes "$FAKE_BACKUP"
    [ "$status" -eq 0 ]
    [ -f "$HOME/.config/gh/hosts.yml" ]
    [ ! -f "$HOME/.config/sourcery/auth.yaml" ]
    [[ "$output" == *"GitHub CLI auth restored"* ]]
    [[ "$output" != *"Sourcery auth restored"* ]]
}

@test "step 14: sourcery auth.yaml restored with mode 600" {
    setup_fake_backup
    mkdir -p "$FAKE_BACKUP/files/auth-tokens/sourcery"
    echo 'token: abc' > "$FAKE_BACKUP/files/auth-tokens/sourcery/auth.yaml"
    run_restore_yes "$FAKE_BACKUP"
    [ "$status" -eq 0 ]
    [ -f "$HOME/.config/sourcery/auth.yaml" ]
    [ "$(stat -f '%Lp' "$HOME/.config/sourcery/auth.yaml")" = "600" ]
}

@test "step 14: loose photos on Desktop are offered for relocation" {
    setup_fake_backup
    mkdir -p "$FAKE_BACKUP/files/Desktop"
    : > "$FAKE_BACKUP/files/Desktop/photo1.jpg"
    : > "$FAKE_BACKUP/files/Desktop/photo2.heic"
    run_restore_yes "$FAKE_BACKUP"
    [ "$status" -eq 0 ]
    [[ "$output" == *"loose photos"* ]]
    [ -d "$HOME/Pictures/Imported" ]
}

@test "step 14 (no): stale data is not auto-restored when user declines" {
    setup_fake_backup
    mkdir -p "$FAKE_BACKUP/files/Documents/old-sync-junk"
    cat > "$FAKE_BACKUP/files/_data-classification.txt" <<EOF
STALE|old-sync-junk|2.4G
EOF
    run_restore_no "$FAKE_BACKUP"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Stale data"* ]] || [[ "$output" == *"sync artifacts"* ]]
}

# ── Step 15 — Language Package Managers ────────────────────────────────────

@test "step 15: conda env create called for each YAML in conda-envs/" {
    setup_fake_backup
    mkdir -p "$FAKE_BACKUP/software-inventory/conda-envs"
    cat > "$FAKE_BACKUP/software-inventory/conda-envs/sci.yml" <<EOF
name: sci
dependencies: [numpy]
EOF
    cat > "$FAKE_BACKUP/software-inventory/conda-envs/web.yml" <<EOF
name: web
dependencies: [flask]
EOF
    run_restore_yes "$FAKE_BACKUP"
    [ "$status" -eq 0 ]
    mock_was_called conda
    mock_calls conda | grep -q "sci.yml"
    mock_calls conda | grep -q "web.yml"
}

@test "step 15: npm i -g called for each entry in npm-globals.txt" {
    setup_fake_backup
    cat > "$FAKE_BACKUP/software-inventory/npm-globals.txt" <<'EOF'
/usr/local/lib
├── npm@10.2.4
├── typescript@5.3.2
└── prettier@3.1.0
EOF
    run_restore_yes "$FAKE_BACKUP"
    [ "$status" -eq 0 ]
    mock_was_called npm
    # Names appear (one per filtered entry); script greps tree characters.
    mock_calls npm | grep -qE "install -g (typescript|prettier|npm)"
}

@test "step 15: pipx install called for each package in pipx-packages.json" {
    setup_fake_backup
    cat > "$FAKE_BACKUP/software-inventory/pipx-packages.json" <<EOF
{"venvs": {"black": {}, "ruff": {}}}
EOF
    # python3 mock needs to actually run, not be mocked-empty. Replace the
    # default mock with a passthrough that runs the real python3.
    cat > "$MOCK_BIN/python3" <<EOF
#!/bin/bash
echo "\$@" >> "$MOCK_BIN/python3.calls"
exec /usr/bin/python3 "\$@"
EOF
    chmod +x "$MOCK_BIN/python3"
    run_restore_yes "$FAKE_BACKUP"
    [ "$status" -eq 0 ]
    mock_was_called pipx
    mock_calls pipx | grep -qE "install (black|ruff)"
}

@test "step 15: cargo install called for each package in cargo-packages.txt" {
    setup_fake_backup
    cat > "$FAKE_BACKUP/software-inventory/cargo-packages.txt" <<EOF
ripgrep v14.0.0:
fd-find v9.0.0:
EOF
    run_restore_yes "$FAKE_BACKUP"
    [ "$status" -eq 0 ]
    mock_was_called cargo
    mock_calls cargo | grep -qE "install (ripgrep|fd-find)"
}

# ── Step 16 — System Config ────────────────────────────────────────────────

@test "step 16: crontab restore invoked with the captured crontab file" {
    setup_fake_backup
    mkdir -p "$FAKE_BACKUP/system"
    cat > "$FAKE_BACKUP/system/crontab.txt" <<'EOF'
0 3 * * * /usr/local/bin/backup.sh
EOF
    run_restore_yes "$FAKE_BACKUP"
    [ "$status" -eq 0 ]
    mock_was_called crontab
    mock_calls crontab | grep -q "crontab.txt"
}

@test "step 16: launch agents copied to ~/Library/LaunchAgents/" {
    setup_fake_backup
    mkdir -p "$FAKE_BACKUP/system/LaunchAgents"
    cat > "$FAKE_BACKUP/system/LaunchAgents/com.example.agent.plist" <<EOF
<?xml version="1.0"?><plist version="1.0"><dict/></plist>
EOF
    run_restore_yes "$FAKE_BACKUP"
    [ "$status" -eq 0 ]
    [ -f "$HOME/Library/LaunchAgents/com.example.agent.plist" ]
}

# ── End-of-run summary ─────────────────────────────────────────────────────

@test "summary: lists sign-in apps reminder section" {
    setup_fake_backup
    run_restore_yes "$FAKE_BACKUP"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Sign-in apps"* ]]
    [[ "$output" == *"App Store"* ]]
    [[ "$output" == *"sign in"* ]]
}

@test "summary: points to migration-manifest.txt when present" {
    setup_fake_backup
    echo "manifest content" > "$FAKE_BACKUP/migration-manifest.txt"
    run_restore_yes "$FAKE_BACKUP"
    [ "$status" -eq 0 ]
    [[ "$output" == *"migration-manifest.txt"* ]]
}

# ── Empty-backup safety ────────────────────────────────────────────────────

@test "empty backup: only Brewfile present — script doesn't crash, exits 0" {
    # Build a near-empty backup: only software-inventory/Brewfile.
    FAKE_BACKUP="$FAKE_ROOT/empty-backup"
    mkdir -p "$FAKE_BACKUP/software-inventory"
    echo 'tap "homebrew/cask"' > "$FAKE_BACKUP/software-inventory/Brewfile"
    run_restore_yes "$FAKE_BACKUP"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Setup Complete"* ]]
}

@test "empty backup: phases with nothing to restore log a 'no … found' note" {
    FAKE_BACKUP="$FAKE_ROOT/empty-backup-2"
    mkdir -p "$FAKE_BACKUP/software-inventory"
    echo 'tap "homebrew/cask"' > "$FAKE_BACKUP/software-inventory/Brewfile"
    run_restore_yes "$FAKE_BACKUP"
    [ "$status" -eq 0 ]
    # Several phases print "No … found in backup" or similar.
    [[ "$output" == *"No Steam game data found in backup"* ]] || \
    [[ "$output" == *"No screenshots found in backup"* ]] || \
    [[ "$output" == *"No license plists found in backup"* ]]
}

@test "REGRESSION: dotfiles dir with only _manifest.txt does not abort restore (set -euo pipefail + grep no-match)" {
    # Step 8 listed dotfiles via `ls -1 dir | grep -v '^_' | sed`. Under
    # pipefail, when every entry begins with '_' (i.e. only the manifest is
    # present), grep -v exits 1, the pipeline exits 1, set -e kills the script
    # silently before Step 9. The fix appends `|| true` to that pipeline.
    # See setup_fake_backup() comment about the longstanding placeholder.txt
    # workaround — this test drops the workaround and asserts the real fix.
    FAKE_BACKUP="$FAKE_ROOT/manifest-only-backup"
    mkdir -p "$FAKE_BACKUP/software-inventory" "$FAKE_BACKUP/config/dotfiles"
    echo 'tap "homebrew/cask"' > "$FAKE_BACKUP/software-inventory/Brewfile"
    : > "$FAKE_BACKUP/config/dotfiles/_manifest.txt"
    run_restore_yes "$FAKE_BACKUP"
    [ "$status" -eq 0 ]
    # Reaching the final banner proves the script ran past Step 8.
    [[ "$output" == *"Setup Complete"* ]]
}

@test "step 14: CLOUD-SYNCED advisory printed when classification has cloud rows" {
    setup_fake_backup
    cat >> "$FAKE_BACKUP/files/_data-classification.txt" <<'EOF'
CLOUD-SYNCED   | Documents/                              | 15G  | iCloud Desktop & Documents — re-syncs on new Mac
CLOUD-SYNCED   | Pictures/Photos Library.photoslibrary/  | 87G  | iCloud Photos — re-downloads on new Mac
EOF
    mkdir -p "$FAKE_BACKUP/files"
    run_restore_yes "$FAKE_BACKUP"
    [ "$status" -eq 0 ]
    [[ "$output" == *"☁ Cloud-synced sources"* ]]
    [[ "$output" == *"MBR_RESTORE_CLOUD=1"* ]]
    [[ "$output" == *"Documents/"* ]]
    [[ "$output" == *"Photos Library.photoslibrary"* ]]
}

@test "step 14: CLOUD-SYNCED dirs skipped by default" {
    setup_fake_backup
    mkdir -p "$FAKE_BACKUP/files/Documents"
    echo "doc-content" > "$FAKE_BACKUP/files/Documents/note.txt"
    cat >> "$FAKE_BACKUP/files/_data-classification.txt" <<'EOF'
CLOUD-SYNCED   | Documents/ | 15G | iCloud Desktop & Documents — re-syncs on new Mac
EOF
    # Capture rsync calls.
    mock_command_script rsync <<'EOF'
echo "$@" >> "$MOCK_BIN/rsync.calls"
exit 0
EOF
    run_restore_yes "$FAKE_BACKUP"
    [ "$status" -eq 0 ]
    # rsync should NOT have been called for Documents.
    ! grep -q "files/Documents" "$MOCK_BIN/rsync.calls"
    [[ "$output" == *"skipping Documents"* ]] || [[ "$output" == *"Documents.*cloud-synced"* ]]
}

@test "step 14: CLOUD-SYNCED dirs ARE restored when MBR_RESTORE_CLOUD=1" {
    setup_fake_backup
    mkdir -p "$FAKE_BACKUP/files/Documents"
    echo "doc-content" > "$FAKE_BACKUP/files/Documents/note.txt"
    cat >> "$FAKE_BACKUP/files/_data-classification.txt" <<'EOF'
CLOUD-SYNCED   | Documents/ | 15G | iCloud Desktop & Documents — re-syncs on new Mac
EOF
    mock_command_script rsync <<'EOF'
echo "$@" >> "$MOCK_BIN/rsync.calls"
exit 0
EOF
    # Run with the env var set.
    output=$(printf 'y%.0s' $(seq 1 400) | \
        MBR_RESTORE_CLOUD=1 /bin/bash "$SCRIPTS_DIR/restore.sh" "$FAKE_BACKUP" 2>&1)
    status=$?
    [ "$status" -eq 0 ]
    grep -q "files/Documents" "$MOCK_BIN/rsync.calls"
}

@test "step 14: Branch 2 row does NOT cause parent dir to be skipped (C1 regression)" {
    setup_fake_backup
    mkdir -p "$FAKE_BACKUP/files/Pictures"
    echo "imported-photo" > "$FAKE_BACKUP/files/Pictures/imported-photo.jpg"
    cat >> "$FAKE_BACKUP/files/_data-classification.txt" <<'EOF'
CLOUD-SYNCED   | Pictures/Photos Library.photoslibrary/ | 87G | iCloud Photos — re-syncs on new Mac
EOF
    mock_command_script rsync <<'EOF'
echo "$@" >> "$MOCK_BIN/rsync.calls"
exit 0
EOF
    run_restore_yes "$FAKE_BACKUP"
    [ "$status" -eq 0 ]
    # Pictures (the parent) is NOT cloud-synced as a whole → rsync MUST be called for it.
    grep -q "files/Pictures" "$MOCK_BIN/rsync.calls"
}
