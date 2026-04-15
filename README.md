# Mac Backup & Restore

A clean migration toolkit for moving to a new Mac without Migration Assistant. Instead of cloning your old system and carrying over years of accumulated cruft, this toolkit captures everything that matters, then helps you set up a fresh, well-organized machine.

## Table of Contents

- [Philosophy](#philosophy)
- [Architecture](#architecture)
- [Repo Structure](#repo-structure)
- [Backup on the External Drive](#backup-on-the-external-drive)
- [New Mac Directory Layout](#new-mac-directory-layout)
- [Design Decisions and Best Practices](#design-decisions-and-best-practices)
- [How to Use: Backup](#how-to-use-backup)
- [How to Use: Restore](#how-to-use-restore)
- [How to Use: Verify](#how-to-use-verify)
- [Security](#security)
- [Customization](#customization)

---

## Philosophy

Migration Assistant copies everything — every preference, every daemon, every stale cache and orphaned config file accumulated over years. That works, but it defeats the purpose of getting a new machine. This toolkit takes the opposite approach: capture only what you need, then rebuild from scratch. You get a clean system with an organized layout, and you know exactly what's on it.

The design follows three principles: be declarative where possible (Brewfile over a list of manual installs), be interactive where judgment is needed (prompting before each personal folder), and be verifiable (a dedicated script to confirm everything landed correctly).

---

## Architecture

The toolkit is three bash scripts plus a shared library, designed to be run in sequence across two machines connected by an external drive.

```
Old Mac                    External Drive                  New Mac
───────                    ──────────────                  ───────
backup.sh ──────────────►  /mac-backup/<timestamp>/  ────► restore.sh
                           ├── software-inventory/         verify.sh
                           ├── config/
                           ├── app-settings/
                           ├── projects/
                           ├── files/
                           └── system/
```

The flow is intentionally one-directional. Backup writes to the drive, restore reads from the drive. There is no bidirectional sync, no daemon, no state file. Each backup is a timestamped snapshot, so you can run backup multiple times and keep older snapshots as insurance.

All three scripts source a shared helper library (`scripts/lib/helpers.sh`) that provides colored output, confirmation prompts, and a `has` command-detection utility. This keeps the main scripts focused on logic rather than formatting boilerplate.

Every destructive or significant step uses the `confirm` function, which requires explicit "y" input. Nothing runs silently.

---

## Repo Structure

```
mac-backup-restore/
├── README.md
├── LICENSE
├── .gitignore
└── scripts/
    ├── backup.sh           ← run on the old Mac
    ├── restore.sh          ← run on the new Mac
    ├── verify.sh           ← run after restore to confirm success
    └── lib/
        └── helpers.sh      ← shared functions (logging, prompts, colors)
```

The scripts live in a `scripts/` directory rather than the repo root to keep the top level clean and to clearly separate documentation from executable code. The shared library lives in `scripts/lib/` following the Unix convention of keeping library code in a `lib/` subdirectory adjacent to the scripts that use it.

---

## Backup on the External Drive

When you run backup.sh, it creates a timestamped directory on the external drive with this layout:

```
/Volumes/YourDrive/mac-backup/20260415_120000/
├── software-inventory/
│   ├── Brewfile                 ← declarative Homebrew manifest (taps, formulae, casks, MAS apps)
│   ├── applications.txt         ← ls /Applications
│   ├── user-applications.txt    ← ls ~/Applications
│   ├── brew-formulae.txt        ← all installed Homebrew formulae
│   ├── brew-casks.txt           ← all installed Homebrew casks
│   ├── brew-taps.txt            ← active Homebrew taps
│   ├── mac-app-store.txt        ← Mac App Store installs (via mas)
│   ├── npm-globals.txt          ← globally installed npm packages
│   ├── pip3-packages.txt        ← pip3 freeze output
│   ├── pipx-packages.json       ← pipx-installed CLI tools
│   ├── cargo-packages.txt       ← Rust crates installed via cargo
│   ├── ruby-gems.txt            ← locally installed Ruby gems
│   ├── go-binaries.txt          ← compiled Go binaries
│   ├── vscode-extensions.txt    ← VS Code extension IDs
│   └── cursor-extensions.txt    ← Cursor extension IDs
├── config/
│   ├── dotfiles/                ← shell configs, git config, editor configs, version managers
│   ├── ssh/                     ← SSH keys, config, known_hosts
│   ├── gnupg/                   ← exported GPG secret keys and trust database
│   ├── dot-config/              ← full ~/.config directory (caches excluded)
│   ├── .aws/                    ← AWS CLI config and credentials
│   ├── .kube/                   ← Kubernetes config
│   └── .docker/                 ← Docker config
├── app-settings/
│   ├── vscode/                  ← settings.json, keybindings.json, snippets
│   ├── cursor/                  ← settings.json, keybindings.json, snippets
│   ├── iterm2/                  ← com.googlecode.iterm2.plist
│   └── macos-defaults-full.txt  ← complete macOS defaults database
├── projects/
│   ├── _project-list.txt        ← manifest of all discovered project paths
│   └── <original-path>/         ← project files, mirroring home directory structure
│       └── <project-name>/          (node_modules, .venv, build dirs excluded)
├── files/
│   ├── Documents/
│   ├── Desktop/
│   ├── Downloads/
│   ├── Pictures/
│   ├── Music/
│   └── Movies/
└── system/
    ├── crontab.txt              ← user crontab
    └── LaunchAgents/            ← ~/Library/LaunchAgents plist files
```

The separation into six top-level directories on the backup drive mirrors the six logical phases of the backup script. Each directory is self-contained and independently useful — you could restore just your dotfiles or just your Brewfile without touching anything else.

---

## New Mac Directory Layout

The restore script creates an opinionated but standards-based directory layout on the new Mac. This is the most important design decision in the toolkit, so here's the rationale for each choice.

```
~/
├── Developer/                 ← all code lives here
│   ├── personal/              ← side projects, personal tools, learning repos
│   ├── work/                  ← employer or client projects
│   ├── oss/                   ← open source contributions and forks
│   └── experiments/           ← throwaway code, spikes, one-off tests
├── Documents/                 ← synced to iCloud Desktop & Documents
├── Desktop/                   ← kept intentionally clean
├── Downloads/                 ← transient; cleared regularly
├── Pictures/
│   └── Screenshots/           ← macOS screenshot destination (via defaults write)
├── Music/
├── Movies/
├── .config/                   ← XDG Base Directory configs
├── .ssh/                      ← SSH keys (700 permissions)
└── .gnupg/                    ← GPG keyring
```

**Why ~/Developer/ instead of ~/Projects, ~/code, ~/repos, or ~/src:**
Apple's own Xcode uses `~/Developer` as its default location. It's the closest thing macOS has to an official convention for code. Using a single root for all code means your shell aliases, editor configs, and backup scripts only need to know about one path. The context-based subdirectories (`personal/`, `work/`, `oss/`, `experiments/`) solve the real organizational problem, which is not where code lives but how to mentally categorize it.

**Why context-based subdirectories instead of language-based or tool-based:**
Organizing by language (`~/Developer/python/`, `~/Developer/rust/`) breaks down the moment you have a project that uses multiple languages. Organizing by tool (`~/Developer/vscode-projects/`) couples your file system to your editor. Context-based organization (personal vs. work vs. open source) reflects how you actually think about and switch between projects. A project's context almost never changes, whereas its language or tooling might.

**Why ~/Pictures/Screenshots/ instead of ~/Desktop:**
The macOS default of dropping screenshots on the Desktop leads to visual clutter. Redirecting them to a dedicated folder keeps the Desktop clean while still making screenshots easy to find. The restore script configures this via `defaults write com.apple.screencapture location`.

**Why .config/ for XDG-style configs:**
The XDG Base Directory Specification (freedesktop.org) defines `~/.config` as the standard location for user configuration files. Most modern CLI tools (starship, lazygit, neovim, alacritty, etc.) already look here by default. Centralizing configs in `~/.config` instead of scattering dozens of dotfiles across `~/` keeps the home directory clean and makes configs easier to back up.

---

## Design Decisions and Best Practices

**Declarative package management via Brewfile.** The Brewfile is the single most important artifact in the backup. It's a declarative manifest that captures your entire Homebrew setup — taps, formulae, casks, and Mac App Store apps — in one file. On the new Mac, `brew bundle` reads it and installs everything. This is idempotent: you can run it multiple times safely. It's also diffable and version-controllable, so you can track exactly what changed between backups.

**rsync over cp for file transfers.** All file copies use `rsync -a` rather than `cp -r`. Rsync preserves permissions, timestamps, symlinks, and extended attributes (the `-a` archive flag). It also handles partial transfers gracefully — if a copy is interrupted, you can rerun it and it picks up where it left off. For project backups, rsync's `--exclude` flag is used to skip generated artifacts (node_modules, .venv, build/, target/, etc.), which dramatically reduces backup size and time.

**Interactive prompts at every stage.** Both scripts use `confirm` prompts before each major action. This is deliberately not a "run and walk away" tool. The prompts exist because backup and restore involve judgment calls — you might not want to restore your pip packages globally, you might want to skip your 40GB Movies folder, you might want to review your macOS defaults before applying them. The script gives you control at every step.

**Timestamped backups for safety.** Each backup creates a new timestamped directory rather than overwriting a fixed location. This means you can run backup.sh multiple times as you prepare for migration — once a week before your new Mac arrives, then one final time the day of. Older backups remain available as insurance.

**Sensitive material flagged explicitly.** The scripts use a distinct `sensitive` log marker (a lock icon) whenever they handle SSH keys, GPG keys, or cloud credentials. This is a deliberate UX choice: you should always know when secret material is being written to or read from the backup drive.

**Project discovery by .git directory.** Rather than requiring you to maintain a list of project paths, the backup script scans common code directories (~/Projects, ~/Developer, ~/code, ~/repos, ~/src, ~/workspace, ~/dev, ~/work, ~/Sites, ~/Documents, ~/Desktop) up to 4 levels deep looking for `.git` directories. This catches everything without needing configuration. The depth limit of 4 prevents the scan from going into node_modules or other deep nested structures.

**Smart exclusions for project backups.** Projects are backed up without their generated artifacts. The exclusion list covers the major ecosystems: node_modules (JavaScript), .venv/venv (Python), target (Rust/Java), build/dist (general), .next/.nuxt (frameworks), Pods/DerivedData (iOS), .gradle (JVM), .cache, .idea, .DS_Store, and compiled object files. This often reduces a project from gigabytes to megabytes.

**SSH permission hardening on restore.** When restoring SSH keys, the script explicitly sets permissions: 700 on the .ssh directory, 600 on private keys, 644 on public keys and known_hosts. SSH is strict about permissions — if they're wrong, it silently refuses to use the keys. The restore script gets this right automatically so you don't have to debug authentication failures.

**Dotfile safety net on restore.** When restoring dotfiles, the script checks if a file already exists at the destination and creates a `.pre-restore` backup before overwriting. This means if the new Mac's default .zshrc had something you wanted to keep, it's still available as `.zshrc.pre-restore`.

**macOS defaults as code.** The restore script applies a curated set of macOS preferences via `defaults write` commands. This includes showing file extensions in Finder, enabling tap-to-click, setting fast key repeat, auto-hiding the Dock, and redirecting screenshots. These are all reversible through System Settings, and the script prompts before applying them. The full macOS defaults database is also captured in the backup as `macos-defaults-full.txt` for reference, though restoring the entire database wholesale would be fragile across macOS versions.

**set -euo pipefail in every script.** All scripts use bash strict mode: `-e` exits on any error, `-u` treats unset variables as errors, and `-o pipefail` catches failures in piped commands. This prevents silent failures — if something goes wrong, you'll know immediately rather than ending up with a half-completed backup.

**Parallel VS Code extension installation.** The restore script installs VS Code extensions in parallel (backgrounding each `code --install-extension` call and waiting for all to finish). Extensions are independent of each other, so parallel installation is safe and significantly faster than sequential.

---

## How to Use: Backup

Run this on your current Mac before migrating.

### Prerequisites

The only hard requirement is bash (which ships with macOS). For a complete backup, you'll also want Homebrew installed (`brew` commands are skipped gracefully if it's not present) and optionally `mas` (`brew install mas`) to capture Mac App Store apps.

### Running

```bash
git clone https://github.com/<you>/mac-backup-restore.git
cd mac-backup-restore
./scripts/backup.sh /Volumes/YourDrive
```

If you run it without arguments, it prints available volumes to help you find your drive's mount point.

### What happens

The script runs through six phases in order:

**Phase 1 — Software Inventory.** Generates a Brewfile using `brew bundle dump`, which captures every tap, formula, cask, and Mac App Store app in a single declarative file. Also captures package lists from npm, pip3, pipx, cargo, gem, and Go, plus extension lists from VS Code and Cursor. Each tool is detected with `command -v` before being invoked, so missing tools are skipped with a warning rather than an error.

**Phase 2 — Dotfiles & Config.** Copies a predefined list of dotfiles from your home directory. The list covers shell configs (zsh, bash), git, vim, tmux, package manager configs (npm, yarn, gem), editor configs, and version manager files (asdf, pyenv, nvm, rbenv). It also backs up your full `~/.ssh` directory (keys, config, known_hosts), exports GPG secret keys and trust database via `gpg --export-secret-keys --armor`, copies the entire `~/.config` directory (excluding caches and logs), and grabs AWS, Kubernetes, and Docker configs.

**Phase 3 — Application Settings.** Copies settings files from VS Code, Cursor, and iTerm2 from their macOS-specific `Library/Application Support` paths. Also exports the complete macOS defaults database via `defaults read`, which captures every preference you've ever set through System Settings or the command line.

**Phase 4 — Project Discovery.** Scans 11 common code directories up to 4 levels deep for `.git` directories. Deduplicates and displays the list with line numbers. Prompts for confirmation before backing up. Uses rsync with 16 exclusion patterns to skip generated artifacts. Each project is stored under its original path relative to `~`, preserving the directory structure for reference.

**Phase 5 — Personal Files.** Iterates through Documents, Desktop, Downloads, Pictures, Music, and Movies. For each folder, shows its size and asks whether to include it. Uses rsync with `--progress` so you can see transfer status for large folders.

**Phase 6 — System Config.** Captures the user crontab (if any) and copies Launch Agents from `~/Library/LaunchAgents`.

After all phases, it prints a summary showing total backup size and a breakdown by directory.

---

## How to Use: Restore

Run this on your new Mac after completing the initial macOS setup wizard (skip Migration Assistant).

### Prerequisites

You need Xcode command line tools for git:

```bash
xcode-select --install
```

Then clone this repo or copy it from the backup drive.

### Running

```bash
cd mac-backup-restore
./scripts/restore.sh /Volumes/YourDrive/mac-backup/20260415_120000
```

If you point it at the drive root instead of a specific timestamp, it lists available backups.

### What happens

The script runs through eight steps:

**Step 0 — macOS Preferences.** Prompts to apply a curated set of defaults: Finder improvements (show extensions, path bar, status bar, search current folder), Dock settings (auto-hide, 48px icons, don't auto-rearrange Spaces), keyboard (fast key repeat with KeyRepeat=2 and InitialKeyRepeat=15), trackpad (tap to click), screenshot location (~/Pictures/Screenshots), disabling .DS_Store on network and USB volumes, and showing the ~/Library folder. Restarts Finder and Dock to apply changes immediately.

**Step 1 — Directory Structure.** Creates the `~/Developer/` tree with `personal/`, `work/`, `oss/`, and `experiments/` subdirectories, plus `~/Pictures/Screenshots/`. This runs without prompting because it's non-destructive (mkdir -p on existing directories is a no-op).

**Step 2 — Homebrew.** Installs Homebrew if not present, including the PATH setup for Apple Silicon Macs (`/opt/homebrew/bin/brew`). Then reads the Brewfile from the backup, shows a category breakdown (formulae, casks, taps, MAS apps), and prompts to install. Uses `brew bundle --no-lock` to avoid creating a Brewfile.lock in the backup directory.

**Step 3 — Dotfiles & Config.** Lists all backed-up dotfiles and prompts to restore. Creates `.pre-restore` backups of any existing files before overwriting. Restores SSH keys with hardened permissions (700 on directory, 600 on private keys, 644 on public keys and config). Imports GPG keys via `gpg --import`. Restores `~/.config`, and restores cloud configs (AWS, Kubernetes, Docker) with individual prompts for each.

**Step 4 — Application Settings.** Restores VS Code and Cursor settings to their `Library/Application Support` paths. For VS Code, also installs all extensions from the backed-up extension list in parallel. Restores iTerm2 preferences plist.

**Step 5 — Projects.** Finds all git repos in the backup and restores them into `~/Developer/personal/` by default, flattening the original path structure. If a project already exists at the destination, it's skipped with a warning. After restore, it reminds you to sort projects into `work/` or `oss/` as appropriate.

**Step 6 — Personal Files.** Prompts for each backed-up personal folder (Documents, Desktop, etc.) with size information, then restores via rsync.

**Step 7 — System Config.** Shows and prompts to restore the crontab and Launch Agents.

**Step 8 — Language Packages.** Reinstalls npm global packages by parsing the backed-up npm list output. For pip packages, warns about global installs and suggests virtualenvs before prompting. This step is intentionally last because language packages depend on their runtimes being installed first (via Homebrew in Step 2).

Finishes with a summary of recommended manual next steps: iCloud sign-in, browser sync, SSH key testing, and project reorganization.

---

## How to Use: Verify

Run this on the new Mac after restore.sh completes.

```bash
./scripts/verify.sh
```

This script runs a checklist of pass/fail/skip tests across six categories: core tools (Homebrew, Git, git config), shell (zsh default, .zshrc exists), SSH (directory permissions, key permissions, GitHub connectivity), GPG (key presence), development tools (node, npm, python3, pip3, code, cursor with version numbers), directory structure (~/Developer tree, Screenshots folder), and cloud configs (AWS, Kubernetes, Docker).

Each check is either a pass (green checkmark), fail (red X), or skip (blue info, for tools that weren't in the backup). At the end it prints a scorecard. Any failures indicate something that needs manual attention — the most common being GitHub SSH authentication, which requires adding your SSH public key to GitHub after restoring it to the new machine.

---

## Security

The backup contains sensitive material: SSH private keys, GPG secret keys, AWS credentials, Kubernetes configs, and potentially other secrets in dotfiles. Treat the backup drive accordingly.

Recommended precautions: encrypt the external drive using Disk Utility (Erase with APFS Encrypted format), don't leave the drive unattended during migration, and securely erase the backup after you've verified the new Mac is working. The scripts flag every sensitive operation with a lock icon in the output so you always know when secrets are being handled.

The backup does not capture passwords from Keychain, browser saved passwords, or system-level credentials. Those sync through iCloud Keychain or your browser's own sync mechanism.

---

## Customization

**Adding dotfiles:** Edit the `DOTFILES` array in `scripts/backup.sh`. Any file or directory in `~` can be added.

**Adding project search locations:** Edit the `SEARCH_DIRS` array in `scripts/backup.sh`.

**Adding app settings:** Follow the existing pattern in Phase 3 of backup.sh — check if the app's config directory exists, create a subdirectory in the backup, and copy the relevant files.

**Changing the Developer/ layout:** Edit Step 1 in `scripts/restore.sh` to create different subdirectories. Update Step 5 to change where projects are restored to.

**Skipping sections:** Every section prompts for confirmation. Answer "n" to skip anything you don't need.

---

## License

MIT
