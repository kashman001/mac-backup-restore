# Cloud-Sync Detection — Design

**Date:** 2026-04-25
**Status:** Approved (pending implementation plan)
**Scope:** Backup and restore scripts + helpers library + config + tests + README. (`verify.sh` is unchanged.)

## Summary

Add macOS-level cloud-sync detection to `backup.sh` so directories that re-sync automatically from iCloud on a new Mac (Documents/Desktop under iCloud Drive sync, Photos Library under iCloud Photos, Music library under iCloud Music Library, TV.app library) are **skipped by default**. The user can override either per-prompt during backup or via an environment variable on restore. Detection covers Pictures, Music, Movies, and the Library subtree in addition to the Documents/Desktop coverage that exists today.

The feature is per-subdirectory (not per-file). Whole-directory cloud-sync is detected via xattr; subfolders managed by individual macOS apps (Photos, Music, TV) are detected by combining (subfolder exists) with (the app's iCloud sync flag is on).

## Background & Motivation

Today's `backup.sh` Phase 5 prompts per top-level home directory (`Documents`, `Desktop`, `Downloads`, `Pictures`, `Music`, `Movies`) without checking whether each is iCloud-managed. Users of iCloud Desktop & Documents sync end up either backing up many gigabytes of data that re-sync from iCloud automatically (waste), or skipping it manually each time (friction).

The existing toolkit already detects third-party cloud-storage clients (OneDrive, Dropbox, Google Drive, Box) and skips them by default in Phase 5b. This feature applies the same philosophy to macOS-level cloud sync.

### Two distinct categories of "app cloud sync"

This design addresses Category 1 only.

- **Category 1 — macOS-managed cloud paths.** Data lives in predictable file-system locations and macOS handles the sync. Examples: iCloud Drive, iCloud Photos, iCloud Music Library, TV.app. Detectable via xattrs and `defaults` queries.
- **Category 2 — App-internal cloud sync.** Vendor cloud services with proprietary sync mechanisms. Examples: 1Password, Microsoft 365, ChatGPT, VS Code Settings Sync, JetBrains Account, Chrome account sync. **Not auto-detected.** Handled today via the `SIGN_IN_APPS` array in `config/migration-patterns.sh` (Pattern 1 in `migration-manifest.txt`). User curates that list.

Auto-detecting Category 2 would require per-vendor probing (each vendor stores sync state differently, often in proprietary databases) and would drift out of date as vendors change their internals. The config-driven approach for Category 2 is deliberate.

## Scope

### In scope

- New detection helpers in `scripts/lib/helpers.sh`
- New cloud-sync config arrays in `config/migration-patterns.sh`
- Phase 5 changes in `scripts/backup.sh` — detection summary, three-branch per-dir loop, `CLOUD-SYNCED` rows in `_data-classification.txt`
- Step 14 changes in `scripts/restore.sh` — advisory block + `MBR_RESTORE_CLOUD=1` override
- Unit tests for the four detection helpers
- Integration tests for new Phase 5 and Step 14 behavior
- README updates

### Out of scope

- Per-file stub detection via `mdls` (too slow)
- App-level cloud sync auto-detection (Category 2) — config-driven via existing `SIGN_IN_APPS`
- New CLI flags on the scripts (env vars are simpler and match the existing OneDrive override pattern)
- A `verify.sh` cloud-sync section
- Detection of corporate file-sync products beyond what `CLOUD_SUBDIRS` allows users to add

## Detection Rules

### A. Top-level `$HOME` dirs entirely iCloud-managed

`~/Documents` and `~/Desktop` when iCloud Desktop & Documents sync is on. Detection: the iCloud File Provider stamps an xattr on managed directories.

```
xattr -p com.apple.file-provider-domain-id "$DIR" 2>/dev/null \
    | grep -q "CloudDocs.iCloudDriveFileProvider"
```

### B. Cloud-managed subfolders within media directories

Combine (subfolder exists on disk) with (the app's iCloud sync flag is on). If the library exists but iCloud sync is off, back up normally.

| Subdir | App | Sync-flag check |
|---|---|---|
| `~/Pictures/Photos Library.photoslibrary` | Photos | `defaults read ~/Library/Containers/com.apple.Photos/Data/Library/Preferences/com.apple.Photos.plist iCloudPhotoLibraryEnabled` = 1 |
| `~/Music/Music/Media.localized` | Apple Music | `defaults read com.apple.Music cloudLibraryEnabled` = 1 |
| `~/Movies/TV/Media.localized` | TV.app | `defaults read com.apple.TV cloudLibraryEnabled` = 1 |

### C. Library folder treatment

Already excluded from project/dotfile/credential scans by `-not -path "*/Library/*"`. The app-settings phase explicitly captures specific paths under `~/Library/Application Support/<app>/` per `config/app-settings.sh`. These captured paths are app configurations, not cloud-synced data, so no change is needed.

`~/Library/Mobile Documents/` (all iCloud per-app containers) and `~/Library/CloudStorage/` (modern macOS File Provider for OneDrive/Dropbox/Google Drive/Box) are excluded by the same Library-pruning rules and by the existing Phase 5b cloud-storage detection respectively.

### D. Already handled (unchanged by this feature)

- `~/OneDrive/`, `~/Dropbox/`, `~/Google Drive/`, `~/Box/`
- `~/Library/CloudStorage/OneDrive-*/`, `Dropbox/`, `GoogleDrive-*/`, `Box-Box/`

These are detected and default-skipped in current Phase 5b. The new cloud-sync feature uses the same UX pattern (inverted prompt) for consistency.

### Edge case handling

| Case | Resolution |
|---|---|
| Stub files inside a cloud dir the user overrode to back up | Trust rsync. Print a warning advising "Download Now" via Finder for full content. No per-file `mdls`. |
| iCloud Photos disabled but Photos Library exists | Back up the library normally — sync-flag gating ensures this. |
| Apple Music with no Sync Library | Back up normally — sync-flag gating ensures this. |
| `~/Documents` is iCloud-managed but user wants offline copy | Explicit `y` to "Back up anyway?" prompt overrides. |
| iCloud state flipped between backup and restore | Backup classifies based on backup-time state recorded in `_data-classification.txt`. Restore reads the classification, not live state. Decisions stay consistent. |
| `~/Documents` is iCloud-managed but contains a non-iCloud subfolder | Whole-dir skip default-misses these. Documented as a known limitation; user can override the prompt to capture everything. |

## User-Facing Behavior

### Backup-side: Phase 5 prompts

Three branches based on detection. Today's flow is uniform; the new flow distinguishes:

**Branch 1 — Whole dir is iCloud-managed.** Inverted prompt (default = skip).

```
☁ Documents — iCloud Desktop & Documents sync is enabled
  Files in this folder live in iCloud and re-sync automatically on the
  new Mac when you sign in. Local-only files (if any) are NOT in iCloud.

  Back up anyway as offline insurance? (y/n)
```

**Branch 2 — Dir has known cloud-managed subfolders.** Normal prompt (default = back up local-only); rsync excludes the cloud subfolder.

```
☁ Pictures — found 1 cloud-managed subfolder, will be excluded:
    - Photos Library.photoslibrary (iCloud Photos enabled)
  Local-only contents will be backed up.

  Back up Pictures (245M after exclusions, was 87G with cloud library)? (y/n)
```

**Branch 3 — No cloud sync.** Existing prompt unchanged.

```
Back up Movies (12G on disk)? (y/n)
```

### Backup-side: cloud-sync summary

Printed once at the start of Phase 5, before the per-dir prompts:

```
Cloud-sync summary:
  ☁ Documents          iCloud Desktop & Documents
  ☁ Desktop            iCloud Desktop & Documents
  ☁ Pictures           Photos Library.photoslibrary (iCloud Photos)
  ☁ Music              Music/Media.localized (iCloud Music Library)
  ─ Downloads          local
  ─ Movies             local
```

### Data classification

`_data-classification.txt` already has tags `STALE`, `ARCHIVAL`, `APP-DATA`, `DOCUMENTS`, `MEDIA`. Adds `CLOUD-SYNCED`:

```
CLOUD-SYNCED   | Documents/                   | 15G    | iCloud Desktop & Documents — re-syncs on new Mac
CLOUD-SYNCED   | Desktop/                     | 1.2G   | iCloud Desktop & Documents — re-syncs on new Mac
CLOUD-SYNCED   | Pictures/Photos Library.photoslibrary/ | 87G  | iCloud Photos — re-downloads on new Mac
CLOUD-SYNCED   | Music/Music/Media.localized/ | 18G    | iCloud Music Library — re-syncs on new Mac
```

### Restore-side: Step 14 advisory + override

Existing classification consumer prints an additional `CLOUD-SYNCED` block:

```
☁ Cloud-synced sources present in backup but skipped by default:
    Documents/ (15G)                                  iCloud Desktop & Documents
    Pictures/Photos Library.photoslibrary/ (87G)      iCloud Photos
    Music/Music/Media.localized/ (18G)                iCloud Music Library

  These will re-sync from iCloud after you sign in (preferred).
  To copy from the backup drive instead, re-run with:

    MBR_RESTORE_CLOUD=1 bash /Volumes/M4MBABackup/mac-backup-restore/scripts/restore.sh \
        /Volumes/M4MBABackup/mac-backup/<TIMESTAMP>
```

### Override mechanism summary

| Side | Default | How to override |
|---|---|---|
| Backup, whole-dir cloud (Branch 1) | Skip | Answer `y` to "Back up anyway?" prompt per dir |
| Backup, subfolder cloud (Branch 2) | Back up parent, exclude subfolder | No per-prompt override. Users who want the cloud subfolder included edit `CLOUD_SUBDIRS` in `config/migration-patterns.sh` to remove the entry. |
| Restore, classified `CLOUD-SYNCED` items | Skip | `MBR_RESTORE_CLOUD=1` env var (any other value or unset = skip) |

There is intentionally no whole-script "include all cloud" backup override. Per-prompt `y` on each Branch 1 dir covers the realistic case ("I want offline copies of Documents and Desktop"). A future `MBR_BACKUP_CLOUD` env var can be added if users ask for it; YAGNI for now.

## Implementation Structure

### Files modified

| File | Why |
|---|---|
| `scripts/lib/helpers.sh` | Add 4 detection helper functions (~30 lines) |
| `config/migration-patterns.sh` | Add 2 cloud-sync arrays |
| `scripts/backup.sh` | Phase 5 — detection summary, three-branch loop, classification rows (~80 lines) |
| `scripts/restore.sh` | Step 14 — advisory + skip gate (~25 lines) |
| `tests/test_helper.bash` | One fixture: `make_fake_icloud_dir <path>` |
| `tests/unit/test_helpers_lib.bats` | Unit tests for the 4 helpers |
| `tests/integration/test_backup.bats` | Phase 5 cloud-detect tests |
| `tests/integration/test_restore.bats` | Step 14 cloud-skip tests |
| `README.md` | 4 small updates (Migration Patterns, classification, design decisions, restore env var) |

### New helpers (`scripts/lib/helpers.sh`)

Bash 3.2 compatible. Each helper returns 0/1 with no stdout. Same idiom as `has`.

```bash
# Returns 0 if PATH is part of iCloud Desktop & Documents sync.
is_icloud_drive_synced() {
    xattr -p com.apple.file-provider-domain-id "$1" 2>/dev/null \
        | grep -q "CloudDocs.iCloudDriveFileProvider"
}

# Returns 0 if iCloud Photos sync is enabled.
is_icloud_photos_enabled() {
    local p="$HOME/Library/Containers/com.apple.Photos/Data/Library/Preferences/com.apple.Photos.plist"
    [ -f "$p" ] || return 1
    [ "$(defaults read "$p" iCloudPhotoLibraryEnabled 2>/dev/null)" = "1" ]
}

# Returns 0 if Apple Music's iCloud Music Library / Sync Library is on.
is_icloud_music_enabled() {
    [ "$(defaults read com.apple.Music cloudLibraryEnabled 2>/dev/null)" = "1" ]
}

# Returns 0 if TV.app's iCloud / iTunes-in-the-Cloud is on.
is_icloud_tv_enabled() {
    [ "$(defaults read com.apple.TV cloudLibraryEnabled 2>/dev/null)" = "1" ]
}
```

### New config (`config/migration-patterns.sh`)

Pipe-delimited arrays, matching the existing `CASK_MAP` / `LICENSE_PLISTS` idiom.

```bash
# Top-level $HOME directories that may be fully iCloud-managed.
# Detection at runtime via is_icloud_drive_synced() on the dir.
CLOUD_TOP_DIRS=(
    "Documents"
    "Desktop"
)

# Cloud-managed subfolders within media directories. Excluded from the
# parent dir's rsync when the app's iCloud sync is on.
# Format: "PARENT|SUBPATH|DETECTION-FN|HUMAN-LABEL"
CLOUD_SUBDIRS=(
    "Pictures|Photos Library.photoslibrary|is_icloud_photos_enabled|iCloud Photos"
    "Music|Music/Media.localized|is_icloud_music_enabled|iCloud Music Library"
    "Movies|TV/Media.localized|is_icloud_tv_enabled|iCloud TV"
)
```

User-extensible. New cloud-managed paths are one-line additions.

### Phase 5 changes (`scripts/backup.sh`)

Replaces the current single-loop personal-files block (~lines 1070–1081). New structure:

1. **Build `CLOUD_DETECTED` list** by iterating `CLOUD_TOP_DIRS` (calling `is_icloud_drive_synced`) and `CLOUD_SUBDIRS` (parsing each entry, calling its detection fn).
2. **Print cloud-sync summary** if anything was detected.
3. **Append `CLOUD-SYNCED` rows** to `$DATA_CLASS`.
4. **Per-dir loop with three branches** (whole-dir cloud → inverted prompt; subfolder cloud → rsync `--exclude`; otherwise → existing path).

### Step 14 changes (`scripts/restore.sh`)

Two additions to the existing classification consumer:

1. **Advisory block** after the existing STALE / ARCHIVAL / APP-DATA blocks. Lists `CLOUD-SYNCED` rows with the override hint.
2. **Skip gate** in the personal-files restore loop: if the directory has a `CLOUD-SYNCED` classification AND `MBR_RESTORE_CLOUD` ≠ `1`, log a "skipped (will re-sync from iCloud)" line and continue.

## Test Plan

### Unit tests (`tests/unit/test_helpers_lib.bats`)

| Test | Asserts |
|---|---|
| `is_icloud_drive_synced` true given the right xattr | xattr fixture matches the regex |
| `is_icloud_drive_synced` false on a plain dir | negative case |
| `is_icloud_photos_enabled` true when prefs flag is 1 | reads the plist correctly |
| `is_icloud_photos_enabled` false when prefs file missing | safe default |
| `is_icloud_music_enabled` true / false (symmetric) | same pattern |
| `is_icloud_tv_enabled` true / false (symmetric) | same pattern |

### Integration tests (`tests/integration/test_backup.bats`)

| Test | Asserts |
|---|---|
| Phase 5 prints cloud-sync summary when iCloud Documents detected | output contains `☁ Documents` |
| Phase 5 default-skips iCloud Documents (writes `CLOUD-SYNCED` row, no rsync called) | classification file content + mock rsync not called for that dir |
| Phase 5 with Photos Library + iCloud Photos uses rsync `--exclude` | mock rsync's recorded args contain `--exclude=Photos Library.photoslibrary` |
| Phase 5 with Photos Library but iCloud Photos OFF backs up normally (regression guard) | rsync called without exclude |
| Phase 5 with no iCloud at all behaves identically to today (regression guard) | identical output to current tests for that path |

### Integration tests (`tests/integration/test_restore.bats`)

| Test | Asserts |
|---|---|
| Step 14 prints `CLOUD-SYNCED` advisory when classification has rows | output contains the override hint |
| Step 14 skips `CLOUD-SYNCED` dirs by default | rsync NOT called for those dirs |
| Step 14 with `MBR_RESTORE_CLOUD=1` does restore them | rsync IS called |

### New fixture (`tests/test_helper.bash`)

```bash
# Drop the iCloud File Provider xattr on a directory so detection helpers
# see it as cloud-managed.
make_fake_icloud_dir() {
    local dir="$1"
    mkdir -p "$dir"
    xattr -w com.apple.file-provider-domain-id \
        "com.apple.CloudDocs.iCloudDriveFileProvider/AAAA-BBBB" "$dir"
}
```

## Manual Validation

Before locking in the detection signals, the implementation phase verifies each one against the user's actual Mac. The plist paths and xattr keys come from public Apple conventions but can drift between macOS versions.

| Helper | Validation command | Expected result |
|---|---|---|
| `is_icloud_drive_synced ~/Documents` | `xattr -p com.apple.file-provider-domain-id ~/Documents` | non-empty, contains `CloudDocs` |
| `is_icloud_drive_synced ~/Movies` | same on `~/Movies` | empty |
| `is_icloud_photos_enabled` | `defaults read ~/Library/Containers/com.apple.Photos/Data/Library/Preferences/com.apple.Photos.plist iCloudPhotoLibraryEnabled` | `1` (if iCloud Photos on) or missing |
| `is_icloud_music_enabled` | `defaults read com.apple.Music cloudLibraryEnabled` | `1` or missing |
| `is_icloud_tv_enabled` | `defaults read com.apple.TV cloudLibraryEnabled` | `1` or missing |

If any returns differently than expected, the corresponding helper is adjusted before the implementation lands. No design change.

## README Changes

1. **Migration Patterns** — add one paragraph: Pattern 1 (Sign In) covers app-internal cloud sync; the cloud-detect feature handles macOS-level sync separately.
2. **Backup on the External Drive** — update the description of `_data-classification.txt` to mention the `CLOUD-SYNCED` tag (two lines).
3. **Design Decisions and Best Practices** — new bullet `**macOS-level cloud sync detection**` (~80 words) explaining philosophy, override mechanisms, helpers and config layout.
4. **How to Use: Restore** — mention `MBR_RESTORE_CLOUD=1` for restoring cloud-synced data from the backup drive (two lines).

## Backwards Compatibility

- Old `_data-classification.txt` (no `CLOUD-SYNCED` rows) being restored on the new toolkit version: works fine — restore script just sees no `CLOUD-SYNCED` rows.
- New classification (with `CLOUD-SYNCED` rows) being restored by an older toolkit version: the existing restore loop iterates `$FILES_SRC/*/`, so data restoration is unaffected by the new tag — old `restore.sh` just ignores the advisory block.
- `MBR_RESTORE_CLOUD` env var: defaults to unset, behavior is "skip cloud" out of the box. Anything other than `=1` is also "skip" (explicit equality check).

## Open Items

None. All design questions resolved during brainstorming.
