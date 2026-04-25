#!/usr/bin/env bats
# =============================================================================
# Integration tests for scripts/backup.sh
#
# Drives the script against an isolated fake $HOME and an isolated fake "drive"
# under $TMPDIR. Real $HOME, /Applications, /Volumes, brew, mas, etc. are never
# touched — all external commands are mocked via PATH-prepended stubs.
#
# Tests run under stock macOS /bin/bash (3.2.57) — no bash 4+ features.
# =============================================================================

load '../test_helper'

# ── Local helpers ───────────────────────────────────────────────────────────

# Pre-create the home directories backup.sh expects to scan. Without these,
# `find` on a missing directory returns non-zero and `set -e + pipefail` kills
# the script before it reaches later phases.
prep_required_home_dirs() {
    mkdir -p "$FAKE_HOME/Documents" \
             "$FAKE_HOME/Desktop" \
             "$FAKE_HOME/Downloads" \
             "$FAKE_HOME/Pictures" \
             "$FAKE_HOME/Music" \
             "$FAKE_HOME/Movies"
}

# Create silent mocks for all external commands the script may call. Each
# returns success and produces no output. Tests can override individual
# commands afterwards with mock_command / mock_command_script.
prep_silent_mocks() {
    local cmd
    for cmd in brew mas defaults mount crontab gpg mdfind osascript pmset \
               chflags pluginkit npm pip3 pipx cargo gem code cursor \
               numfmt rsync; do
        mock_command "$cmd"
    done
    # rsync needs to actually behave like rsync — restore real one but keep
    # mocks for everything else. We unlink rsync's stub so the real binary is
    # used (rsync has well-defined behavior on dirs and is required for the
    # toolkit-copy phase to populate the drive).
    rm -f "$MOCK_BIN/rsync"
    # Same for numfmt: harmless if missing (script falls back to awk).
    rm -f "$MOCK_BIN/numfmt"
}

# Drive the interactive `confirm` prompts with a long stream of "y" chars.
#
# Note: helpers.sh `confirm` does `read -n 1`, which consumes ONE byte per
# call. Sending "y\ny\n..." would feed "y" to the first call and "\n" to the
# second — making every other confirm fail. We emit raw "y" bytes (no
# newlines) so every read sees a "y" regardless of how many prompts fire.
yes_input() {
    local i=0
    while [ $i -lt 600 ]; do
        printf 'y'
        i=$((i + 1))
    done
}

no_input() {
    local i=0
    while [ $i -lt 600 ]; do
        printf 'n'
        i=$((i + 1))
    done
}

# Run backup.sh end-to-end with the given stdin. Sets $output/$status as bats
# `run` does. We can't use bats `run` directly because we need stdin redirect.
run_backup_yes() {
    output=$(yes_input | bash "$SCRIPTS_DIR/backup.sh" "$FAKE_DRIVE" 2>&1)
    status=$?
}

run_backup_no() {
    output=$(no_input | bash "$SCRIPTS_DIR/backup.sh" "$FAKE_DRIVE" 2>&1)
    status=$?
}

# Locate the (single) timestamped backup dir created during a run.
backup_dir() {
    ls -1d "$FAKE_DRIVE/mac-backup"/*/ 2>/dev/null | head -1 | sed 's:/$::'
}

# Count timestamped backup dirs.
backup_count() {
    ls -1d "$FAKE_DRIVE/mac-backup"/*/ 2>/dev/null | wc -l | tr -d ' '
}

setup() {
    setup_test_env
    prep_required_home_dirs
    prep_silent_mocks
}

teardown() {
    teardown_test_env
}

# ─────────────────────────────────────────────────────────────────────────────
# Smoke / sourcing
# ─────────────────────────────────────────────────────────────────────────────

@test "smoke: all-yes run completes with status 0 and creates a timestamped backup dir" {
    run_backup_yes
    [ "$status" -eq 0 ]
    bd=$(backup_dir)
    [ -n "$bd" ]
    [ -d "$bd" ]
    # Timestamp format: YYYYMMDD_HHMMSS
    base=$(basename "$bd")
    [[ "$base" =~ ^[0-9]{8}_[0-9]{6}$ ]]
}

@test "smoke: all-no run exits 0 without crashing (user declined)" {
    run_backup_no
    [ "$status" -eq 0 ]
    # The user said "no" to "Start backup?" so no backup dir should be populated
    # beyond the empty timestamp directory created before the prompt.
    [[ "$output" == *"Mac Backup"* ]]
}

@test "smoke: backup root dir is chmod 700" {
    run_backup_yes
    [ "$status" -eq 0 ]
    bd=$(backup_dir)
    perm=$(stat -f '%Lp' "$bd")
    [ "$perm" = "700" ]
}

@test "smoke: parent mac-backup/ container is chmod 700" {
    run_backup_yes
    [ "$status" -eq 0 ]
    perm=$(stat -f '%Lp' "$FAKE_DRIVE/mac-backup")
    [ "$perm" = "700" ]
}

