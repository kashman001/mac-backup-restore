#!/usr/bin/env bats
# Unit tests for scripts/lib/helpers.sh
# Run with: bats tests/unit/test_helpers_lib.bats

load '../test_helper'

setup() {
    setup_test_env
    source "$LIB_DIR/helpers.sh"
}

teardown() {
    teardown_test_env
}

# ── lookup() ────────────────────────────────────────────────────────────────

@test "lookup: returns value for exact match" {
    local arr=("foo|bar" "baz|qux")
    run lookup "foo" "${arr[@]}"
    [ "$status" -eq 0 ]
    [ "$output" = "bar" ]
}

@test "lookup: returns 1 for missing key with no output" {
    local arr=("foo|bar")
    run lookup "missing" "${arr[@]}"
    [ "$status" -eq 1 ]
    [ -z "$output" ]
}

@test "lookup: handles keys containing spaces" {
    local arr=("Visual Studio Code.app|visual-studio-code")
    run lookup "Visual Studio Code.app" "${arr[@]}"
    [ "$status" -eq 0 ]
    [ "$output" = "visual-studio-code" ]
}

@test "lookup: handles keys containing dots" {
    local arr=("draw.io.app|drawio")
    run lookup "draw.io.app" "${arr[@]}"
    [ "$status" -eq 0 ]
    [ "$output" = "drawio" ]
}

@test "lookup: handles keys containing parentheses" {
    local arr=("iStat Menus (helper)|com.bjango.istatmenus.agent")
    run lookup "iStat Menus (helper)" "${arr[@]}"
    [ "$status" -eq 0 ]
    [ "$output" = "com.bjango.istatmenus.agent" ]
}

@test "lookup: keys are matched literally, not as glob patterns" {
    local arr=("foo|bar")
    run lookup "f*" "${arr[@]}"
    [ "$status" -eq 1 ]
}

@test "lookup: keys are matched literally, not as regex" {
    local arr=("foo.app|bar")
    # If matched as regex, "foo.app" pattern would match "fooXapp"
    run lookup "fooXapp" "${arr[@]}"
    [ "$status" -eq 1 ]
}

@test "lookup: returns first match when key appears twice" {
    local arr=("foo|first" "foo|second")
    run lookup "foo" "${arr[@]}"
    [ "$status" -eq 0 ]
    [ "$output" = "first" ]
}

@test "lookup: value containing pipe — only first pipe is delimiter" {
    local arr=("key|value|with|pipes")
    run lookup "key" "${arr[@]}"
    [ "$status" -eq 0 ]
    [ "$output" = "value|with|pipes" ]
}

