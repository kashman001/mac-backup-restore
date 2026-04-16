#!/bin/bash
# =============================================================================
# app-settings.sh — Maps apps to their configuration file locations
#
# The backup script copies these settings directories. The restore script
# puts them back. Each entry defines:
#   display name | source path (relative to $HOME) | backup subdirectory name
#   | files to copy (optional, space-separated; empty = copy all)
#
# Paths use ~ as a placeholder for $HOME (expanded at runtime).
# =============================================================================

# APP_SETTINGS is an array of pipe-delimited strings:
#   "Name|source_path|backup_subdir|files_to_copy"
#
# - source_path: relative to $HOME, e.g. "Library/Application Support/Code/User"
# - backup_subdir: name under app-settings/ in the backup
# - files_to_copy: space-separated list of specific files/dirs to copy.
#                  Leave empty to copy everything in source_path.

APP_SETTINGS=(
    # ── Code Editors ─────────────────────────────────────────────────────────
    "VS Code|Library/Application Support/Code/User|vscode|settings.json keybindings.json snippets"
    "Cursor|Library/Application Support/Cursor/User|cursor|settings.json keybindings.json snippets"
    "Zed|.config/zed|zed|settings.json keymap.json"

    # ── Terminals ────────────────────────────────────────────────────────────
    "Ghostty|Library/Application Support/com.mitchellh.ghostty|ghostty|"
    "iTerm2|Library/Preferences/com.googlecode.iterm2.plist|iterm2|"
    "Warp|Library/Application Support/dev.warp.Warp-Stable|warp|prefs.json keybindings.yaml launch_configurations.yaml"

    # ── IDEs ─────────────────────────────────────────────────────────────────
    # PyCharm settings are handled specially (finds the latest version dir).
    # Add other JetBrains IDEs the same way if needed — see backup.sh.

    # ── Note-taking ──────────────────────────────────────────────────────────
    "Obsidian|Library/Application Support/obsidian|obsidian|obsidian.json"

    # ── Add your own app settings below ──────────────────────────────────────
    # Format: "App Name|path/relative/to/home|backup-dir-name|files or empty"
    #
    # Examples:
    # "Alacritty|.config/alacritty|alacritty|"
    # "Raycast|Library/Application Support/com.raycast.macos|raycast|"
    # "Hammerspoon|.hammerspoon|hammerspoon|init.lua Spoons"
    # "Karabiner-Elements|.config/karabiner|karabiner|karabiner.json"
)

# JetBrains IDEs to scan for settings (finds latest version automatically).
# Format: "Display Name|directory name prefix under JetBrains/"
# The script scans ~/Library/Application Support/JetBrains/<prefix>*/
JETBRAINS_IDES=(
    "PyCharm|PyCharm"
    "IntelliJ IDEA|IntelliJIdea"
    "WebStorm|WebStorm"
    "GoLand|GoLand"
    "CLion|CLion"
    "Rider|Rider"
    "DataGrip|DataGrip"
    "RubyMine|RubyMine"
    "PhpStorm|PhpStorm"
)

# JetBrains subdirectories to back up from each IDE's config directory
JETBRAINS_SUBDIRS=(codestyles colors inspection keymaps options templates)