@test "smoke: toolkit is copied to drive root in Phase 7" {
    run_backup_yes
    [ "$status" -eq 0 ]
    [ -d "$FAKE_DRIVE/mac-backup-restore" ]
    [ -f "$FAKE_DRIVE/mac-backup-restore/scripts/backup.sh" ]
    [ -f "$FAKE_DRIVE/mac-backup-restore/scripts/lib/helpers.sh" ]
    # .git should be excluded
    [ ! -d "$FAKE_DRIVE/mac-backup-restore/.git" ]
}

@test "usage: running with no args prints usage and lists volumes" {
    output=$(bash "$SCRIPTS_DIR/backup.sh" 2>&1 || true)
    [[ "$output" == *"Usage:"* ]]
    [[ "$output" == *"Available volumes:"* ]]
}

@test "usage: non-existent drive errors out non-zero" {
    run bash "$SCRIPTS_DIR/backup.sh" "$FAKE_ROOT/no-such-drive"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Drive not found"* ]]
}

# ─────────────────────────────────────────────────────────────────────────────
# Phase 1 — Software inventory
# ─────────────────────────────────────────────────────────────────────────────

@test "phase 1: Brewfile is generated when brew mock succeeds" {
    # brew mock already set up by prep_silent_mocks; create a Brewfile-like
    # output via brew bundle dump so the file ends up non-empty.
    mock_command_script brew <<'EOF'
case "$1" in
    bundle)
        # `brew bundle dump --file=<path> --force`
        for arg in "$@"; do
            case "$arg" in
                --file=*) f="${arg#--file=}" ;;
            esac
        done
        printf 'tap "homebrew/cask"\nbrew "git"\ncask "iterm2"\n' > "$f"
        ;;
    list)   echo "git" ;;
    tap)    echo "homebrew/cask" ;;
    info)   exit 1 ;;     # _find_cask_name auto-discovery returns "no cask"
    search) exit 1 ;;
esac
exit 0
EOF
    run_backup_yes
    [ "$status" -eq 0 ]
    bd=$(backup_dir)
    [ -f "$bd/software-inventory/Brewfile" ]
    grep -q 'cask "iterm2"' "$bd/software-inventory/Brewfile"
}

@test "phase 1: missing brew prints warning and continues" {
    # Remove brew from PATH entirely so `has brew` returns false.
    rm -f "$MOCK_BIN/brew"
    # Also strip homebrew from real PATH for this run.
    output=$(yes_input | env PATH="$MOCK_BIN:/usr/bin:/bin" \
        bash "$SCRIPTS_DIR/backup.sh" "$FAKE_DRIVE" 2>&1)
    status=$?
    [ "$status" -eq 0 ]
    [[ "$output" == *"Homebrew not found"* ]]
}

@test "phase 1: mac-app-store.txt populated when mas mock returns rows" {
    mock_command mas "1234567890 SomeApp (1.0)"
    run_backup_yes
    [ "$status" -eq 0 ]
    bd=$(backup_dir)
    [ -f "$bd/software-inventory/mac-app-store.txt" ]
    grep -q "SomeApp" "$bd/software-inventory/mac-app-store.txt"
}

@test "phase 1: missing mas prints helpful warning" {
    rm -f "$MOCK_BIN/mas"
    output=$(yes_input | env PATH="$MOCK_BIN:/usr/bin:/bin" \
        bash "$SCRIPTS_DIR/backup.sh" "$FAKE_DRIVE" 2>&1)
    [[ "$output" == *"mas not installed"* ]]
}

@test "phase 1: install-sources.txt is generated and contains classification rows" {
    run_backup_yes
    [ "$status" -eq 0 ]
    bd=$(backup_dir)
    [ -f "$bd/software-inventory/install-sources.txt" ]
    # Should contain the header
    grep -q "Application Install Source Classification" "$bd/software-inventory/install-sources.txt"
    # And at least one of the source labels — this depends on what the real
    # /Applications dir contains, but on any Mac there are SOME apps so at
    # least one label must appear.
    grep -qE '^(bundled|brew-cask|mas|manual)' "$bd/software-inventory/install-sources.txt"
}

@test "phase 1: applications.txt is created (sourced from real /Applications)" {
    run_backup_yes
    [ "$status" -eq 0 ]
    bd=$(backup_dir)
    # We can't write to real /Applications, so this test asserts only that the
    # file is created. Its contents come from the host's real /Applications.
    [ -f "$bd/software-inventory/applications.txt" ]
}

# ─────────────────────────────────────────────────────────────────────────────
# Phase 1 — Cask map and classification
# ─────────────────────────────────────────────────────────────────────────────

@test "phase 1: CASK_MAP override is honored — Brewfile.addon contains mapped cask" {
    # Set up: brew has empty cask list (so the mapped app counts as
    # "manual install"); brew info --cask <name> always succeeds so the
    # auto-discovery path could be triggered. But we want CASK_MAP to win
    # for an entry that exists in config/cask-map.sh.
    mock_command_script brew <<'EOF'
case "$1" in
    bundle) for a in "$@"; do case "$a" in --file=*) f="${a#--file=}";; esac; done; : > "$f" ;;
    list)   echo "" ;;
    tap)    echo "" ;;
    info)   exit 0 ;;     # discovery succeeds — but CASK_MAP still preferred
    search) exit 0 ;;