@test "lookup: handles empty value (entry ends with pipe)" {
    local arr=("key|")
    run lookup "key" "${arr[@]}"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "lookup: with no extra args (caller didn't pass array entries)" {
    # When ARRAY is empty, callers MUST guard the call site, but verify
    # lookup itself doesn't crash if invoked with just a key.
    run lookup "key"
    [ "$status" -eq 1 ]
    [ -z "$output" ]
}

@test "lookup: works under set -euo pipefail (no unbound errors)" {
    run /bin/bash -c '
        set -euo pipefail
        source "'"$LIB_DIR"'/helpers.sh"
        arr=("k|v")
        result=$(lookup "k" "${arr[@]}")
        echo "$result"
    '
    [ "$status" -eq 0 ]
    [ "$output" = "v" ]
}

@test "lookup: returning 1 does not kill caller under set -e" {
    # Standard set -e exception: command in if-condition can fail without exit.
    run /bin/bash -c '
        set -euo pipefail
        source "'"$LIB_DIR"'/helpers.sh"
        arr=("k|v")
        if result=$(lookup "missing" "${arr[@]}"); then
            echo "found"
        else
            echo "not-found"
        fi
    '
    [ "$status" -eq 0 ]
    [ "$output" = "not-found" ]
}

# ── has() ───────────────────────────────────────────────────────────────────

@test "has: returns 0 for an existing command" {
    run has bash
    [ "$status" -eq 0 ]
}

@test "has: returns non-zero for a missing command" {
    run has __definitely_not_a_real_command_42__
    [ "$status" -ne 0 ]
}

@test "has: produces no stdout/stderr noise" {
    run has __no_such_command__
    [ -z "$output" ]
}

# ── log family (smoke tests) ────────────────────────────────────────────────

@test "log/warn/info/err/sensitive: produce non-empty output" {
    run log "hello"
    [ "$status" -eq 0 ]
    [ -n "$output" ]

    run warn "hi"
    [ -n "$output" ]

    run info "hi"
    [ -n "$output" ]

    run err "hi"
    [ -n "$output" ]

    run sensitive "hi"
    [ -n "$output" ]
}

@test "header: includes title in output" {
    run header "My Header"
    [ "$status" -eq 0 ]
    [[ "$output" == *"My Header"* ]]
}

@test "phase: includes title in output" {
    run phase "Phase Name"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Phase Name"* ]]
}

# ── confirm() ───────────────────────────────────────────────────────────────

@test "confirm: returns 0 when user answers y" {
    run /bin/bash -c '
        source "'"$LIB_DIR"'/helpers.sh"
        echo "y" | confirm "Proceed?"
    '
    [ "$status" -eq 0 ]
}

@test "confirm: returns 0 when user answers Y" {
    run /bin/bash -c '
        source "'"$LIB_DIR"'/helpers.sh"
        echo "Y" | confirm "Proceed?"
    '
    [ "$status" -eq 0 ]
}

@test "confirm: returns non-zero when user answers n" {
    run /bin/bash -c '
        source "'"$LIB_DIR"'/helpers.sh"
        echo "n" | confirm "Proceed?"
    '
    [ "$status" -ne 0 ]
}

@test "confirm: returns non-zero when user answers anything else" {
    run /bin/bash -c '
        source "'"$LIB_DIR"'/helpers.sh"
        echo "z" | confirm "Proceed?"
    '
    [ "$status" -ne 0 ]
}

# ── stock-bash compatibility regression ─────────────────────────────────────

@test "helpers.sh sources cleanly under stock /bin/bash (3.2.57 on macOS)" {
    run /bin/bash -c "source '$LIB_DIR/helpers.sh' && echo OK"
    [ "$status" -eq 0 ]
    [ "$output" = "OK" ]
}

@test "helpers.sh sources under set -euo pipefail" {
    run /bin/bash -c "set -euo pipefail; source '$LIB_DIR/helpers.sh' && echo OK"
    [ "$status" -eq 0 ]
    [ "$output" = "OK" ]
}

# ── is_icloud_drive_synced() ───────────────────────────────────────────────

@test "is_icloud_drive_synced: true when CloudDocs xattr is present" {
    make_fake_icloud_dir "$FAKE_HOME/Documents"
    is_icloud_drive_synced "$FAKE_HOME/Documents"
}

@test "is_icloud_drive_synced: false on a plain directory" {
    mkdir -p "$FAKE_HOME/plain"
    # Don't install an xattr mock — the helper hits the real `xattr`, which
    # exits non-zero on a missing key (stderr suppressed by 2>/dev/null), and
    # its empty stdout makes `grep -q` exit 1, so the helper returns 1.
    ! is_icloud_drive_synced "$FAKE_HOME/plain"
}

@test "is_icloud_drive_synced: false when the path does not exist" {
    # Don't install an xattr mock — the helper's [ -e ] check short-circuits
    # before xattr is ever called, so no mock is needed.
    ! is_icloud_drive_synced "$FAKE_HOME/nope"
}

# ── is_icloud_photos_enabled() ─────────────────────────────────────────────

@test "is_icloud_photos_enabled: true via file-system signal (cpl/ dir exists)" {
    mkdir -p "$FAKE_HOME/Pictures/Photos Library.photoslibrary/resources/cpl"
    # No defaults mock — we should not need it; the fs check returns first.
    is_icloud_photos_enabled
}

@test "is_icloud_photos_enabled: true via daemon signal (cpl/ absent, defaults succeeds)" {
    # cpl/ dir does NOT exist → fall through to defaults check.
    mock_command_script defaults <<'EOF'
if [ "$1" = "read" ] && [ "$2" = "com.apple.cloudphotod" ] && [ "$3" = "CPLEngineParameters-SystemLibrary" ]; then
    echo "stub-non-empty"
    exit 0
fi
exit 1
EOF
    is_icloud_photos_enabled
}

@test "is_icloud_photos_enabled: false when neither signal present" {
    # No fs marker, no defaults mock (defaults not in mock_bin → real defaults
    # against fake $HOME has no cloudphotod prefs → exits non-zero).
    mock_command_failing defaults
    ! is_icloud_photos_enabled
}

# ── is_icloud_music_enabled() ──────────────────────────────────────────────

@test "is_icloud_music_enabled: true via SubscriptionAvailability=1" {
    mock_command_script defaults <<'EOF'
if [ "$1" = "read" ] && [ "$2" = "com.apple.Music" ] && [ "$3" = "_MPCloudServiceStatusControllerSubscriptionAvailability" ]; then
    echo "1"
    exit 0
fi
exit 1
EOF
    is_icloud_music_enabled
}

@test "is_icloud_music_enabled: true via doesStoreSupportCloudMusicLibrary=1 (fallback)" {
    mock_command_script defaults <<'EOF'
case "$3" in
    _MPCloudServiceStatusControllerSubscriptionAvailability) exit 1 ;;
    doesStoreSupportCloudMusicLibrary) echo "1"; exit 0 ;;
    *) exit 1 ;;
