# Mac Backup & Restore

A clean migration toolkit for moving to a new Mac without Migration Assistant. Instead of cloning your old system and carrying over years of accumulated cruft, this toolkit captures everything that matters, then helps you set up a fresh, well-organized machine.

## Table of Contents

- [Philosophy](#philosophy)
- [Migration Patterns](#migration-patterns)
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

The design follows four principles: assume chaos on the old Mac (scan everywhere, classify what you find), be declarative where possible (Brewfile over a list of manual installs), normalize on restore (install via Homebrew even if the original was a .dmg), and be verifiable (a dedicated script to confirm everything landed correctly).

---

## Migration Patterns

Not all software migrates the same way. Installing the binary is only the first step — every app also needs its data, configuration, and license activation to be fully functional. This toolkit recognizes five distinct migration patterns and handles each one differently.

**Pattern 1 — Sign In.** Cloud-synced apps that restore everything via account login. You install the binary, sign into your account, and all data, settings, and license state come back automatically. The backup only needs to note that these exist; the restore just installs them and reminds you to sign in. Examples: 1Password, Microsoft 365 (Word, Excel, etc.), OneDrive, ChatGPT, Claude, Perplexity, WhatsApp.

**Pattern 2 — Restore Config.** Apps that are functional after install but lose your workflow without their settings files. The license is either free, open-source, or handled by account login — the real value is in the config files, keybindings, snippets, and themes. The backup copies these files; the restore puts them back in the right locations. Examples: VS Code, Cursor, Ghostty, iTerm2, Warp, PyCharm, Zed, shell configs (.zshrc, .gitconfig).

**Pattern 3 — Restore License.** Apps that store a serial number or license key in a macOS preference plist. If you copy the right plist file to `~/Library/Preferences/` on the new Mac, the app activates without prompting for a key. If you don't have the plist, you need to find and re-enter the original license key. The backup captures these plists explicitly. Examples: BBEdit, Bartender, iStat Menus, TG Pro, Gemini 2, Shottr, TextSniper, CrossOver.

**Pattern 4 — Re-download Content.** Apps that manage large content which must be re-acquired after install. The app binary is easy to install, but the real payload — games, container images, Python environments — needs to be pulled down again (or restored from a backup of the content itself). Examples: Steam (re-download games after login), CrossOver bottles (restore from backup or reinstall Windows games), Docker (pull images), Anaconda (recreate environments from exported YAML).

**Pattern 5 — Sync Extensions.** Browser and editor extensions that live inside a host app. Most sync automatically when you sign into the host app's account (Chrome extensions sync with your Google account, VS Code can sync via GitHub). When sync isn't available, the backup captures extension lists so you can reinstall from a reference. VS Code and Cursor extensions can be scripted via `--install-extension`; browser extensions and JetBrains plugins require manual reinstall from the list.

The backup script generates a `migration-manifest.txt` that classifies every installed app into one of these patterns, so you know exactly what each app needs on the new Mac before you start the restore.

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
│   ├── Brewfile.addon           ← apps that WERE manual but CAN become Brew casks on the new Mac
│   ├── install-sources.txt      ← classification of every app (brew-cask, mas, manual, bundled)
│   ├── applications.txt         ← ls /Applications
│   ├── user-applications.txt    ← ls ~/Applications
│   ├── usr-local-bin.txt        ← /usr/local/bin inventory (standalone installers, Docker CLIs)
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
│   ├── cursor-extensions.txt    ← Cursor extension IDs
│   ├── conda-environments.txt   ← list of Anaconda environments
│   ├── conda-envs/              ← exported conda environment YAML files
│   ├── browser-extensions/      ← browser extension inventories
│   │   ├── chrome-extensions.txt    ← Chrome extensions (ID, name, version)
│   │   ├── arc-extensions.txt       ← Arc browser extensions
│   │   ├── opera-extensions.txt     ← Opera extensions
│   │   └── safari-extensions.txt    ← Safari extensions
│   ├── app-plugins/             ← application plugin inventories
│   │   ├── pycharm-plugins.txt      ← PyCharm user-installed plugins
│   │   ├── <IDE>-plugins.txt        ← other JetBrains IDE plugins
│   │   └── obsidian/
│   │       └── <vault>-plugins.txt  ← community plugins per vault
│   └── steam/
│       ├── installed-games.txt  ← Steam games installed on this Mac
│       ├── crossover-games.txt  ← Windows games running via CrossOver
│       └── loginusers.vdf       ← Steam account info
├── config/
│   ├── dotfiles/                ← ALL dotfiles from ~ (scanned, not just hardcoded list)
│   │   └── _manifest.txt        ← what was found and copied
│   ├── ssh/                     ← SSH keys, config, known_hosts
│   ├── gnupg/                   ← exported GPG secret keys and trust database
│   ├── dot-config/              ← full ~/.config directory (caches excluded)
│   ├── .aws/                    ← AWS CLI config and credentials
│   ├── .kube/                   ← Kubernetes config
│   └── .docker/                 ← Docker config
├── app-settings/
│   ├── vscode/                  ← settings.json, keybindings.json, snippets
│   ├── cursor/                  ← settings.json, keybindings.json, snippets
│   ├── ghostty/                 ← Ghostty terminal config
│   ├── iterm2/                  ← com.googlecode.iterm2.plist
│   ├── warp/                    ← Warp terminal settings
│   ├── pycharm/                 ← PyCharm code styles, keymaps, options
│   ├── obsidian/                ← Obsidian vault config
│   └── macos-defaults-full.txt  ← complete macOS defaults database
├── licenses/
│   └── plists/                  ← preference plists containing license keys/serials
│       ├── com.barebones.bbedit.plist
│       ├── com.surteesstudios.Bartender.plist
│       └── ...                      (BBEdit, Bartender, iStat, TG Pro, Gemini, etc.)
├── migration-manifest.txt       ← every app classified by migration pattern
├── crossover/                   ← CrossOver bottles (optional, can be very large)
├── projects/
│   ├── _project-list.txt        ← manifest of all discovered project paths
│   ├── _orphan-code-files.txt   ← code files found outside any git repo
│   └── <original-path>/         ← project files, mirroring home directory structure
│       └── <project-name>/          (node_modules, .venv, build dirs excluded)
├── files/
│   ├── _data-classification.txt ← every data directory classified by type
│   ├── Screenshots/             ← organized from Desktop clutter into YYYY/MM/
│   │   ├── 2025/
│   │   │   ├── 01/
│   │   │   ├── 06/
│   │   │   └── ...
│   │   └── unsorted/            ← screenshots with non-standard filenames
│   ├── scattered-credentials/   ← secrets found outside ~/.ssh (backup codes, API keys, .pem files)
│   ├── auth-tokens/             ← app auth tokens (GitHub CLI, Sourcery, etc.)
│   │   ├── gh/hosts.yml
│   │   └── sourcery/auth.yaml
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

The key addition compared to a typical backup tool is the `install-sources.txt` classification file and `Brewfile.addon`. The backup scans every app in /Applications, figures out how it was originally installed (Homebrew cask, Mac App Store, manual download, macOS-bundled), and for manual installs, checks if a Homebrew cask exists. The addon Brewfile contains cask entries for all those apps, so the restore can install them cleanly via Homebrew even though they were originally .dmg downloads.

The `_data-classification.txt` file in `files/` categorizes every data directory by type: cloud-synced (will re-sync via iCloud), documents (personal and work files), archival (large old data like Zoom recordings), app-data (created by specific apps, only useful if the app is installed), media (photos, videos), and stale (multi-machine sync artifacts from old devices). The restore script uses this classification to guide decisions — stale data is flagged for skipping, archival data is flagged for cloud/external storage, and app-data is flagged as conditional on the app being installed.

Each directory is self-contained and independently useful — you could restore just your dotfiles or just your Brewfile without touching anything else.

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
│   ├── Work/                  ← employer/client documents
│   ├── Education/             ← courses, study materials
│   └── ...                    ← personal documents by topic
├── Desktop/                   ← kept intentionally clean (no screenshots, no loose photos)
├── Downloads/                 ← transient; cleared regularly
├── Pictures/
│   ├── Screenshots/           ← macOS screenshot destination (via defaults write)
│   └── Imported/              ← loose photos rescued from old Desktop
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

**Where different data types end up:**

Not all data is equal, and the restore handles each type differently. Irreplaceable personal documents (contracts, certificates, financial records) go to `~/Documents/` and are protected by iCloud sync plus the backup as insurance. Work documents land in `~/Documents/Work/`. Code projects are consolidated into `~/Developer/` by context. Screenshots go to `~/Pictures/Screenshots/` organized by year and month. Loose photos found on the old Desktop get moved to `~/Pictures/Imported/` instead of cluttering the new Desktop.

Multi-machine sync artifacts (those "Documents - Mac mini" folders from iCloud) are flagged as stale and recommended for skipping — they're leftovers from previous devices that shouldn't follow you to the new machine. Large archival data like Zoom recordings (potentially tens of gigabytes of meeting videos from years past) is flagged for cloud storage or an external drive rather than consuming SSD space on a fresh machine. App-generated data (DaVinci Resolve projects, Snagit captures, Hook links) is restored conditionally — only worth copying if the app is also being installed.

Scattered credentials (backup codes in Documents, API key files on the Desktop) are detected and restored first, since they're the easiest to lose and the hardest to replace. Auth tokens for CLI tools (GitHub CLI, Sourcery) are restored to `~/.config/` so your development tools work immediately.

Cloud-native data (anything in iCloud, OneDrive, 1Password) will re-sync when you sign into the corresponding account. The backup captures it as insurance, but the primary migration path for cloud data is the account sign-in, not the backup drive.

---

## Design Decisions and Best Practices

**Declarative package management via Brewfile.** The Brewfile is the single most important artifact in the backup. It's a declarative manifest that captures your entire Homebrew setup — taps, formulae, casks, and Mac App Store apps — in one file. On the new Mac, `brew bundle` reads it and installs everything. This is idempotent: you can run it multiple times safely. It's also diffable and version-controllable, so you can track exactly what changed between backups.

**rsync over cp for file transfers.** All file copies use `rsync -a` rather than `cp -r`. Rsync preserves permissions, timestamps, symlinks, and extended attributes (the `-a` archive flag). It also handles partial transfers gracefully — if a copy is interrupted, you can rerun it and it picks up where it left off. For project backups, rsync's `--exclude` flag is used to skip generated artifacts (node_modules, .venv, build/, target/, etc.), which dramatically reduces backup size and time.

**Interactive prompts at every stage.** Both scripts use `confirm` prompts before each major action. This is deliberately not a "run and walk away" tool. The prompts exist because backup and restore involve judgment calls — you might not want to restore your pip packages globally, you might want to skip your 40GB Movies folder, you might want to review your macOS defaults before applying them. The script gives you control at every step.

**Timestamped backups for safety.** Each backup creates a new timestamped directory rather than overwriting a fixed location. This means you can run backup.sh multiple times as you prepare for migration — once a week before your new Mac arrives, then one final time the day of. Older backups remain available as insurance.

**Sensitive material flagged explicitly.** The scripts use a distinct `sensitive` log marker (a lock icon) whenever they handle SSH keys, GPG keys, or cloud credentials. This is a deliberate UX choice: you should always know when secret material is being written to or read from the backup drive.

**Migration manifest and pattern classification.** The backup generates a `migration-manifest.txt` that classifies every installed app into one of five patterns: sign-in (cloud-synced), config restore, license-key restore, content re-download, or extension sync. This means you never have to guess what an app needs on the new Mac — the manifest tells you. The restore script's final summary is organized around these patterns too, so the post-restore checklist is practical rather than a generic list of "stuff to do."

**License plist preservation.** Many macOS apps store their license or serial number in a preference plist under `~/Library/Preferences/`. The backup captures these explicitly, and the restore copies them back before you launch the apps. This avoids the common problem of having to dig through old emails looking for license keys. The toolkit maintains a map of known license plists (`LICENSE_PLISTS` in backup.sh) that you can extend for your own apps.

**Organic-to-clean migration.** The backup script assumes your current Mac is an adhoc setup — apps installed through a mix of methods, code scattered across multiple directories, configs accumulated over years. It scans everywhere and classifies what it finds. The restore script then normalizes everything: Homebrew for all apps, ~/Developer/ for all code, proper permissions on all keys. You go from organic to organized without losing anything.

**Brew-first install strategy.** The backup classifies every app in /Applications by install source and generates a Brewfile.addon for apps that were manually installed but have Homebrew casks available. On the new Mac, these get installed through Homebrew instead of manual downloads. This means `brew upgrade` keeps everything updated going forward — no more hunting for .dmg update dialogs.

**Project discovery by .git directory.** Rather than requiring you to maintain a list of project paths, the backup script scans the entire home directory up to 5 levels deep looking for `.git` directories, excluding Library, Trash, and dependency directories. This catches everything regardless of where you happened to clone it. It also scans for orphan code files (scripts, notebooks) that aren't inside any git repo.

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

The script assumes an organic, adhoc setup — software installed through a mix of Homebrew, Mac App Store, direct downloads, standalone .pkg installers, JetBrains Toolbox, Docker Desktop, and CrossOver. It scans everything and classifies what it finds.

**Phase 1 — Software Inventory.** Generates a Brewfile via `brew bundle dump`. Lists all apps in /Applications, then classifies each one by install source (Homebrew cask, Mac App Store, manual download, macOS-bundled) using a built-in mapping table. For manual installs, it checks if a Homebrew cask exists and generates a `Brewfile.addon` — this is what lets the restore convert manual installs to Homebrew. Also captures /usr/local/bin (standalone tools like Docker CLIs), package lists from npm, pip3, pipx, cargo, gem, Go, and extension lists from VS Code and Cursor. Scans browser extensions across Chrome, Arc, Opera, and Safari by parsing Chromium manifest.json files to extract human-readable names and versions. Captures application plugins including PyCharm/JetBrains user-installed plugins and Obsidian community plugins per vault. Exports Anaconda/conda environments as YAML files for recreation on the new Mac. Scans Steam for installed games (parsing appmanifest .acf files) and CrossOver game launchers (parsing Desktop .app bundles that call `steam://run/`).

**Phase 2 — Dotfiles & Config.** Instead of only copying a hardcoded list, it first grabs known priority dotfiles, then scans `~/` for any additional dotfiles it didn't predict. This catches organic configs that accumulate over time. Also backs up SSH, GPG, ~/.config, and cloud credentials (AWS, Kubernetes, Docker).

**Phase 3 — Application Settings & Licenses.** Copies settings from VS Code, Cursor, Ghostty, iTerm2, Warp, PyCharm (via JetBrains config directories), and Obsidian. Exports the full macOS defaults database. Backs up license plists from `~/Library/Preferences/` for apps that store serial numbers or activation data in their preferences (BBEdit, Bartender, iStat Menus, TG Pro, Gemini 2, Shottr, TextSniper, CrossOver). Generates a migration manifest that classifies every installed app by migration pattern (sign-in, config, license-key, re-download, extension). Optionally backs up CrossOver bottles (which can be tens of gigabytes if you have Windows games installed).

**Phase 4 — Project Discovery.** Scans the entire home directory up to 5 levels deep for `.git` directories, excluding Library, Trash, node_modules, anaconda3, and virtual environments. Also scans for orphan code files (`.py`, `.ipynb`, `.js`, `.sh`, etc.) that aren't inside any git repo and logs them separately.

**Phase 5 — Personal Files.** This is the most nuanced phase. Rather than blindly copying everything, it classifies data first. Warns about iCloud offloading (files may be stubs if Desktop & Documents sync is enabled). Sweeps screenshots from Desktop, Documents, and Downloads into organized `Screenshots/YYYY/MM/` folders. Scans for scattered credentials and secrets (backup codes, API keys, .pem files found outside ~/.ssh). Captures auth tokens from `~/.config/` (GitHub CLI, Sourcery, etc.). Analyzes the Documents folder to produce a `_data-classification.txt` that flags multi-machine sync artifacts (old "Documents - Mac mini" folders from iCloud), archival data (Zoom recordings), and app-generated data (DaVinci Resolve projects, Snagit captures). Detects loose photos on the Desktop for relocation to ~/Pictures/. Then iterates through Documents, Desktop, Downloads, Pictures, Music, and Movies with size and confirmation prompts.

**Phase 6 — System Config.** Captures crontab and Launch Agents.

After all phases, it prints a summary with total size, breakdown by directory, and pointers to the key files the restore script will use.

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

The restore strategy is: install everything possible through Homebrew (even apps that were manual .dmg installs on the old Mac), organize files into a clean layout, and flag anything that needs manual attention.

**Step 0 — macOS Preferences.** Applies a curated set of defaults: Finder improvements, Dock auto-hide, fast key repeat, tap-to-click, screenshots to ~/Pictures/Screenshots, disable .DS_Store on network volumes, and show ~/Library. Restarts Finder and Dock to apply immediately.

**Step 1 — Directory Structure.** Creates the `~/Developer/` tree with `personal/`, `work/`, `oss/`, and `experiments/`. This is the "clean slate" layout that replaces the organic scatter of `~/code`, `~/projects`, `~/repos`, etc.

**Step 2 — Homebrew.** Installs Homebrew if needed (including Apple Silicon PATH setup persisted to ~/.zprofile). Runs `brew bundle` on the original Brewfile first, then on the Brewfile.addon to convert previously manual installs to Homebrew casks. This is the key normalization step — apps that were .dmg downloads on the old Mac become Homebrew-managed on the new one, getting automatic updates via `brew upgrade`.

**Step 3 — Mac App Store.** Installs `mas` CLI if needed, then reinstalls Mac App Store apps from the backup list. Apps like Final Cut Pro, Logic Pro, and Keynote come through here.

**Step 4 — Manual Install Check.** Reads the install-sources.txt classification and flags any apps that couldn't be handled by Homebrew or MAS. These need manual download. Accumulates a running TODO list.

**Step 5 — Docker Desktop.** Confirms Docker is installed (via Homebrew cask) and notes that it automatically provides docker, docker-compose, and kubectl CLIs — no need for standalone installs in /usr/local/bin like the old Mac had.

**Step 6 — JetBrains.** Checks for JetBrains Toolbox and restores PyCharm settings (code styles, keymaps, options) if available. JetBrains Toolbox handles IDE installation; settings can also sync via JetBrains account.

**Step 7 — Steam & Games.** Lists native macOS Steam games and CrossOver/Steam Windows games from the backup. Optionally restores CrossOver bottles (saves re-downloading game data). Provides steam:// install links for quick redownload.

**Step 8 — Dotfiles & Config.** Restores dotfiles with `.pre-restore` safety backups, SSH keys with hardened permissions, GPG keys, ~/.config, and cloud credentials (AWS, Kubernetes, Docker).

**Step 9 — Application Settings.** Restores settings for VS Code, Cursor, Ghostty, iTerm2, Warp, and Obsidian. Installs VS Code and Cursor extensions in parallel.

**Step 10 — License Keys & Activation.** Restores preference plists that contain serial numbers and activation data to `~/Library/Preferences/`. Apps like BBEdit, Bartender, iStat Menus, and TG Pro should auto-activate when launched. Points the user to the migration manifest for a full breakdown of what each app needs. This is a Pattern 3 migration — the simplest path for licensed software.

**Step 11 — Browser Extensions & App Plugins.** Displays the full inventory of browser extensions (Chrome, Arc, Opera, Safari) with human-readable names, and lists JetBrains IDE plugins and Obsidian community plugins. Browser extensions can't be auto-installed — this step provides the reference lists so you can reinstall them after signing into each browser (Pattern 5 — most will sync via account). JetBrains plugins need to be reinstalled via each IDE's Settings → Plugins.

**Step 12 — Screenshots.** Restores the date-organized screenshots into `~/Pictures/Screenshots/YYYY/MM/`. Shows a count and year/month breakdown before prompting. Since Step 0 already configured macOS to save new screenshots here, everything ends up in one place going forward.

**Step 13 — Projects.** Flattens all backed-up projects (regardless of where they were scattered on the old Mac) into `~/Developer/personal/`. Shows where they originally came from. Flags orphan code files that weren't in any git repo.

**Step 14 — Personal Files.** The most interactive step. Displays the data classification from the backup, highlighting stale data (old device sync artifacts — recommends skipping), archival data (Zoom recordings — recommends cloud/external storage), and app-generated data (only needed if the app is installed). Restores scattered credentials and auth tokens first (most important for getting tools working). Offers to move loose photos from Desktop to `~/Pictures/Imported/` to keep the Desktop clean. Restores remaining personal files (Documents, Desktop, Downloads, Pictures, Music, Movies) with size prompts, noting that iCloud-synced content will also re-sync when you sign in.

**Step 15 — Python & Conda.** Recreates conda environments from exported YAML files. Reinstalls npm globals. This is late because it depends on runtimes from Step 2.

**Step 16 — System Config.** Restores crontab and Launch Agents.

Finishes with a structured summary organized by migration pattern: what was handled automatically, which apps need account sign-in (Pattern 1), which need manual verification (Pattern 3 license apps), and a pointer to the migration manifest for the full picture.

---

## How to Use: Verify

Run this on the new Mac after restore.sh completes.

```bash
./scripts/verify.sh
```

This script runs a comprehensive checklist across ten categories: core tools (Homebrew, Git, git config), shell (zsh default, .zshrc exists), SSH (directory permissions, key permissions, GitHub connectivity test), GPG (key presence), development tools (node, npm, python3, pip3, code, cursor with version numbers), Homebrew health (formula/cask counts, checks for expected packages like git, gh, node, imagemagick and expected casks like visual-studio-code, cursor, docker, ghostty), directory structure (~/Developer tree, Screenshots folder, screenshot file count and year-directory organization), macOS settings (screenshot location, file extensions visible), cloud configs (AWS, Kubernetes, Docker), key applications (checks /Applications for expected apps), and Steam/CrossOver status (installed games, bottle counts).

Each check is either a pass (green checkmark), fail (red X), or skip (blue info, for tools that weren't in the backup). At the end it prints a scorecard. Any failures indicate something that needs manual attention — the most common being GitHub SSH authentication, which requires adding your SSH public key to GitHub after restoring it to the new machine.

---

## Security

The backup contains sensitive material: SSH private keys, GPG secret keys, AWS credentials, Kubernetes configs, and potentially other secrets in dotfiles. Treat the backup drive accordingly.

Recommended precautions: encrypt the external drive using Disk Utility (Erase with APFS Encrypted format), don't leave the drive unattended during migration, and securely erase the backup after you've verified the new Mac is working. The scripts flag every sensitive operation with a lock icon in the output so you always know when secrets are being handled.

The backup does not capture passwords from Keychain, browser saved passwords, or system-level credentials. Those sync through iCloud Keychain or your browser's own sync mechanism.

---

## Customization

**Adding dotfiles:** Edit the `PRIORITY_DOTFILES` array in `scripts/backup.sh`. The script also auto-discovers any dotfiles in `~/` not in the list, so this is mainly for prioritization.

**Adding app cask mappings:** Edit the `CASK_MAP` associative array in backup.sh to add brew cask names for apps. This is how the script knows that "Ghostty.app" maps to `brew install --cask ghostty`.

**Adding app settings:** Follow the existing pattern in Phase 3 of backup.sh — check if the app's config directory exists, create a subdirectory in the backup, and copy the relevant files.

**Changing the Developer/ layout:** Edit Step 1 in `scripts/restore.sh` to create different subdirectories. Update Step 13 to change where projects are restored to.

**Adding license-key apps:** Edit the `LICENSE_PLISTS` associative array in backup.sh to add new bundle IDs. Find an app's bundle ID with: `defaults read /Applications/AppName.app/Contents/Info.plist CFBundleIdentifier`.

**Adding screenshot scan locations:** Edit the `for search_dir in ...` loop in Phase 5 of backup.sh to add directories beyond Desktop, Documents, and Downloads.

**Skipping sections:** Every section prompts for confirmation. Answer "n" to skip anything you don't need.

---

## License

MIT