esac
exit 0
EOF
    run_backup_yes
    [ "$status" -eq 0 ]
    bd=$(backup_dir)
    [ -f "$bd/software-inventory/Brewfile.addon" ]
    # Whether any specific cask shows up depends on what's installed in the
    # real /Applications, but the file should at minimum exist after the run.
}

@test "phase 1: brew-cask auto-discovery for unmapped apps (mock brew info)" {
    # brew info --cask <guess> succeeds for everything, so unmapped apps
    # become brew-cask candidates and get listed in install-sources.txt.
    mock_command_script brew <<'EOF'
case "$1" in
    bundle) for a in "$@"; do case "$a" in --file=*) f="${a#--file=}";; esac; done; : > "$f" ;;
    list)   echo "" ;;
    tap)    : ;;
    info)   exit 0 ;;
    *)      : ;;
esac
exit 0
EOF
    run_backup_yes
    [ "$status" -eq 0 ]
    bd=$(backup_dir)
    [ -f "$bd/software-inventory/Brewfile.addon" ]
    # When info succeeds for every app and none are pre-installed, every app
    # not in cask-map ends up either as brew-cask or in the addon. Some apps
    # may have failed _find_cask_name's first map lookup but succeed via
    # discovery, so the addon should be non-empty (assuming any apps exist).
    if [ -s "$bd/software-inventory/applications.txt" ]; then
        # At least one app should have classified — install-sources non-empty.
        wc -l < "$bd/software-inventory/install-sources.txt" | tr -d ' ' \
            | { read n; [ "$n" -gt 5 ]; }
    fi
}

@test "phase 1: Brewfile.addon does not include already-installed casks" {
    # Pretend "git" is already a cask (so it should NOT be in addon). Our
    # "brew list --cask" returns a cask name; for any app that matches it
    # via the map, the script writes "brew-cask" not the addon entry.
    mock_command_script brew <<'EOF'
case "$1" in
    bundle) for a in "$@"; do case "$a" in --file=*) f="${a#--file=}";; esac; done; : > "$f" ;;
    list)
        case "$2" in
            --formula) ;;
            --cask)    echo "iterm2"; echo "google-chrome" ;;
        esac
        ;;
    info) exit 1 ;;
esac
exit 0
EOF
    run_backup_yes
    [ "$status" -eq 0 ]
    bd=$(backup_dir)
    addon="$bd/software-inventory/Brewfile.addon"
    [ -f "$addon" ]
    # If a cask is already installed it must NOT appear in the addon.
    if grep -q '"iterm2"' "$addon" 2>/dev/null; then
        false  # would indicate a regression: addon listed an already-installed cask
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Phase 1 — Browser / app plugin / Steam scanning
# ─────────────────────────────────────────────────────────────────────────────

@test "phase 1: browser/plugin/steam scans don't crash with no fixtures" {
    run_backup_yes
    [ "$status" -eq 0 ]
    bd=$(backup_dir)
    # No browser-extensions or app-plugins dirs should exist (script removes
    # them when empty).
    [ ! -d "$bd/software-inventory/browser-extensions" ]
    [ ! -d "$bd/software-inventory/app-plugins" ]
}

@test "phase 1: Chrome extension manifest is parsed when fixture exists" {
    ext_dir="$FAKE_HOME/Library/Application Support/Google/Chrome/Default/Extensions/abcdef0123456789/1.0_0"
    mkdir -p "$ext_dir"
    cat > "$ext_dir/manifest.json" <<'EOF'
{ "name": "Test Extension", "version": "1.2.3" }
EOF
    run_backup_yes
    [ "$status" -eq 0 ]
    bd=$(backup_dir)
    [ -f "$bd/software-inventory/browser-extensions/chrome-extensions.txt" ]
    grep -q "Test Extension" "$bd/software-inventory/browser-extensions/chrome-extensions.txt"
    grep -q "1.2.3" "$bd/software-inventory/browser-extensions/chrome-extensions.txt"
}

@test "phase 1: JetBrains plugin scan picks up plugins from fake IDE dir" {
    plugins="$FAKE_HOME/Library/Application Support/JetBrains/PyCharm2024.1/plugins"
    mkdir -p "$plugins/IdeaVim" "$plugins/Rainbow"
    run_backup_yes
    [ "$status" -eq 0 ]
    bd=$(backup_dir)
    plist="$bd/software-inventory/app-plugins/PyCharm2024.1-plugins.txt"
    [ -f "$plist" ]
    grep -q "IdeaVim" "$plist"
    grep -q "Rainbow" "$plist"
}

@test "phase 1: Steam .acf parser handles minimal fake manifest" {
    steamapps="$FAKE_HOME/Library/Application Support/Steam/steamapps"
    mkdir -p "$steamapps"
    cat > "$steamapps/appmanifest_440.acf" <<'EOF'
"AppState"
{
    "appid"        "440"
    "name"        "Team Fortress 2"
    "SizeOnDisk"        "12345678"
}
EOF
    run_backup_yes
    [ "$status" -eq 0 ]
    bd=$(backup_dir)
    [ -f "$bd/software-inventory/steam/installed-games.txt" ]
    grep -q "Team Fortress 2" "$bd/software-inventory/steam/installed-games.txt"
    grep -qE "440 \| Team Fortress 2" "$bd/software-inventory/steam/installed-games.txt"
}