esac
EOF
    is_icloud_music_enabled
}

@test "is_icloud_music_enabled: false when both signals absent" {
    mock_command_failing defaults
    ! is_icloud_music_enabled
}

# ── is_icloud_tv_enabled() ─────────────────────────────────────────────────

@test "is_icloud_tv_enabled: true when cloudLibraryEnabled is 1" {
    mock_command_script defaults <<'EOF'
if [ "$1" = "read" ] && [ "$2" = "com.apple.TV" ] && [ "$3" = "cloudLibraryEnabled" ]; then
    echo "1"
    exit 0
fi
exit 1
EOF
    is_icloud_tv_enabled
}

@test "is_icloud_tv_enabled: false when defaults read fails" {
    mock_command_failing defaults
    ! is_icloud_tv_enabled
}

# ── trim() ──────────────────────────────────────────────────────────────────

@test "trim: strips leading and trailing whitespace" {
    [ "$(trim '   hello   ')" = "hello" ]
}

@test "trim: leaves internal whitespace alone" {
    [ "$(trim '   hello world   ')" = "hello world" ]
}

@test "trim: handles tabs and mixed whitespace" {
    [ "$(trim $'\t  hello\t')" = "hello" ]
}

@test "trim: empty input returns empty string" {
    [ "$(trim '')" = "" ]
}

@test "trim: whitespace-only input returns empty string" {
    [ "$(trim '   ')" = "" ]
}

@test "trim: input with single quote does NOT crash (vs xargs failure mode)" {
    # Real bug regression: previous code did `echo "\$x" | xargs` which exited
    # non-zero on unbalanced quotes, killing restore.sh under set -euo pipefail
    # whenever a Steam game name like "Don't Starve" was in the inventory.
    [ "$(trim "  Don't Starve  ")" = "Don't Starve" ]
}

@test "trim: input with double quote does NOT crash" {
    [ "$(trim '  say "hi"  ')" = 'say "hi"' ]
}
