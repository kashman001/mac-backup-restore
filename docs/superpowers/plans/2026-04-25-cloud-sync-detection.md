# Cloud-Sync Detection — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Detect macOS-managed cloud-sync paths (iCloud Drive, iCloud Photos, iCloud Music Library, TV.app library) during Phase 5 of `backup.sh` and skip them by default, with explicit per-prompt overrides on backup and an `MBR_RESTORE_CLOUD=1` env var override on restore.

**Architecture:** Four small detection helpers in `scripts/lib/helpers.sh` (xattr + `defaults read` checks). Two new pipe-delimited config arrays in `config/migration-patterns.sh` driving Phase 5 logic. Phase 5 in `scripts/backup.sh` gains a three-branch per-dir loop (whole-dir cloud → inverted prompt; subfolder cloud → rsync `--exclude`; otherwise → existing path) plus `CLOUD-SYNCED` rows in `_data-classification.txt`. Step 14 in `scripts/restore.sh` gains an advisory block reading those rows and a skip gate honoring the env var.

**Tech Stack:** Bash 3.2 (stock macOS), bats-core (test runner), `xattr`/`defaults` (system tools).

---

## File Structure

| File | Role | Change |
|---|---|---|
| `scripts/lib/helpers.sh` | Shared utilities sourced by all three scripts | Append four `is_icloud_*` functions |
| `config/migration-patterns.sh` | App classification config | Append `CLOUD_TOP_DIRS` and `CLOUD_SUBDIRS` arrays |
| `tests/test_helper.bash` | bats fixture builders | Append `make_fake_icloud_dir` |
| `tests/unit/test_helpers_lib.bats` | Helper unit tests | Append tests for the four new functions |
| `scripts/backup.sh` | Backup script | Replace lines 1063–1081 (Phase 5d personal-files loop) with detection + three-branch logic; insert classification rows |
| `tests/integration/test_backup.bats` | Backup integration tests | Append Phase 5 cloud-detect tests |
| `scripts/restore.sh` | Restore script | Insert advisory block in Step 14 (after APP-DATA block, before personal-files restore loop); add skip gate inside the loop |
| `tests/integration/test_restore.bats` | Restore integration tests | Append Step 14 cloud-skip tests |
| `README.md` | User-facing docs | Update four sections per spec |

The detection helpers are pure functions with no side effects. The config arrays are data-only. All script changes are confined to a single phase per script. No new files are created.

---

## Task 1: Detection helper — `is_icloud_drive_synced`

**Files:**
- Modify: `tests/test_helper.bash` (append fixture builder)
- Modify: `tests/unit/test_helpers_lib.bats` (append tests)
- Modify: `scripts/lib/helpers.sh` (append helper)

- [ ] **Step 1: Add the test fixture to `tests/test_helper.bash`**

Append at the end of the file (after `make_fake_license_plist`).