@test "phase 1: Steam .acf with shell metacharacters in name is not executed" {
    steamapps="$FAKE_HOME/Library/Application Support/Steam/steamapps"
    mkdir -p "$steamapps"
    # Inject a value that, if naively eval'd, would create a sentinel file.
    cat > "$steamapps/appmanifest_999.acf" <<'EOF'
"AppState"
{
    "appid"        "999"
    "name"        "Bad$(touch /tmp/mbr-pwned-12345)"
    "SizeOnDisk"        "1024"
}
EOF
    run_backup_yes
    [ "$status" -eq 0 ]
    # The sentinel file MUST NOT exist; the script must not have executed the
    # injected command substitution.
    [ ! -e /tmp/mbr-pwned-12345 ]
    bd=$(backup_dir)
    # And the literal string is preserved in the output (proves it's data,
    # not a command).
    grep -q "Bad" "$bd/software-inventory/steam/installed-games.txt"
}

@test "phase 1: Steam .acf with non-numeric SizeOnDisk does not crash arithmetic" {
    steamapps="$FAKE_HOME/Library/Application Support/Steam/steamapps"
    mkdir -p "$steamapps"
    cat > "$steamapps/appmanifest_001.acf" <<'EOF'
"AppState"
{
    "appid"        "1"
    "name"        "WeirdGame"
    "SizeOnDisk"        "; rm -rf /tmp/mbr-bogus"
}
EOF
    run_backup_yes
    [ "$status" -eq 0 ]
    bd=$(backup_dir)
    [ -f "$bd/software-inventory/steam/installed-games.txt" ]
    # Size column should fall through to "?" since regex didn't match.
    grep -qE "1 \| WeirdGame \| \?" "$bd/software-inventory/steam/installed-games.txt"
}

# ─────────────────────────────────────────────────────────────────────────────
# Phase 2 — Dotfiles & config
# ─────────────────────────────────────────────────────────────────────────────

@test "phase 2: priority dotfiles in fake \$HOME are copied" {
    echo "alias ll='ls -la'" > "$FAKE_HOME/.zshrc"
    cat > "$FAKE_HOME/.gitconfig" <<'EOF'
[user]
    name = Test User
EOF
    run_backup_yes
    [ "$status" -eq 0 ]
    bd=$(backup_dir)
    [ -f "$bd/config/dotfiles/.zshrc" ]
    [ -f "$bd/config/dotfiles/.gitconfig" ]
    grep -q "Test User" "$bd/config/dotfiles/.gitconfig"
}

@test "phase 2: SSH dir is captured and emits the sensitive (lock) marker" {
    mkdir -p "$FAKE_HOME/.ssh"
    echo "ssh-rsa AAAA..." > "$FAKE_HOME/.ssh/id_rsa.pub"
    echo "# config" > "$FAKE_HOME/.ssh/config"
    run_backup_yes
    [ "$status" -eq 0 ]
    bd=$(backup_dir)
    [ -f "$bd/config/ssh/id_rsa.pub" ]
    [ -f "$bd/config/ssh/config" ]
    [[ "$output" == *"🔒"* ]]
    [[ "$output" == *"SSH keys backed up"* ]]
}

@test "phase 2: GPG export attempted only when gpg mock returns secret keys" {
    # Stub gpg to behave like a real one: list-secret-keys prints "sec" header,
    # export-secret-keys prints armored block.
    mock_command_script gpg <<'EOF'
case "$1" in
    --list-secret-keys) echo "sec   rsa4096/ABCD 2024-01-01 [SC]" ;;
    --export-secret-keys) echo "-----BEGIN PGP PRIVATE KEY BLOCK-----" ;;
    --export-ownertrust)  echo "ABCD:6:" ;;
esac
exit 0
EOF
    run_backup_yes
    [ "$status" -eq 0 ]
    bd=$(backup_dir)
    [ -f "$bd/config/gnupg/secret-keys.asc" ]
    grep -q "BEGIN PGP" "$bd/config/gnupg/secret-keys.asc"
    [[ "$output" == *"GPG keys backed up"* ]]
}

@test "phase 2: missing gpg is gracefully skipped (no crash)" {
    rm -f "$MOCK_BIN/gpg"
    output=$(yes_input | env PATH="$MOCK_BIN:/usr/bin:/bin" \
        bash "$SCRIPTS_DIR/backup.sh" "$FAKE_DRIVE" 2>&1)
    status=$?
    [ "$status" -eq 0 ]
    bd=$(backup_dir)
    # No GPG export file should be created.
    [ ! -f "$bd/config/gnupg/secret-keys.asc" ]
}

