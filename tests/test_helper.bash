#!/usr/bin/env bash
# =============================================================================
# test_helper.bash — Shared fixtures and helpers for bats tests.
#
# Source from a .bats file:
#   load '../test_helper'
# =============================================================================

# Resolve project root regardless of where the test runs from.
TESTS_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$( cd "$TESTS_DIR/.." && pwd )"
SCRIPTS_DIR="$PROJECT_ROOT/scripts"
CONFIG_DIR="$PROJECT_ROOT/config"
LIB_DIR="$SCRIPTS_DIR/lib"
MOCKS_DIR="$TESTS_DIR/mocks"

# ── Fake environment (per-test sandbox) ────────────────────────────────────
# Creates an isolated $HOME and $DRIVE under a per-test temp dir. Tests must
# call this in setup() and call teardown_fake_env in teardown().
setup_fake_env() {
    FAKE_ROOT="$(mktemp -d -t mbr-test.XXXXXX)"
    export FAKE_HOME="$FAKE_ROOT/home"
    export FAKE_DRIVE="$FAKE_ROOT/drive"
    mkdir -p "$FAKE_HOME" "$FAKE_DRIVE"
    # Many script paths use $HOME directly. Override for the duration of the test.
    export ORIG_HOME="$HOME"
    export HOME="$FAKE_HOME"
}

teardown_fake_env() {
    [ -n "${ORIG_HOME:-}" ] && export HOME="$ORIG_HOME"
    [ -n "${FAKE_ROOT:-}" ] && [ -d "$FAKE_ROOT" ] && rm -rf "$FAKE_ROOT"
    unset FAKE_ROOT FAKE_HOME FAKE_DRIVE ORIG_HOME
}

# ── Command mocking ────────────────────────────────────────────────────────
# Drop a stub script into a temp dir prepended to PATH. The stub records its
# argv and exits 0 by default. Use mock_command_with_output to set custom
# stdout / exit code.

setup_mock_path() {
    MOCK_BIN="$FAKE_ROOT/mock-bin"
    mkdir -p "$MOCK_BIN"
    export ORIG_PATH="$PATH"
    export PATH="$MOCK_BIN:$PATH"
}

# mock_command NAME [STDOUT_LINE...]   exit 0, prints given lines
mock_command() {
    local name="$1"; shift
    local stub="$MOCK_BIN/$name"
    {
        echo '#!/bin/bash'
        echo "echo \"\$@\" >> \"$MOCK_BIN/${name}.calls\""
        for line in "$@"; do
            printf 'echo %q\n' "$line"
        done
        echo 'exit 0'
    } > "$stub"
    chmod +x "$stub"
}

# mock_command_failing NAME [EXIT_CODE]  always exits non-zero
mock_command_failing() {
    local name="$1"
    local code="${2:-1}"
    local stub="$MOCK_BIN/$name"
    {
        echo '#!/bin/bash'
        echo "echo \"\$@\" >> \"$MOCK_BIN/${name}.calls\""
        echo "exit $code"
    } > "$stub"
    chmod +x "$stub"
}

# mock_command_script NAME <<'EOF' ... EOF   custom stub script body
# Reads stub body from stdin. The stub auto-records argv to NAME.calls.
mock_command_script() {
    local name="$1"
    local stub="$MOCK_BIN/$name"
    {
        echo '#!/bin/bash'
        echo "echo \"\$@\" >> \"$MOCK_BIN/${name}.calls\""
        cat
    } > "$stub"
    chmod +x "$stub"
}

# Returns 0 if the named mock was called at all.
mock_was_called() {
    [ -f "$MOCK_BIN/$1.calls" ]
}

# Prints all argv lines the named mock was called with.
mock_calls() {
    cat "$MOCK_BIN/$1.calls" 2>/dev/null
}

teardown_mock_path() {
    [ -n "${ORIG_PATH:-}" ] && export PATH="$ORIG_PATH"
    unset ORIG_PATH MOCK_BIN
}

# ── Convenience: combined setup / teardown ─────────────────────────────────
setup_test_env() {
    setup_fake_env
    setup_mock_path
}

teardown_test_env() {
    teardown_mock_path
    teardown_fake_env
}

# ── Fixture builders ───────────────────────────────────────────────────────
# Drop a fake .app into the fake env's /Applications equivalent.
# Tests can't write to real /Applications, so callers wanting to test app
# detection should override the script's APP_DIR or use the FAKE_HOME's
# Applications dir for ~/Applications scans.
make_fake_app() {
    local app_name="$1"
    local app_root="${2:-$FAKE_HOME/Applications}"
    mkdir -p "$app_root/$app_name/Contents"
    cat > "$app_root/$app_name/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>com.example.$(echo "$app_name" | tr '[:upper:] ' '[:lower:]-' | sed 's/.app$//')</string>
</dict>
</plist>
EOF
}

# Drop a fake license plist into ~/Library/Preferences/.
make_fake_license_plist() {
    local bundle_id="$1"
    local prefs="$FAKE_HOME/Library/Preferences"
    mkdir -p "$prefs"
    # Minimal binary-safe plist: defaults can read it back as XML.
    /usr/bin/plutil -create xml1 "$prefs/${bundle_id}.plist" 2>/dev/null || \
        echo '<?xml version="1.0"?><plist version="1.0"><dict/></plist>' > "$prefs/${bundle_id}.plist"
}

# Drop the iCloud File Provider xattr on a directory so detection helpers
# treat it as iCloud-managed (Desktop & Documents sync).
make_fake_icloud_dir() {
    local dir="$1"
    mkdir -p "$dir"
    xattr -w com.apple.file-provider-domain-id \
        "com.apple.CloudDocs.iCloudDriveFileProvider/AAAA-BBBB-CCCC" "$dir"
}
