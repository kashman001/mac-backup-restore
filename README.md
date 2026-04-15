# Mac Backup & Restore

Clean migration toolkit for moving to a new Mac without using Migration Assistant. Back up everything that matters from your current Mac, then set up the new one from scratch with an organized directory layout.

## Philosophy

Instead of cloning your old Mac (and carrying over years of cruft), this toolkit:

1. **Captures** a complete inventory of your software, configs, projects, and files
2. **Restores** selectively on the new Mac, letting you start clean
3. **Organizes** your new Mac with a sensible directory structure
4. **Verifies** that everything made it over correctly

## Quick Start

### On your old Mac

```bash
git clone https://github.com/<you>/mac-backup-restore.git
cd mac-backup-restore

# Plug in your external drive, then:
./scripts/backup.sh /Volumes/YourDrive
```

### On your new Mac

```bash
# Install Xcode command line tools (needed for git)
xcode-select --install

# Clone this repo (or copy it from your drive)
git clone https://github.com/<you>/mac-backup-restore.git
cd mac-backup-restore

# Restore from your backup
./scripts/restore.sh /Volumes/YourDrive/mac-backup/<timestamp>

# Verify everything worked
./scripts/verify.sh
```

## What Gets Backed Up

| Category | What's Captured |
|---|---|
| **Software inventory** | Brewfile (formulae, casks, taps), Mac App Store apps, npm/pip/cargo/gem globals, VS Code extensions |
| **Dotfiles & config** | Shell configs, .gitconfig, .ssh, .gnupg, ~/.config, AWS/Kube/Docker configs |
| **App settings** | VS Code, Cursor, iTerm2, Sublime Text, full macOS defaults |
| **Projects** | Git repos found across common directories (without node_modules, build dirs, etc.) |
| **Personal files** | Documents, Desktop, Downloads, Pictures, Music, Movies (each prompted individually) |
| **System** | Crontab, Launch Agents |

## New Mac Directory Layout

The restore script sets up this structure:

```
~/
├── Developer/
│   ├── personal/       ← your personal projects
│   ├── work/           ← employer/client projects
│   ├── oss/            ← open source contributions
│   └── experiments/    ← throwaway experiments
├── Documents/          ← synced to iCloud
├── Pictures/
│   └── Screenshots/    ← macOS screenshot destination
└── .config/            ← XDG-style app configs
```

## Scripts

| Script | Purpose |
|---|---|
| `scripts/backup.sh` | Full backup of current Mac to external drive |
| `scripts/restore.sh` | Set up new Mac from a backup |
| `scripts/verify.sh` | Post-restore verification checklist |

## macOS Preferences Applied by Restore

The restore script optionally applies these sensible defaults:

- Finder: show file extensions, path bar, status bar; search current folder
- Dock: auto-hide, 48px icons, don't rearrange Spaces
- Keyboard: fast key repeat (KeyRepeat=2, InitialKeyRepeat=15)
- Trackpad: tap to click
- Screenshots: save to ~/Pictures/Screenshots
- Disable .DS_Store on network and USB volumes
- Show ~/Library folder

## Security Notes

Your backup will contain sensitive material (SSH keys, GPG keys, cloud credentials). Treat the backup drive with the same care you'd give your laptop:

- Don't leave the drive unattended
- Consider encrypting the drive (Disk Utility → Erase → APFS Encrypted)
- After successful migration and verification, securely erase the backup if you no longer need it

## Customization

### Adding custom dotfiles

Edit the `DOTFILES` array in `scripts/backup.sh` to include any additional config files.

### Changing project search locations

Edit the `SEARCH_DIRS` array in `scripts/backup.sh` to add directories where you keep projects.

### Skipping sections

Every section in both backup and restore scripts prompts for confirmation, so you can skip anything you don't need.

## License

MIT