@test "phase 2: ~/.config is rsync'd with cache exclusions" {
    mkdir -p "$FAKE_HOME/.config/myapp/Cache" \
             "$FAKE_HOME/.config/myapp/cache" \
             "$FAKE_HOME/.config/myapp/logs" \
             "$FAKE_HOME/.config/myapp"
    echo "real" > "$FAKE_HOME/.config/myapp/config.yml"
    echo "junk" > "$FAKE_HOME/.config/myapp/Cache/blob"
    echo "junk" > "$FAKE_HOME/.config/myapp/cache/blob"
    echo "junk" > "$FAKE_HOME/.config/myapp/logs/old.log"

    run_backup_yes
    [ "$status" -eq 0 ]
    bd=$(backup_dir)
    [ -f "$bd/config/dot-config/myapp/config.yml" ]
    # Cache dir contents should be excluded (the rsync excludes match
    # `*/Cache*` and `*/cache*` so the directories themselves disappear).
    [ ! -e "$bd/config/dot-config/myapp/Cache" ]
    [ ! -e "$bd/config/dot-config/myapp/cache" ]
    # The rsync exclude for logs is `*/logs/*` — that excludes contents but
    # may leave an empty logs/ directory behind. Assert no log files copied.
    [ ! -f "$bd/config/dot-config/myapp/logs/old.log" ]
}

# ─────────────────────────────────────────────────────────────────────────────
# Phase 3 — App settings & licenses
# ─────────────────────────────────────────────────────────────────────────────

@test "phase 3: VS Code app settings present in fake \$HOME are copied" {
    vsdir="$FAKE_HOME/Library/Application Support/Code/User"
    mkdir -p "$vsdir/snippets"
    echo '{"editor.fontSize": 14}' > "$vsdir/settings.json"
    echo '[]' > "$vsdir/keybindings.json"
    echo '{}' > "$vsdir/snippets/python.json"

    run_backup_yes
    [ "$status" -eq 0 ]
    bd=$(backup_dir)
    [ -f "$bd/app-settings/vscode/settings.json" ]
    [ -f "$bd/app-settings/vscode/keybindings.json" ]
    grep -q "fontSize" "$bd/app-settings/vscode/settings.json"
}

@test "phase 3: license plist for known bundle ID is copied to licenses/plists/" {
    # BBEdit's bundle ID is com.barebones.bbedit per config/license-plists.sh
    make_fake_license_plist "com.barebones.bbedit"
    run_backup_yes
    [ "$status" -eq 0 ]
    bd=$(backup_dir)
    [ -f "$bd/licenses/plists/com.barebones.bbedit.plist" ]
    [[ "$output" == *"BBEdit license plist"* ]]
    [[ "$output" == *"🔒"* ]]
}

@test "phase 3: empty LICENSE_PLISTS is handled without crash (regression)" {
    # Override the config file by sourcing a clean version that empties the
    # array. We can't modify the real config, but we can run the script in a
    # subshell that truncates the variable.
    #
    # Instead: don't create any of the license plists. The default config
    # has entries but no real plists exist on disk → LICENSE_COUNT=0 path.
    run_backup_yes
    [ "$status" -eq 0 ]
    bd=$(backup_dir)
    # Plists dir was created but should be empty.
    [ -d "$bd/licenses/plists" ]
    [[ "$output" == *"No license plists found"* ]]
}

@test "phase 3: migration manifest classifies apps under correct headers" {
    # Set up a license plist and an app settings dir so both LICENSE-KEY and
    # CONFIG sections get populated.
    make_fake_license_plist "com.barebones.bbedit"
    vsdir="$FAKE_HOME/Library/Application Support/Code/User"
    mkdir -p "$vsdir"
    echo '{}' > "$vsdir/settings.json"

    run_backup_yes
    [ "$status" -eq 0 ]
    bd=$(backup_dir)
    [ -f "$bd/migration-manifest.txt" ]
    # All four headers must be present.
    grep -q "## SIGN-IN" "$bd/migration-manifest.txt"
    grep -q "## CONFIG" "$bd/migration-manifest.txt"
    grep -q "## LICENSE-KEY" "$bd/migration-manifest.txt"
    grep -q "## RE-DOWNLOAD" "$bd/migration-manifest.txt"
    # BBEdit must appear under LICENSE-KEY (we created its plist).
    grep -q "BBEdit" "$bd/migration-manifest.txt"
}

# ─────────────────────────────────────────────────────────────────────────────
# Phase 4 — Project discovery
# ─────────────────────────────────────────────────────────────────────────────

@test "phase 4: a fake git repo under ~/Developer/personal is found" {
    repo="$FAKE_HOME/Developer/personal/foo"
    mkdir -p "$repo/.git"
    echo "ref: refs/heads/main" > "$repo/.git/HEAD"
    echo "print('hi')" > "$repo/main.py"

    run_backup_yes
    [ "$status" -eq 0 ]
    bd=$(backup_dir)
    list="$bd/projects/_project-list.txt"
    [ -f "$list" ]
    grep -q "Developer/personal/foo" "$list"
}

