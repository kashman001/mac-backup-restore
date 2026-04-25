#!/usr/bin/env bats
# Unit tests for config/*.sh — verify all four files source cleanly under
# stock macOS /bin/bash (3.2.57). This is a regression test for the bug
# where declare -A in cask-map.sh and license-plists.sh crashed the script.

load '../test_helper'

# ── Sourcing under stock bash ───────────────────────────────────────────────

@test "config/cask-map.sh sources cleanly under stock /bin/bash" {
    run /bin/bash -c "set -euo pipefail; source '$CONFIG_DIR/cask-map.sh' && echo OK"
    [ "$status" -eq 0 ]
    [ "$output" = "OK" ]
}

@test "config/license-plists.sh sources cleanly under stock /bin/bash" {
    run /bin/bash -c "set -euo pipefail; source '$CONFIG_DIR/license-plists.sh' && echo OK"
    [ "$status" -eq 0 ]
    [ "$output" = "OK" ]
}

@test "config/app-settings.sh sources cleanly under stock /bin/bash" {
    run /bin/bash -c "set -euo pipefail; source '$CONFIG_DIR/app-settings.sh' && echo OK"
    [ "$status" -eq 0 ]
    [ "$output" = "OK" ]
}

@test "config/migration-patterns.sh sources cleanly under stock /bin/bash" {
    run /bin/bash -c "set -euo pipefail; source '$CONFIG_DIR/migration-patterns.sh' && echo OK"
    [ "$status" -eq 0 ]
    [ "$output" = "OK" ]
}

@test "all configs source together without conflicts" {
    run /bin/bash -c "
        set -euo pipefail
        source '$CONFIG_DIR/cask-map.sh'
        source '$CONFIG_DIR/license-plists.sh'
        source '$CONFIG_DIR/app-settings.sh'
        source '$CONFIG_DIR/migration-patterns.sh'
        echo OK
    "
    [ "$status" -eq 0 ]
    [ "$output" = "OK" ]
}

# ── No declare -A in any config (would break bash 3.2) ──────────────────────

@test "no config file uses declare -A (associative array)" {
    run grep -l "declare -A" "$CONFIG_DIR"/*.sh
    [ "$status" -ne 0 ]  # grep -l returns non-zero when no match
}

@test "no config file uses [key]=value associative-array literals" {
    # Match ["something"]= pattern — old associative array syntax
    run grep -lE '\["[^"]+"\]=' "$CONFIG_DIR"/*.sh
    [ "$status" -ne 0 ]
}

# ── Array contents via lookup helper ────────────────────────────────────────

@test "CASK_MAP: known overrides resolve correctly" {
    source "$LIB_DIR/helpers.sh"
    source "$CONFIG_DIR/cask-map.sh"

    run lookup "Visual Studio Code.app" "${CASK_MAP[@]}"
    [ "$status" -eq 0 ]
    [ "$output" = "visual-studio-code" ]

    run lookup "iTerm.app" "${CASK_MAP[@]}"
    [ "$status" -eq 0 ]
    [ "$output" = "iterm2" ]

    run lookup "1Password.app" "${CASK_MAP[@]}"
    [ "$status" -eq 0 ]
    [ "$output" = "1password" ]
}

@test "CASK_MAP: missing key returns 1" {
    source "$LIB_DIR/helpers.sh"
    source "$CONFIG_DIR/cask-map.sh"

    run lookup "Nonexistent.app" "${CASK_MAP[@]}"
    [ "$status" -eq 1 ]
}

@test "LICENSE_PLISTS: known apps resolve to bundle IDs" {
    source "$LIB_DIR/helpers.sh"
    source "$CONFIG_DIR/license-plists.sh"

    run lookup "BBEdit" "${LICENSE_PLISTS[@]}"
    [ "$status" -eq 0 ]
    [ "$output" = "com.barebones.bbedit" ]

    run lookup "iStat Menus (helper)" "${LICENSE_PLISTS[@]}"
    [ "$status" -eq 0 ]
    [ "$output" = "com.bjango.istatmenus.agent" ]

    run lookup "CrossOver" "${LICENSE_PLISTS[@]}"
    [ "$status" -eq 0 ]
    [ "$output" = "com.codeweavers.CrossOver" ]
}

@test "APP_SETTINGS: pipe-delimited entries split into 4 fields" {
    source "$CONFIG_DIR/app-settings.sh"
    [ "${#APP_SETTINGS[@]}" -gt 0 ]
    local entry="${APP_SETTINGS[0]}"
    # Ensure entry has at least 3 pipe characters (4 fields, last possibly empty)
    local pipe_count
    pipe_count=$(echo "$entry" | tr -cd '|' | wc -c | tr -d ' ')
    [ "$pipe_count" -eq 3 ]
}

@test "JETBRAINS_IDES: contains expected default IDEs" {
    source "$CONFIG_DIR/app-settings.sh"
    local found_pycharm=false
    local entry
    for entry in "${JETBRAINS_IDES[@]}"; do
        [[ "${entry%%|*}" == "PyCharm" ]] && found_pycharm=true
    done
    [ "$found_pycharm" = true ]
}

@test "SIGN_IN_APPS: array is populated and contains 1Password" {
    source "$CONFIG_DIR/migration-patterns.sh"
    [ "${#SIGN_IN_APPS[@]}" -gt 0 ]
    local found=false
    local app
    for app in "${SIGN_IN_APPS[@]}"; do
        [ "$app" = "1Password" ] && found=true
    done
    [ "$found" = true ]
}

@test "RE_DOWNLOAD_APPS: pipe-delimited Steam entry exists" {
    source "$CONFIG_DIR/migration-patterns.sh"
    local found_steam=false
    local entry
    for entry in "${RE_DOWNLOAD_APPS[@]}"; do
        [[ "${entry%%|*}" == "Steam" ]] && found_steam=true
    done
    [ "$found_steam" = true ]
}

# ── Empty-config defensive path ─────────────────────────────────────────────

@test "missing config files don't crash if scripts use defensive declare -a" {
    run /bin/bash -c '
        set -euo pipefail
        # Simulate config files missing — never sourced
        declare -a CASK_MAP 2>/dev/null || true
        declare -a LICENSE_PLISTS 2>/dev/null || true
        declare -a APP_SETTINGS 2>/dev/null || true
        declare -a SIGN_IN_APPS 2>/dev/null || true

        # Verify size queries work on empty arrays under set -u
        echo "${#CASK_MAP[@]} ${#LICENSE_PLISTS[@]} ${#APP_SETTINGS[@]} ${#SIGN_IN_APPS[@]}"
    '
    [ "$status" -eq 0 ]
    [ "$output" = "0 0 0 0" ]
}
