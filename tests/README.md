# Tests

Bats-core tests for the mac-backup-restore toolkit.

## Requirements

```bash
brew install bats-core
```

Tests are written to run under stock macOS `/bin/bash` (3.2.57). This is
deliberate — the toolkit promises to work on stock macOS bash, so the test
harness must validate that promise.

## Running

From the project root:

```bash
# All tests
bats tests/

# Just unit tests (fast, no fake env)
bats tests/unit/

# Just integration tests (slower, set up fake $HOME and external drive)
bats tests/integration/

# A single file
bats tests/unit/test_helpers_lib.bats
```

## Layout

```
tests/
├── README.md             — this file
├── test_helper.bash      — shared fixtures + command mocking utilities
├── mocks/                — generated PATH stubs (created at test time)
├── fixtures/             — static test data (synthetic dotfiles, plists, etc.)
├── unit/
│   ├── test_helpers_lib.bats   — scripts/lib/helpers.sh (lookup, has, confirm)
│   └── test_configs.bats       — all config/*.sh source cleanly under bash 3.2
└── integration/
    ├── test_backup.bats        — scripts/backup.sh against a synthetic $HOME
    ├── test_restore.bats       — scripts/restore.sh against a synthetic backup
    └── test_verify.bats        — scripts/verify.sh sanity checks
```

## Test isolation

Every integration test creates a temp dir under `$TMPDIR` containing a fake
`$HOME` and a fake external drive. The real `$HOME` and `/Volumes/` are never
touched. Tests that need to run external commands (`brew`, `mas`, `defaults`)
mock them via PATH-prepended stubs in `tests/mocks/`.

See `test_helper.bash` for the helper functions: `setup_test_env`,
`teardown_test_env`, `mock_command`, `mock_command_failing`,
`mock_command_script`, `mock_was_called`, `mock_calls`, `make_fake_app`,
`make_fake_license_plist`.

## Adding tests

Each `.bats` file should:

1. `load '../test_helper'` (or `'test_helper'` for files in `tests/`)
2. Define `setup() { setup_test_env; }` and `teardown() { teardown_test_env; }`
3. Use `@test "description" { ... }` blocks
4. Assert with `[ ... ]` or the bats-provided `assert_*` helpers (if you load
   `bats-assert`)

## What's covered

| Area | Unit | Integration |
|---|---|---|
| `scripts/lib/helpers.sh` | yes | — |
| `config/*.sh` sourcing | yes | — |
| `scripts/backup.sh` | — | yes |
| `scripts/restore.sh` | — | yes |
| `scripts/verify.sh` | — | yes |