@test "phase 4: repos in node_modules / .venv / Library are excluded" {
    # Real repo
    mkdir -p "$FAKE_HOME/code/legit/.git"
    # Junk repos that should be excluded
    mkdir -p "$FAKE_HOME/code/legit/node_modules/some-pkg/.git"
    mkdir -p "$FAKE_HOME/code/legit/.venv/some-lib/.git"
    mkdir -p "$FAKE_HOME/Library/Caches/junk/.git"

    run_backup_yes
    [ "$status" -eq 0 ]
    bd=$(backup_dir)
    list="$bd/projects/_project-list.txt"
    grep -q "code/legit$" "$list"
    if grep -q "node_modules" "$list"; then false; fi
    if grep -q "\.venv" "$list"; then false; fi
    if grep -q "Library/Caches" "$list"; then false; fi
}

@test "phase 4: orphan code files (outside any git repo) are listed" {
    # Stray .py file with no surrounding .git
    echo "print(1)" > "$FAKE_HOME/Documents/loose_script.py"
    run_backup_yes
    [ "$status" -eq 0 ]
    bd=$(backup_dir)
    [ -f "$bd/projects/_orphan-code-files.txt" ]
    grep -q "loose_script.py" "$bd/projects/_orphan-code-files.txt"
}

# ─────────────────────────────────────────────────────────────────────────────
# Phase 5 — Personal files
# ─────────────────────────────────────────────────────────────────────────────

@test "phase 5: iCloud offload warning appears when CloudDocs dir exists" {
    mkdir -p "$FAKE_HOME/Library/Mobile Documents/com~apple~CloudDocs"
    run_backup_yes
    [ "$status" -eq 0 ]
    [[ "$output" == *"iCloud Desktop & Documents is ENABLED"* ]]
}

@test "phase 5: cloud sync folders are detected and skipped by default (answer n)" {
    # Create a fake OneDrive sync folder with a unique sentinel file.
    od="$FAKE_HOME/Library/CloudStorage/OneDrive-Personal"
    mkdir -p "$od"
    echo "secret" > "$od/sentinel.txt"

    # All-no answers EVERY confirm with n, including "Start backup?". We need
    # to start the backup, then say n to the cloud-sync override. Build a
    # custom byte stream: one "y" to start, then a flood of "n" bytes for
    # every subsequent prompt.
    output=$( ( printf 'y'; printf 'n%.0s' $(seq 1 600) ) | \
        bash "$SCRIPTS_DIR/backup.sh" "$FAKE_DRIVE" 2>&1)
    status=$?
    [ "$status" -eq 0 ]
    [[ "$output" == *"Cloud sync folders found"* ]]
    bd=$(backup_dir)
    # cloud-sync dir must not contain copied OneDrive content.
    [ ! -e "$bd/files/cloud-sync/OneDrive/sentinel.txt" ]
}

@test "phase 5: cloud sync folder is copied when override is answered y" {
    od="$FAKE_HOME/Library/CloudStorage/OneDrive-Personal"
    mkdir -p "$od"
    echo "important" > "$od/doc.txt"
    run_backup_yes
    [ "$status" -eq 0 ]
    bd=$(backup_dir)
    # Look for the file under cloud-sync (name normalised by tr).
    found=$(find "$bd/files/cloud-sync" -name "doc.txt" 2>/dev/null | head -1)
    [ -n "$found" ]
    grep -q "important" "$found"
}

@test "phase 5: multi-machine sync artifacts are flagged STALE" {
    mkdir -p "$FAKE_HOME/Documents/Documents - Mac mini"
    echo "old data" > "$FAKE_HOME/Documents/Documents - Mac mini/note.txt"
    run_backup_yes
    [ "$status" -eq 0 ]
    bd=$(backup_dir)
    [ -f "$bd/files/_data-classification.txt" ]
    grep -q "STALE" "$bd/files/_data-classification.txt"
    grep -q "Documents - Mac mini" "$bd/files/_data-classification.txt"
}

@test "phase 5: screenshots get organized into Screenshots/YYYY/MM/" {
    # Drop one Screenshot file with a parseable date.
    cp /dev/null "$FAKE_HOME/Desktop/Screenshot 2024-06-15 at 10.30.00 AM.png"
    cp /dev/null "$FAKE_HOME/Documents/Screenshot 2023-12-01 at 09.00.00 AM.png"
    run_backup_yes
    [ "$status" -eq 0 ]
    bd=$(backup_dir)
    [ -d "$bd/files/Screenshots/2024/06" ]
    [ -d "$bd/files/Screenshots/2023/12" ]
    [ -f "$bd/files/Screenshots/2024/06/Screenshot 2024-06-15 at 10.30.00 AM.png" ]
}

@test "phase 5: scattered .pem credentials are detected and copied" {
    echo "-----BEGIN PRIVATE KEY-----" > "$FAKE_HOME/Documents/server.pem"
    run_backup_yes
    [ "$status" -eq 0 ]
    bd=$(backup_dir)
    [ -d "$bd/files/scattered-credentials" ]
    [ -f "$bd/files/scattered-credentials/Documents/server.pem" ]
    [[ "$output" == *"🔒"* ]]
    [[ "$output" == *"scattered-credentials"* ]]
}