**Important:** the real `com.apple.file-provider-domain-id` xattr is kernel-protected on macOS — `xattr -w` returns `Operation not permitted` for any value of that key, regardless of sandbox. So the fixture **mocks the `xattr` command** rather than writing a real xattr. The mock is path-specific (only the most recent call's `$dir` will match — call once per test). Same pattern as `mock_command_script defaults` used by Tasks 2-4.

```bash
# Mark a directory as iCloud-managed for detection-helper tests.
# The real File Provider xattr (com.apple.file-provider-domain-id) is kernel-
# protected and cannot be written from user space, so we mock the `xattr`
# command instead. Call this AFTER setup_test_env so $MOCK_BIN exists.
# Only the most recent call's $dir will match — call once per test.
make_fake_icloud_dir() {
    local dir="$1"
    mkdir -p "$dir"
    mock_command_script xattr <<EOF
if [ "\$1" = "-p" ] && [ "\$2" = "com.apple.file-provider-domain-id" ] && [ "\$3" = "$dir" ]; then
    echo "com.apple.CloudDocs.iCloudDriveFileProvider/AAAA-BBBB-CCCC"
    exit 0
fi
exit 1
EOF
}
```

- [ ] **Step 2: Append failing tests to `tests/unit/test_helpers_lib.bats`**

Append at the end of the file:

```bash
# ── is_icloud_drive_synced() ───────────────────────────────────────────────

@test "is_icloud_drive_synced: true when CloudDocs xattr is present" {
    setup_test_env
    make_fake_icloud_dir "$FAKE_HOME/Documents"
    is_icloud_drive_synced "$FAKE_HOME/Documents"
    teardown_test_env
}

@test "is_icloud_drive_synced: false on a plain directory" {
    setup_test_env
    mkdir -p "$FAKE_HOME/plain"
    ! is_icloud_drive_synced "$FAKE_HOME/plain"
    teardown_test_env
}

@test "is_icloud_drive_synced: false when the path does not exist" {
    setup_test_env
    ! is_icloud_drive_synced "$FAKE_HOME/nope"
    teardown_test_env
}
```

- [ ] **Step 3: Run the tests, expect failure**

```bash
bats tests/unit/test_helpers_lib.bats --filter "is_icloud_drive_synced"
```

Expected output: 3 failures with `is_icloud_drive_synced: command not found`.

- [ ] **Step 4: Implement the helper in `scripts/lib/helpers.sh`**

Append at the end of the file (after the `lookup` function):

```bash
# Returns 0 if PATH is part of iCloud Desktop & Documents sync.
# Detection: the iCloud File Provider stamps an xattr on managed dirs.
is_icloud_drive_synced() {
    [ -e "$1" ] || return 1
    xattr -p com.apple.file-provider-domain-id "$1" 2>/dev/null \
        | grep -q "CloudDocs.iCloudDriveFileProvider"
}
```

- [ ] **Step 5: Run the tests, expect pass**

```bash
bats tests/unit/test_helpers_lib.bats --filter "is_icloud_drive_synced"
```

Expected output: `3 tests, 0 failures`.

- [ ] **Step 6: Commit**

```bash
git add tests/test_helper.bash tests/unit/test_helpers_lib.bats scripts/lib/helpers.sh
git commit -m "$(cat <<'EOF'
feat: is_icloud_drive_synced helper + make_fake_icloud_dir fixture

Detect iCloud Desktop & Documents sync via the file-provider-domain-id
xattr stamped by the iCloud File Provider on managed directories.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Detection helper — `is_icloud_photos_enabled`

**Files:**
- Modify: `tests/unit/test_helpers_lib.bats`
- Modify: `scripts/lib/helpers.sh`

- [ ] **Step 1: Append failing tests**

Append to `tests/unit/test_helpers_lib.bats`:

```bash
# ── is_icloud_photos_enabled() ─────────────────────────────────────────────

@test "is_icloud_photos_enabled: true when iCloudPhotoLibraryEnabled is 1" {
    setup_test_env
    local prefs="$FAKE_HOME/Library/Containers/com.apple.Photos/Data/Library/Preferences"
    mkdir -p "$prefs"
    : > "$prefs/com.apple.Photos.plist"
    mock_command_script defaults <<'EOF'
if [ "$1" = "read" ] && [[ "$2" == */com.apple.Photos.plist ]] && [ "$3" = "iCloudPhotoLibraryEnabled" ]; then
    echo "1"
    exit 0
fi
exit 1
EOF
    is_icloud_photos_enabled
    teardown_test_env
}

@test "is_icloud_photos_enabled: false when prefs file is missing" {
    setup_test_env
    ! is_icloud_photos_enabled
    teardown_test_env
}

@test "is_icloud_photos_enabled: false when iCloudPhotoLibraryEnabled is 0" {
    setup_test_env
    local prefs="$FAKE_HOME/Library/Containers/com.apple.Photos/Data/Library/Preferences"
    mkdir -p "$prefs"
    : > "$prefs/com.apple.Photos.plist"
    mock_command_script defaults <<'EOF'
echo "0"
exit 0
EOF
    ! is_icloud_photos_enabled
    teardown_test_env
}
```

- [ ] **Step 2: Run the tests, expect failure**

```bash
bats tests/unit/test_helpers_lib.bats --filter "is_icloud_photos_enabled"
```

Expected: 3 failures with `is_icloud_photos_enabled: command not found`.

- [ ] **Step 3: Implement the helper**

Append to `scripts/lib/helpers.sh`:

```bash
# Returns 0 if iCloud Photos sync is enabled.
is_icloud_photos_enabled() {
    local p="$HOME/Library/Containers/com.apple.Photos/Data/Library/Preferences/com.apple.Photos.plist"
    [ -f "$p" ] || return 1
    [ "$(defaults read "$p" iCloudPhotoLibraryEnabled 2>/dev/null)" = "1" ]
}
```

- [ ] **Step 4: Run the tests, expect pass**

```bash
bats tests/unit/test_helpers_lib.bats --filter "is_icloud_photos_enabled"
```

Expected: `3 tests, 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add tests/unit/test_helpers_lib.bats scripts/lib/helpers.sh
git commit -m "$(cat <<'EOF'
feat: is_icloud_photos_enabled helper

Reads iCloudPhotoLibraryEnabled from com.apple.Photos.plist in the Photos
sandbox container. Returns false when the prefs file is absent (Photos
hasn't been launched) or when the flag is anything other than "1".

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Detection helper — `is_icloud_music_enabled`

**Files:**
- Modify: `tests/unit/test_helpers_lib.bats`
- Modify: `scripts/lib/helpers.sh`

- [ ] **Step 1: Append failing tests**

Append to `tests/unit/test_helpers_lib.bats`:

```bash
# ── is_icloud_music_enabled() ──────────────────────────────────────────────

@test "is_icloud_music_enabled: true when cloudLibraryEnabled is 1" {
    setup_test_env
    mock_command_script defaults <<'EOF'
if [ "$1" = "read" ] && [ "$2" = "com.apple.Music" ] && [ "$3" = "cloudLibraryEnabled" ]; then
    echo "1"
    exit 0
fi
exit 1
EOF
    is_icloud_music_enabled
    teardown_test_env
}

@test "is_icloud_music_enabled: false when defaults read fails" {
    setup_test_env
    mock_command_failing defaults
    ! is_icloud_music_enabled
    teardown_test_env
}
```

- [ ] **Step 2: Run, expect failure**

```bash
bats tests/unit/test_helpers_lib.bats --filter "is_icloud_music_enabled"
```

Expected: 2 failures with `is_icloud_music_enabled: command not found`.

- [ ] **Step 3: Implement**

Append to `scripts/lib/helpers.sh`:

```bash
# Returns 0 if Apple Music's iCloud Music Library / Sync Library is on.
is_icloud_music_enabled() {
    [ "$(defaults read com.apple.Music cloudLibraryEnabled 2>/dev/null)" = "1" ]
}
```

- [ ] **Step 4: Run, expect pass**

```bash
bats tests/unit/test_helpers_lib.bats --filter "is_icloud_music_enabled"
```

Expected: `2 tests, 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add tests/unit/test_helpers_lib.bats scripts/lib/helpers.sh
git commit -m "$(cat <<'EOF'
feat: is_icloud_music_enabled helper

Reads cloudLibraryEnabled from com.apple.Music. Returns false when the
domain or key is missing (e.g. Music.app never launched, no Apple Music
subscription).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Detection helper — `is_icloud_tv_enabled`

**Files:**
- Modify: `tests/unit/test_helpers_lib.bats`
- Modify: `scripts/lib/helpers.sh`

- [ ] **Step 1: Append failing tests**

Append to `tests/unit/test_helpers_lib.bats`:

```bash
# ── is_icloud_tv_enabled() ─────────────────────────────────────────────────

@test "is_icloud_tv_enabled: true when cloudLibraryEnabled is 1" {
    setup_test_env
    mock_command_script defaults <<'EOF'
if [ "$1" = "read" ] && [ "$2" = "com.apple.TV" ] && [ "$3" = "cloudLibraryEnabled" ]; then
    echo "1"
    exit 0
fi
exit 1
EOF
    is_icloud_tv_enabled
    teardown_test_env
}

@test "is_icloud_tv_enabled: false when defaults read fails" {
    setup_test_env
    mock_command_failing defaults
    ! is_icloud_tv_enabled
    teardown_test_env
}
```

- [ ] **Step 2: Run, expect failure**

```bash
bats tests/unit/test_helpers_lib.bats --filter "is_icloud_tv_enabled"
```

Expected: 2 failures.

- [ ] **Step 3: Implement**

Append to `scripts/lib/helpers.sh`:

```bash
# Returns 0 if TV.app's iCloud / iTunes-in-the-Cloud is on.
is_icloud_tv_enabled() {
    [ "$(defaults read com.apple.TV cloudLibraryEnabled 2>/dev/null)" = "1" ]
}
```

- [ ] **Step 4: Run, expect pass**

```bash
bats tests/unit/test_helpers_lib.bats --filter "is_icloud_tv_enabled"
```

Expected: `2 tests, 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add tests/unit/test_helpers_lib.bats scripts/lib/helpers.sh
git commit -m "$(cat <<'EOF'
feat: is_icloud_tv_enabled helper

Symmetric to is_icloud_music_enabled: reads cloudLibraryEnabled from
com.apple.TV.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: Manual validation against the current Mac

**Goal:** Confirm the detection signals match the user's actual Mac before building Phase 5 logic on top. If any helper returns differently than expected, the helper is adjusted before continuing.

**Files:** None modified in this task (validation only). Adjustments, if needed, become a 6th step here.

- [ ] **Step 1: Source the helpers in an interactive shell**

```bash
source scripts/lib/helpers.sh
```

- [ ] **Step 2: Validate `is_icloud_drive_synced`**

```bash
is_icloud_drive_synced "$HOME/Documents" && echo "Documents: iCloud" || echo "Documents: local"
is_icloud_drive_synced "$HOME/Movies"    && echo "Movies: iCloud"    || echo "Movies: local"
```

Expected on a Mac with iCloud Desktop & Documents sync on: `Documents: iCloud`, `Movies: local`.
Expected on a Mac without iCloud D&D: both `local`.

- [ ] **Step 3: Validate `is_icloud_photos_enabled`**

```bash
is_icloud_photos_enabled && echo "Photos: iCloud" || echo "Photos: local"
```

Expected: `Photos: iCloud` if iCloud Photos is on in System Settings → Apple ID → iCloud, else `Photos: local`.

- [ ] **Step 4: Validate `is_icloud_music_enabled`**

```bash
is_icloud_music_enabled && echo "Music: iCloud" || echo "Music: local"
```

Expected: matches "Sync Library" toggle in Music.app → Settings → General.

- [ ] **Step 5: Validate `is_icloud_tv_enabled`**

```bash
is_icloud_tv_enabled && echo "TV: iCloud" || echo "TV: local"
```

Expected: matches the equivalent toggle in TV.app → Settings.

- [ ] **Step 6: Adjust helpers if any returned the wrong value**

If a result is wrong, inspect the actual data source and update the helper. Common adjustments:

- `is_icloud_photos_enabled` reads the wrong key — try `defaults read <plist>` (no key) and grep the output for the correct key name.
- `is_icloud_music_enabled` reads the wrong domain — try `defaults read com.apple.Music | grep -i cloud` to find the actual key.
- For each adjustment, update both the helper and its unit test, re-run that helper's tests (`bats tests/unit/test_helpers_lib.bats --filter <name>`), and commit with a `fix:` message.

If all five validations match expectations, no commit needed for this task — proceed to Task 6.

---

## Task 6: Cloud-sync config arrays

**Files:**
- Modify: `tests/unit/test_configs.bats` (regression guard for new arrays)
- Modify: `config/migration-patterns.sh` (append two arrays)

- [ ] **Step 1: Append failing test to `tests/unit/test_configs.bats`**

Append at the end of the file:

```bash
@test "migration-patterns.sh: defines CLOUD_TOP_DIRS and CLOUD_SUBDIRS" {
    setup_test_env
    source "$CONFIG_DIR/migration-patterns.sh"
    [ "${#CLOUD_TOP_DIRS[@]}" -gt 0 ]
    [ "${#CLOUD_SUBDIRS[@]}" -gt 0 ]
    # CLOUD_SUBDIRS entries must have exactly 4 pipe-delimited fields.
    local entry
    for entry in "${CLOUD_SUBDIRS[@]}"; do
        local field_count
        field_count=$(echo "$entry" | awk -F'|' '{print NF}')
        [ "$field_count" -eq 4 ]
    done
    teardown_test_env
}
```

- [ ] **Step 2: Run, expect failure**

```bash
bats tests/unit/test_configs.bats --filter "CLOUD_TOP_DIRS"
```

Expected: 1 failure (`CLOUD_TOP_DIRS: unbound variable` or array length 0).

- [ ] **Step 3: Append the arrays to `config/migration-patterns.sh`**

Append at the end of the file:

```bash
# ─────────────────────────────────────────────────────────────────────────────
# Cloud-sync detection (Phase 5 of backup.sh)
# ─────────────────────────────────────────────────────────────────────────────

# Top-level $HOME directories that may be fully iCloud-managed via Desktop &
# Documents sync. Detection at runtime via is_icloud_drive_synced() on the dir.
CLOUD_TOP_DIRS=(
    "Documents"
    "Desktop"
)

# Cloud-managed subfolders within media directories. The backup script
# excludes these via rsync --exclude when their app's iCloud sync is on.
# Format: "PARENT|SUBPATH|DETECTION-FN|HUMAN-LABEL"
# DETECTION-FN must be a function defined in scripts/lib/helpers.sh.
CLOUD_SUBDIRS=(
    "Pictures|Photos Library.photoslibrary|is_icloud_photos_enabled|iCloud Photos"
    "Music|Music/Media.localized|is_icloud_music_enabled|iCloud Music Library"
    "Movies|TV/Media.localized|is_icloud_tv_enabled|iCloud TV"
)
```

- [ ] **Step 4: Run, expect pass**

```bash
bats tests/unit/test_configs.bats --filter "CLOUD_TOP_DIRS"
```

Expected: `1 test, 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add config/migration-patterns.sh tests/unit/test_configs.bats
git commit -m "$(cat <<'EOF'
feat: cloud-sync config arrays in migration-patterns.sh

CLOUD_TOP_DIRS — top-level $HOME dirs that may be entirely iCloud-managed
(Desktop & Documents sync). Detection via is_icloud_drive_synced.

CLOUD_SUBDIRS — pipe-delimited entries naming cloud-managed subfolders
within media dirs (Photos Library, Music/Media.localized, TV/Media.localized)
plus the detection function and human-readable label for each.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: Phase 5 — cloud-sync detection summary

**Files:**
- Modify: `tests/integration/test_backup.bats` (append test)
- Modify: `scripts/backup.sh` (insert detection block at start of Phase 5d)

- [ ] **Step 1: Append failing test to `tests/integration/test_backup.bats`**

Append at the end of the file:

```bash
@test "phase 5: cloud-sync summary lists iCloud-managed Documents" {
    prep_required_home_dirs
    make_fake_icloud_dir "$FAKE_HOME/Documents"
    run_backup_yes
    [ "$status" -eq 0 ]
    [[ "$output" == *"Cloud-sync summary"* ]]
    [[ "$output" == *"Documents"* ]]
    [[ "$output" == *"iCloud Desktop"* ]]
}

@test "phase 5: cloud-sync summary skipped when nothing is cloud-synced" {
    prep_required_home_dirs
    run_backup_yes
    [ "$status" -eq 0 ]
    [[ "$output" != *"Cloud-sync summary"* ]]
}
```

- [ ] **Step 2: Run, expect failure**

```bash
bats tests/integration/test_backup.bats --filter "cloud-sync summary"
```

Expected: 1 failure on the first test (output does not contain `Cloud-sync summary`). Second test passes coincidentally before the change but tracks the regression.

- [ ] **Step 3: Insert the detection block in `scripts/backup.sh`**

Find this existing block at lines ~1063–1068:

```bash
# ── 5d. Back up personal files (with classification awareness)
if $ICLOUD_ENABLED; then
    info "Since iCloud is enabled, Documents and Desktop will re-sync on the new Mac."
    info "This backup serves as insurance and for organizing data on restore."
    echo ""
fi
```

**Insert immediately after the `fi` and before the `for dir in ...` loop:**

```bash
# ── 5d-bis. Cloud-sync detection (per docs/superpowers/specs/2026-04-25...) ──
# Build a list of detected cloud-synced paths. CLOUD_DETECTED entries:
#   "TOP|<dir>|<label>"           — entire top-level dir is iCloud-managed
#   "SUB|<parent>|<subpath>|<label>" — known subfolder is cloud-managed
declare -a CLOUD_DETECTED
CLOUD_DETECTED=()

if [ "${#CLOUD_TOP_DIRS[@]}" -gt 0 ]; then
    for top in "${CLOUD_TOP_DIRS[@]}"; do
        if is_icloud_drive_synced "$HOME/$top"; then
            CLOUD_DETECTED+=("TOP|$top|iCloud Desktop & Documents")
        fi
    done
fi

if [ "${#CLOUD_SUBDIRS[@]}" -gt 0 ]; then
    for entry in "${CLOUD_SUBDIRS[@]}"; do
        parent="${entry%%|*}"; rest="${entry#*|}"
        subpath="${rest%%|*}";  rest="${rest#*|}"
        fn="${rest%%|*}"
        label="${rest##*|}"
        if [ -d "$HOME/$parent/$subpath" ] && $fn; then
            CLOUD_DETECTED+=("SUB|$parent|$subpath|$label")
        fi
    done
fi

if [ "${#CLOUD_DETECTED[@]}" -gt 0 ]; then
    info "Cloud-sync summary:"
    for entry in "${CLOUD_DETECTED[@]}"; do
        kind="${entry%%|*}"; rest="${entry#*|}"
        if [ "$kind" = "TOP" ]; then
            d="${rest%%|*}"; lbl="${rest##*|}"
            printf "    ☁ %-12s %s\n" "$d" "$lbl"
        else
            p="${rest%%|*}"; rest2="${rest#*|}"
            sp="${rest2%%|*}"; lbl="${rest2##*|}"
            printf "    ☁ %-12s %s (%s)\n" "$p" "$sp" "$lbl"
        fi
    done
    echo ""
fi
```

- [ ] **Step 4: Run, expect pass**

```bash
bats tests/integration/test_backup.bats --filter "cloud-sync summary"
```

Expected: `2 tests, 0 failures`.

- [ ] **Step 5: Run the full backup suite to confirm no regression**

```bash
bats tests/integration/test_backup.bats
```

Expected: all tests pass (54 tests after this addition).

- [ ] **Step 6: Commit**

```bash
git add scripts/backup.sh tests/integration/test_backup.bats
git commit -m "$(cat <<'EOF'
feat: cloud-sync detection summary in backup.sh Phase 5

Iterates CLOUD_TOP_DIRS and CLOUD_SUBDIRS, calling each entry's detection
helper. When anything is detected, prints a "Cloud-sync summary" block listing
each path and the responsible iCloud feature. The CLOUD_DETECTED array is
consumed by subsequent commits to drive the per-dir loop's three branches.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 8: Phase 5 — Branch 1 (whole-dir cloud skip with inverted prompt)

**Files:**
- Modify: `tests/integration/test_backup.bats`
- Modify: `scripts/backup.sh`

- [ ] **Step 1: Append failing tests**

Append to `tests/integration/test_backup.bats`:

```bash
@test "phase 5: iCloud-managed Documents is skipped by default" {
    prep_required_home_dirs
    make_fake_icloud_dir "$FAKE_HOME/Documents"
    echo "personal-doc" > "$FAKE_HOME/Documents/note.txt"
    run_backup_no  # all 'n' → skip the inverted "Back up anyway?" prompt
    [ "$status" -eq 0 ]
    bd=$(backup_dir)
    [ ! -d "$bd/files/Documents" ]
    grep -q '^CLOUD-SYNCED.*Documents/' "$bd/files/_data-classification.txt"
}

@test "phase 5: iCloud-managed Documents is backed up on 'y' override" {
    prep_required_home_dirs
    make_fake_icloud_dir "$FAKE_HOME/Documents"
    echo "personal-doc" > "$FAKE_HOME/Documents/note.txt"
    run_backup_yes  # 'y' to inverted prompt → back up
    [ "$status" -eq 0 ]
    bd=$(backup_dir)
    [ -d "$bd/files/Documents" ]
    [ -f "$bd/files/Documents/note.txt" ]
}
```

- [ ] **Step 2: Run, expect failure**

```bash
bats tests/integration/test_backup.bats --filter "iCloud-managed Documents"
```

Expected: 2 failures (current loop has only one branch; classification row not written; inverted prompt not in script yet).

- [ ] **Step 3: Replace the personal-files loop in `scripts/backup.sh`**

Find this existing block at lines ~1070–1081:

```bash
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
```

**Replace it with this three-branch version (Branch 1 + classification rows; Branches 2 and 3 added in Tasks 9):**

```bash
# Helper: is this dir's name in CLOUD_DETECTED with kind=TOP?
_dir_is_cloud_top() {
    local q="$1" entry kind name
    for entry in "${CLOUD_DETECTED[@]}"; do
        kind="${entry%%|*}"; name=$(echo "${entry#*|}" | awk -F'|' '{print $1}')
        [ "$kind" = "TOP" ] && [ "$name" = "$q" ] && return 0
    done
    return 1
}

# Helper: print rsync --exclude flags for any cloud SUB entries matching this parent.
_cloud_excludes_for() {
    local parent="$1" entry kind p sp
    for entry in "${CLOUD_DETECTED[@]}"; do
        kind="${entry%%|*}"; rest="${entry#*|}"
        [ "$kind" = "SUB" ] || continue
        p="${rest%%|*}"; rest2="${rest#*|}"
        sp="${rest2%%|*}"
        [ "$p" = "$parent" ] && printf -- "--exclude=%s\n" "$sp"
    done
}

for dir in "$HOME/Documents" "$HOME/Desktop" "$HOME/Downloads" "$HOME/Pictures" "$HOME/Music" "$HOME/Movies"; do
    name=$(basename "$dir")
    [ -d "$dir" ] && [ "$(ls -A "$dir" 2>/dev/null)" ] || continue
    SIZE=$(du -sh "$dir" 2>/dev/null | cut -f1)

    if _dir_is_cloud_top "$name"; then
        # Branch 1: whole dir is iCloud-managed; default-skip with inverted prompt.
        warn "☁ $name — iCloud Desktop & Documents sync is enabled"
        info "  Files in this folder live in iCloud and re-sync automatically on the"
        info "  new Mac when you sign in. Local-only files (if any) are NOT in iCloud."
        echo "CLOUD-SYNCED   | $name/ | $SIZE | iCloud Desktop & Documents — re-syncs on new Mac" >> "$DATA_CLASS"
        confirm "Back up anyway as offline insurance?" && {
            rsync -a --progress \
                --exclude='.DS_Store' \
                --exclude='workspace/.metadata' \
                "$dir/" "$FILES/$name/" 2>/dev/null
            log "$name (overridden — offline copy captured)"
        }
        continue
    fi

    confirm "Back up $name ($SIZE on disk)?" && {
        rsync -a --progress \
            --exclude='.DS_Store' \
            --exclude='workspace/.metadata' \
            "$dir/" "$FILES/$name/" 2>/dev/null
        log "$name"
    }
done
```

Note: `$DATA_CLASS` is the classification file path, set earlier in Phase 5c at `DATA_CLASS="$FILES/_data-classification.txt"`. The Branch 1 block appends a `CLOUD-SYNCED` row regardless of the prompt answer (it documents what was detected).

- [ ] **Step 4: Run the new tests, expect pass**

```bash
bats tests/integration/test_backup.bats --filter "iCloud-managed Documents"
```

Expected: `2 tests, 0 failures`.

- [ ] **Step 5: Run the full backup suite to confirm no regression**

```bash
bats tests/integration/test_backup.bats
```

Expected: all tests pass.

- [ ] **Step 6: Commit**

```bash
git add scripts/backup.sh tests/integration/test_backup.bats
git commit -m "$(cat <<'EOF'
feat: Phase 5 Branch 1 — skip iCloud Documents/Desktop by default

For dirs flagged as TOP in CLOUD_DETECTED (whole-dir iCloud-managed),
print an advisory, write a CLOUD-SYNCED row to _data-classification.txt
unconditionally, and prompt with the inverted "Back up anyway?" question.
Default behavior (any non-y answer) is skip; explicit y still captures the
offline copy.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 9: Phase 5 — Branch 2 (cloud subfolder rsync exclude)

**Files:**
- Modify: `tests/integration/test_backup.bats`
- Modify: `scripts/backup.sh`

- [ ] **Step 1: Append failing tests**

Append to `tests/integration/test_backup.bats`:

```bash
@test "phase 5: Pictures with iCloud Photos excludes Photos Library from rsync" {
    prep_required_home_dirs
    mkdir -p "$FAKE_HOME/Pictures/Photos Library.photoslibrary"
    echo "fake" > "$FAKE_HOME/Pictures/Photos Library.photoslibrary/Library.apdb"
    echo "imported" > "$FAKE_HOME/Pictures/imported-photo.jpg"
    # Mock defaults to report iCloud Photos enabled.
    mock_command_script defaults <<'EOF'
case "$@" in
    *iCloudPhotoLibraryEnabled*) echo "1"; exit 0 ;;
esac
exit 1
EOF
    # Ensure the Photos prefs path exists so the helper's [ -f ] check passes.
    mkdir -p "$FAKE_HOME/Library/Containers/com.apple.Photos/Data/Library/Preferences"
    : > "$FAKE_HOME/Library/Containers/com.apple.Photos/Data/Library/Preferences/com.apple.Photos.plist"
    # Capture rsync invocation to assert --exclude.
    mock_command_script rsync <<'EOF'
echo "$@" >> "$MOCK_BIN/rsync.calls"
exit 0
EOF
    run_backup_yes
    [ "$status" -eq 0 ]
    bd=$(backup_dir)
    grep -q '^CLOUD-SYNCED.*Photos Library.photoslibrary' "$bd/files/_data-classification.txt"
    grep -q -- '--exclude=Photos Library.photoslibrary' "$MOCK_BIN/rsync.calls"
}

@test "phase 5: Pictures with iCloud Photos OFF backs up everything (regression guard)" {
    prep_required_home_dirs
    mkdir -p "$FAKE_HOME/Pictures/Photos Library.photoslibrary"
    echo "fake" > "$FAKE_HOME/Pictures/Photos Library.photoslibrary/Library.apdb"
    # defaults stays the default mock (silent / fails / 0). is_icloud_photos_enabled
    # returns false because the prefs file does not exist.
    mock_command_script rsync <<'EOF'
echo "$@" >> "$MOCK_BIN/rsync.calls"
exit 0
EOF
    run_backup_yes
    [ "$status" -eq 0 ]
    # No --exclude for Photos Library in any rsync call.
    ! grep -q -- '--exclude=Photos Library.photoslibrary' "$MOCK_BIN/rsync.calls"
}
```

- [ ] **Step 2: Run, expect failure**

```bash
bats tests/integration/test_backup.bats --filter "iCloud Photos"
```

Expected: first test fails (no `--exclude` emitted by current rsync). Second passes coincidentally but locks in regression behavior.

- [ ] **Step 3: Update the per-dir loop to add Branch 2**

In `scripts/backup.sh`, find the loop body added in Task 8. Replace the **final** `confirm "Back up $name ..."` block (the Branch 3 default) with this version that handles Branch 2 first:

Replace this:

```bash
    confirm "Back up $name ($SIZE on disk)?" && {
        rsync -a --progress \
            --exclude='.DS_Store' \
            --exclude='workspace/.metadata' \
            "$dir/" "$FILES/$name/" 2>/dev/null
        log "$name"
    }
done
```

With this:

```bash
    # Branch 2: dir contains known cloud-managed subfolders → rsync --exclude.
    cloud_excludes=$(_cloud_excludes_for "$name")
    if [ -n "$cloud_excludes" ]; then
        warn "☁ $name — found cloud-managed subfolder(s), will be excluded:"
        for entry in "${CLOUD_DETECTED[@]}"; do
            kind="${entry%%|*}"; rest="${entry#*|}"
            [ "$kind" = "SUB" ] || continue
            p="${rest%%|*}"; rest2="${rest#*|}"
            sp="${rest2%%|*}"; lbl="${rest2##*|}"
            if [ "$p" = "$name" ]; then
                info "    - $sp ($lbl)"
                # Compute the excluded subfolder's actual size so the row is informative.
                sub_size=$(du -sh "$dir/$sp" 2>/dev/null | cut -f1)
                echo "CLOUD-SYNCED   | $name/$sp/ | ${sub_size:-?} | $lbl — re-syncs on new Mac" >> "$DATA_CLASS"
            fi
        done
        confirm "Back up $name (cloud subfolder(s) excluded)?" && {
            # shellcheck disable=SC2086 - $cloud_excludes is intentionally word-split into multiple --exclude flags.
            rsync -a --progress \
                --exclude='.DS_Store' \
                --exclude='workspace/.metadata' \
                $cloud_excludes \
                "$dir/" "$FILES/$name/" 2>/dev/null
            log "$name (cloud subfolders excluded)"
        }
        continue
    fi

    # Branch 3: no cloud sync — existing behavior.
    confirm "Back up $name ($SIZE on disk)?" && {
        rsync -a --progress \
            --exclude='.DS_Store' \
            --exclude='workspace/.metadata' \
            "$dir/" "$FILES/$name/" 2>/dev/null
        log "$name"
    }
done
```

- [ ] **Step 4: Run the new tests, expect pass**

```bash
bats tests/integration/test_backup.bats --filter "iCloud Photos"
```

Expected: `2 tests, 0 failures`.

- [ ] **Step 5: Run the full backup suite**

```bash
bats tests/integration/test_backup.bats
```

Expected: all tests pass.

- [ ] **Step 6: Commit**

```bash
git add scripts/backup.sh tests/integration/test_backup.bats
git commit -m "$(cat <<'EOF'
feat: Phase 5 Branch 2 — exclude cloud subfolders from rsync

For dirs whose name matches CLOUD_DETECTED entries with kind=SUB (Photos
Library when iCloud Photos is on, Apple Music's Media.localized when Sync
Library is on, etc.), rsync runs with --exclude=<subpath> for each match.
The local-only remainder is captured normally. CLOUD-SYNCED rows for each
excluded subfolder are written to _data-classification.txt for the restore
script's advisory.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 10: Step 14 — CLOUD-SYNCED advisory block

**Files:**
- Modify: `tests/integration/test_restore.bats`
- Modify: `scripts/restore.sh`

- [ ] **Step 1: Append failing test**

Append to `tests/integration/test_restore.bats`:

```bash
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
```

Note: `setup_fake_backup` creates `$FAKE_BACKUP/files/` but not `_data-classification.txt`. The `cat >>` operator creates the file on first write, so the test above does not need to pre-create it.

- [ ] **Step 2: Run, expect failure**

```bash
bats tests/integration/test_restore.bats --filter "CLOUD-SYNCED advisory"
```

Expected: 1 failure (output does not contain `☁ Cloud-synced sources`).

- [ ] **Step 3: Insert advisory block in `scripts/restore.sh`**

Find the existing APP-DATA block ending at line ~645 (look for `info "  These directories are created by specific apps — restore only if the app is installed."`). **Insert the advisory block immediately after that block's closing `fi`, but before the closing `fi` of the outer `if [ -f "$DATA_CLASS" ]`:**

```bash
    # Show cloud-synced data — already restoring via account sign-in
    CLOUD_COUNT=$(grep -c "^CLOUD-SYNCED" "$DATA_CLASS" 2>/dev/null || echo 0)
    if [ "$CLOUD_COUNT" -gt 0 ]; then
        info "☁ Cloud-synced sources present in backup but skipped by default:"
        grep "^CLOUD-SYNCED" "$DATA_CLASS" | while IFS='|' read -r tag name size note; do
            name=$(echo "$name" | xargs)
            size=$(echo "$size" | xargs)
            note=$(echo "$note" | xargs)
            echo "    $name ($size) — $note"
        done || true
        info "  These will re-sync from iCloud after you sign in (preferred)."
        info "  To copy from the backup drive instead, re-run with:"
        info "    MBR_RESTORE_CLOUD=1 bash <restore-command>"
        echo ""
    fi
```

The `|| true` after `done` follows the established hardening pattern from earlier commits (set -euo pipefail + grep no-match would otherwise kill the script).

- [ ] **Step 4: Run, expect pass**

```bash
bats tests/integration/test_restore.bats --filter "CLOUD-SYNCED advisory"
```

Expected: `1 test, 0 failures`.

- [ ] **Step 5: Run the full restore suite**

```bash
bats tests/integration/test_restore.bats
```

Expected: all tests pass.

- [ ] **Step 6: Commit**

```bash
git add scripts/restore.sh tests/integration/test_restore.bats
git commit -m "$(cat <<'EOF'
feat: Step 14 advisory for CLOUD-SYNCED items

Reads CLOUD-SYNCED rows from _data-classification.txt and prints an
advisory listing each cloud-synced source with its size and the iCloud
feature responsible. Tells the user how to override with MBR_RESTORE_CLOUD=1.
This is informational only — the actual skip gate ships in the next commit.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 11: Step 14 — skip gate honoring `MBR_RESTORE_CLOUD`

**Files:**
- Modify: `tests/integration/test_restore.bats`
- Modify: `scripts/restore.sh`

- [ ] **Step 1: Append failing tests**

Append to `tests/integration/test_restore.bats`:

```bash
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
    output=$(MBR_RESTORE_CLOUD=1 printf 'y%.0s' $(seq 1 400) | \
        /bin/bash "$SCRIPTS_DIR/restore.sh" "$FAKE_BACKUP" 2>&1)
    status=$?
    [ "$status" -eq 0 ]
    grep -q "files/Documents" "$MOCK_BIN/rsync.calls"
}
```

- [ ] **Step 2: Run, expect failure**

```bash
bats tests/integration/test_restore.bats --filter "CLOUD-SYNCED dirs"
```

Expected: 2 failures (current loop has no skip gate; rsync IS called for Documents in both scenarios).

- [ ] **Step 3: Add the skip gate in `scripts/restore.sh`**

Find the personal-files restore loop at line ~717:

```bash
for dir in "$FILES_SRC"/*/; do
    [ -d "$dir" ] || continue
    name=$(basename "$dir")
    # Skip items handled in other steps
    case "$name" in
        Screenshots|scattered-credentials|auth-tokens) continue ;;
    esac
    SIZE=$(du -sh "$dir" 2>/dev/null | cut -f1)
```

**Insert the skip gate immediately after the existing `case` block, before `SIZE=$(...)`:**

```bash
    # Skip items the backup classified as CLOUD-SYNCED unless user opted in.
    if [ -f "$DATA_CLASS" ] \
       && [ "${MBR_RESTORE_CLOUD:-}" != "1" ] \
       && grep -q "^CLOUD-SYNCED.*${name}/" "$DATA_CLASS" 2>/dev/null; then
        info "  ☁ skipping $name — cloud-synced (re-syncs from iCloud)"
        continue
    fi
```

- [ ] **Step 4: Run, expect pass**

```bash
bats tests/integration/test_restore.bats --filter "CLOUD-SYNCED dirs"
```

Expected: `2 tests, 0 failures`.

- [ ] **Step 5: Run the full restore suite**

```bash
bats tests/integration/test_restore.bats
```

Expected: all tests pass.

- [ ] **Step 6: Run the full bats suite (all unit + integration)**

```bash
bats tests/unit/ tests/integration/
```

Expected: full suite green. Note total — should be at least the prior 199 plus the new tests added in this plan (≈211).

- [ ] **Step 7: Commit**

```bash
git add scripts/restore.sh tests/integration/test_restore.bats
git commit -m "$(cat <<'EOF'
feat: Step 14 skip gate for CLOUD-SYNCED items

In the personal-files restore loop, skip any directory whose name appears in
a CLOUD-SYNCED row of _data-classification.txt unless MBR_RESTORE_CLOUD=1 is
set. The advisory printed earlier in the step explains this behavior to the
user. iCloud will re-sync these on sign-in.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 12: README updates

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Update the Migration Patterns section**

In `README.md`, find the paragraph at the end of the "Migration Patterns" section that begins with "The backup script generates a `migration-manifest.txt`...". **Append this new paragraph after it:**

```markdown
**Pattern 1 covers app-internal cloud sync** (1Password, Microsoft 365, ChatGPT, VS Code Settings Sync, JetBrains Account, Chrome account sync, etc.) — handled via the `SIGN_IN_APPS` array in `config/migration-patterns.sh`. **macOS-level cloud sync is handled separately by Phase 5's cloud-sync detection** (see [Design Decisions](#design-decisions-and-best-practices)) — iCloud Drive, iCloud Photos, iCloud Music Library, and TV.app library are detected automatically and skipped by default since they re-sync from iCloud on the new Mac.
```

- [ ] **Step 2: Update the Backup on the External Drive section**

Find the paragraph that describes `_data-classification.txt`. The existing text mentions tags `STALE`, `ARCHIVAL`, `APP-DATA`, etc. **Update it to include `CLOUD-SYNCED`:**

Replace:

```markdown
The `_data-classification.txt` file in `files/` categorizes every data directory by type: cloud-synced (will re-sync via iCloud), documents (personal and work files), archival (large old data like Zoom recordings), app-data (created by specific apps, only useful if the app is installed), media (photos, videos), and stale (multi-machine sync artifacts from old devices).
```

With:

```markdown
The `_data-classification.txt` file in `files/` categorizes every data directory by type: `CLOUD-SYNCED` (managed by iCloud — Photos Library, Music library, Documents/Desktop sync, etc.; re-syncs on the new Mac), `DOCUMENTS` (personal and work files), `ARCHIVAL` (large old data like Zoom recordings), `APP-DATA` (created by specific apps, only useful if the app is installed), `MEDIA` (photos, videos), and `STALE` (multi-machine sync artifacts from old devices).
```

- [ ] **Step 3: Add a new bullet to Design Decisions and Best Practices**

In `README.md`, find the "Design Decisions and Best Practices" section. **Insert this new bullet at a logical position (after the "Brew-first install strategy" bullet works well — it's about install-time strategy and this is about backup-time strategy):**

```markdown
**macOS-level cloud sync detection.** Phase 5 of `backup.sh` detects directories that macOS already syncs via iCloud and skips them by default — Documents/Desktop under iCloud Drive sync, Photos Library under iCloud Photos, Apple Music's library, and TV.app's library. Detection is per-subdirectory (whole-dir via xattr, sub-dir via the app's iCloud sync flag); per-file stub detection is intentionally avoided for performance. The user can override per-prompt during backup ("Back up anyway?") if they want offline copies. On restore, cloud-synced items are skipped silently with an advisory pointing to `MBR_RESTORE_CLOUD=1` for users who want to copy from the backup drive instead of waiting for iCloud to re-sync. The detection lists are configurable in `config/migration-patterns.sh` (`CLOUD_TOP_DIRS`, `CLOUD_SUBDIRS`).
```

- [ ] **Step 4: Update the How to Use: Restore section**

Find the "How to Use: Restore" section. After the existing "What happens" text and before "Step 0 — macOS Preferences", **append:**

```markdown
### Cloud-synced data on restore

Directories the backup classified as `CLOUD-SYNCED` (Documents/Desktop with iCloud sync, Photos Library, Apple Music library, TV.app library) are skipped by default during Step 14. This is intentional — iCloud will re-sync them automatically once you sign in. The restore script prints an advisory listing each skipped item.

If you want to restore from the backup drive instead (e.g. you don't trust iCloud, or your data was offloaded to stubs and you want the local copy that was captured), set the env var:

```bash
MBR_RESTORE_CLOUD=1 bash /Volumes/YourDrive/mac-backup-restore/scripts/restore.sh \
    /Volumes/YourDrive/mac-backup/<TIMESTAMP>
```
```

- [ ] **Step 5: Verify the README still renders sanely**

```bash
pandoc -s --css=https://cdn.jsdelivr.net/npm/github-markdown-css@5/github-markdown-light.css \
  -o /tmp/readme-preview.html README.md && open /tmp/readme-preview.html
```

Visually inspect the four updated sections — no broken markdown, no orphan headings.

- [ ] **Step 6: Commit**

```bash
git add README.md
git commit -m "$(cat <<'EOF'
docs: README updates for cloud-sync detection

Adds explanation of the new Phase 5 cloud-detection feature in four places:
Migration Patterns (mentions Category 1 vs Category 2), Backup section's
classification description (CLOUD-SYNCED tag), Design Decisions (philosophy
and override mechanisms), and Restore section (MBR_RESTORE_CLOUD usage).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Spec coverage check

| Spec section | Implementing task |
|---|---|
| Detection rules A (top-level iCloud dirs) | Task 1 (helper), Task 6 (config), Task 7 (summary), Task 8 (Branch 1) |
| Detection rules B (cloud-managed subfolders) | Tasks 2–4 (helpers), Task 6 (config), Task 7 (summary), Task 9 (Branch 2) |
| Detection rules C (Library treatment) | No code change — already excluded; documented in README (Task 12) |
| Detection rules D (already-handled providers) | Unchanged — no task |
| Edge case: stub files in overridden dir | Branch 1 implementation (rsync copies what's on disk; warning text in advisory) |
| Edge case: iCloud feature off | Helpers return false → Branches 2/3 execute correctly (Tasks 7, 9) |
| Edge case: classification snapshot vs live state | `_data-classification.txt` is read on restore — Task 11 honors recorded state |
| Backup-side prompt UX (3 branches) | Tasks 7, 8, 9 |
| Cloud-sync summary block | Task 7 |
| `_data-classification.txt` `CLOUD-SYNCED` rows | Task 8 (TOP), Task 9 (SUB) |
| Restore advisory | Task 10 |
| `MBR_RESTORE_CLOUD=1` override | Task 11 |
| Manual validation (5 commands) | Task 5 |
| README updates (4 places) | Task 12 |
| Backwards compatibility | Implicit — old classifications don't have CLOUD-SYNCED rows; new tag is invisible to old restore.sh |

All spec sections covered. No placeholders remain in the plan.

---

## Plan complete

Saved to `docs/superpowers/plans/2026-04-25-cloud-sync-detection.md`.

**Two execution options:**

1. **Subagent-Driven (recommended)** — I dispatch a fresh subagent per task, review between tasks, fast iteration. Each task is small enough for a focused subagent context.

2. **Inline Execution** — I execute tasks here in this session using `executing-plans`, with checkpoints between major task groups for your review.

**Which approach?**