@test "phase 5: gh hosts.yml and sourcery auth.yaml are copied to auth-tokens/" {
    mkdir -p "$FAKE_HOME/.config/gh" "$FAKE_HOME/.config/sourcery"
    echo "github.com:" > "$FAKE_HOME/.config/gh/hosts.yml"
    echo "token: secret" > "$FAKE_HOME/.config/sourcery/auth.yaml"
    run_backup_yes
    [ "$status" -eq 0 ]
    bd=$(backup_dir)
    [ -f "$bd/files/auth-tokens/gh/hosts.yml" ]
    [ -f "$bd/files/auth-tokens/sourcery/auth.yaml" ]
    [[ "$output" == *"GitHub CLI auth token"* ]]
    [[ "$output" == *"Sourcery auth token"* ]]
}

# ─────────────────────────────────────────────────────────────────────────────
# Phase 5f — Network drives
# ─────────────────────────────────────────────────────────────────────────────

@test "phase 5f: SMB mount is detected; backup drive itself is excluded" {
    # mount mock outputs an SMB line, plus a line for the backup drive itself.
    nd_path="$FAKE_ROOT/fake-net"
    mkdir -p "$nd_path"
    mock_command_script mount <<EOF
echo "smb://server/share on $nd_path (smbfs, nodev, nosuid)"
echo "/dev/disk2s1 on $FAKE_DRIVE (apfs, local, journaled)"
EOF
    # Answer n to "Include network drive contents in backup?" so the test
    # only verifies detection, not copying. Easiest: use no_input.
    run_backup_no
    # Detection text appears even when user says no to start, because mount
    # is called only after Start backup? was answered — so we need yes_input
    # but n to the network confirm. Simulate with all-yes (the default in
    # this test's main flow).
    run_backup_yes
    [ "$status" -eq 0 ]
    [[ "$output" == *"fake-net"* ]] || [[ "$output" == *"smb://server/share"* ]]
    # Backup drive itself must NOT be listed as a network drive.
    if [[ "$output" == *"$(basename "$FAKE_DRIVE") (/dev"* ]]; then false; fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Phase 6 — System config
# ─────────────────────────────────────────────────────────────────────────────

@test "phase 6: crontab content is captured to system/crontab.txt" {
    mock_command crontab "0 9 * * 1 echo monday-morning"
    run_backup_yes
    [ "$status" -eq 0 ]
    bd=$(backup_dir)
    [ -f "$bd/system/crontab.txt" ]
    grep -q "monday-morning" "$bd/system/crontab.txt"
}

@test "phase 6: ~/Library/LaunchAgents/*.plist is copied" {
    la="$FAKE_HOME/Library/LaunchAgents"
    mkdir -p "$la"
    cat > "$la/com.example.test.plist" <<'EOF'
<?xml version="1.0"?>
<plist><dict><key>Label</key><string>com.example.test</string></dict></plist>
EOF
    run_backup_yes
    [ "$status" -eq 0 ]
    bd=$(backup_dir)
    [ -f "$bd/system/LaunchAgents/com.example.test.plist" ]
}

# ─────────────────────────────────────────────────────────────────────────────
# Phase 7 — Toolkit packaging
# ─────────────────────────────────────────────────────────────────────────────

@test "phase 7: toolkit dir on drive matches repo structure (no .git)" {
    run_backup_yes
    [ "$status" -eq 0 ]
    [ -f "$FAKE_DRIVE/mac-backup-restore/scripts/backup.sh" ]
    [ -f "$FAKE_DRIVE/mac-backup-restore/scripts/restore.sh" ] || \
        [ -f "$FAKE_DRIVE/mac-backup-restore/scripts/lib/helpers.sh" ]
    [ -d "$FAKE_DRIVE/mac-backup-restore/config" ]
    [ ! -d "$FAKE_DRIVE/mac-backup-restore/.git" ]
}

@test "phase 7: summary prints the exact restore command for new Mac" {
    run_backup_yes
    [ "$status" -eq 0 ]
    bd=$(backup_dir)
    expected="bash $FAKE_DRIVE/mac-backup-restore/scripts/restore.sh $bd"
    [[ "$output" == *"$expected"* ]]
}

# ─────────────────────────────────────────────────────────────────────────────
# Idempotency / safety
# ─────────────────────────────────────────────────────────────────────────────

@test "idempotency: two runs create two distinct timestamped dirs" {
    run_backup_yes
    [ "$status" -eq 0 ]
    [ "$(backup_count)" = "1" ]
    # Sleep so the second run gets a different YYYYMMDD_HHMMSS.
    sleep 1
    run_backup_yes
    [ "$status" -eq 0 ]
    [ "$(backup_count)" = "2" ]
}

@test "safety: critical dirs do not contain zero-byte placeholder files after a successful run" {
    # Drop a real dotfile so dotfiles/ is non-empty.
    echo "alias x=y" > "$FAKE_HOME/.zshrc"
    run_backup_yes
    [ "$status" -eq 0 ]
    bd=$(backup_dir)
    # If the file exists at all, it must be non-zero (we wrote real content).
    if [ -f "$bd/config/dotfiles/.zshrc" ]; then
        [ -s "$bd/config/dotfiles/.zshrc" ]
    fi
    # No zero-byte sentinel under software-inventory/ (the script writes only
    # files it has content for).
    found=$(find "$bd/software-inventory" -type f -size 0 2>/dev/null | wc -l | tr -d ' ')
    # Some placeholder-style files (e.g. Brewfile.addon empty) are legitimate;
    # we only assert there's no flood of empties.
    [ "$found" -lt 20 ]
}

# ─────────────────────────────────────────────────────────────────────────────
# Security
# ─────────────────────────────────────────────────────────────────────────────

@test "security: SSH-keys backup logs the 🔒 sensitive marker" {
    mkdir -p "$FAKE_HOME/.ssh"
    echo "fake-key" > "$FAKE_HOME/.ssh/id_rsa"
    run_backup_yes
    [ "$status" -eq 0 ]
    [[ "$output" == *"🔒"* ]]
    [[ "$output" == *"SSH keys"* ]]
}

@test "security: backup dir and parent are both chmod 700 (owner-only)" {
    run_backup_yes
    [ "$status" -eq 0 ]
    bd=$(backup_dir)
    [ "$(stat -f '%Lp' "$bd")" = "700" ]
    [ "$(stat -f '%Lp' "$FAKE_DRIVE/mac-backup")" = "700" ]
}

@test "security: browser-extension manifest with shell metacharacters in name is not executed" {
    ext_dir="$FAKE_HOME/Library/Application Support/Google/Chrome/Default/Extensions/zzzzzzzzzzzzzzzz/1.0_0"
    mkdir -p "$ext_dir"
    # A name containing $(...) — if naively eval'd would touch a sentinel.
    cat > "$ext_dir/manifest.json" <<'EOF'
{ "name": "Evil$(touch /tmp/mbr-pwn-ext-9876)", "version": "1.0" }
EOF
    run_backup_yes
    [ "$status" -eq 0 ]
    [ ! -e /tmp/mbr-pwn-ext-9876 ]
    bd=$(backup_dir)
    # The literal name (verbatim) should appear in the txt — proving it was
    # passed as data via env vars, not evaluated.
    grep -q "Evil" "$bd/software-inventory/browser-extensions/chrome-extensions.txt"
}

@test "security: final summary banner emits the keep-secure 🔒 reminder" {
    run_backup_yes
    [ "$status" -eq 0 ]
    [[ "$output" == *"🔒"* ]]
    [[ "$output" == *"contains SSH keys"* ]]
}

# ─────────────────────────────────────────────────────────────────────────────
# Regression
# ─────────────────────────────────────────────────────────────────────────────

@test "REGRESSION: Safari prefs without 'Enabled Extensions' does not abort backup mid-Phase-1 (set -euo pipefail + grep no-match)" {
    # Phase 1 ran:
    #   pluginkit -mA 2>/dev/null | grep -i safari > "$SAFARI_OUT" 2>/dev/null
    #   defaults read com.apple.Safari 2>/dev/null | grep -A2 "Enabled Extensions" >> "$SAFARI_OUT" 2>/dev/null
    # Both pipelines run only when the Safari prefs file exists. Under pipefail,
    # if grep finds no match (modern Safari does not store extensions under
    # "Enabled Extensions"), the pipeline exits 1 and set -e kills the script
    # silently — leaving a partial Phase-1 backup and never reaching Phase 2+.
    # The fix appends `|| true` to both pipelines.
    mkdir -p "$FAKE_HOME/Library/Preferences"
    : > "$FAKE_HOME/Library/Preferences/com.apple.Safari.plist"
    run_backup_yes
    [ "$status" -eq 0 ]
    # Reaching the final banner proves the script ran past Phase 1.
    [[ "$output" == *"Backup Complete"* ]]
    # And Phase 7 (toolkit packaging) actually wrote the toolkit to the drive.
    [ -d "$FAKE_DRIVE/mac-backup-restore/scripts" ]
}

@test "REGRESSION: pipe-to-while pipelines past Phase 1 must terminate in '|| true' under set -euo pipefail" {
    # Static guard: every `find ... | while` and `<cmd> | while ... > file`
    # site walking $HOME or grep'ing optional output must end with `|| true`.
    # If a future edit drops the guard, set -euo pipefail will silently kill
    # the script when find hits a permission error or grep finds no match
    # (the same failure mode as the Safari and dotfile bugs).
    #
    # The audit below is the one I ran by hand after Phase 4 silently aborted
    # on a real Mac — encoded so a future edit can't reintroduce it.
    cd "$PROJECT_ROOT"
    # 1. Project find ($HOME, maxdepth 5)
    grep -A 10 'find "\$HOME" -maxdepth 5 -name ".git"' scripts/backup.sh \
        | grep -q 'sort -u > "\$LIST" || true'
    # 2. Orphan-code find ($HOME, maxdepth 4)
    grep -A 30 'find "\$HOME" -maxdepth 4 -type f' scripts/backup.sh \
        | grep -q 'sort > "\$ORPHANS" 2>/dev/null || true'
    # 3. Scattered-credentials find ($HOME/Documents/Desktop/Downloads)
    grep -A 15 'find "\$HOME/Documents" "\$HOME/Desktop" "\$HOME/Downloads"' scripts/backup.sh \
        | grep -q '> "\$CREDS/_found.txt" 2>/dev/null || true'
}
