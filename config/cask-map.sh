#!/bin/bash
# =============================================================================
# cask-map.sh — Maps application names to Homebrew cask names
#
# The backup script uses this to classify apps and generate Brewfile.addon.
# Only entries where the app name doesn't trivially match the cask name need
# to be listed here. The script will auto-discover cask names for unlisted
# apps by querying `brew search`.
#
# Format: "App Name.app|brew-cask-name"  (pipe-delimited, bash 3.2-safe)
#
# To find a cask name:   brew search --cask "app name"
# To verify:             brew info --cask <cask-name>
# =============================================================================

CASK_MAP=(
    # ── Terminals & Editors ──────────────────────────────────────────────────
    "Visual Studio Code.app|visual-studio-code"
    "iTerm.app|iterm2"

    # ── Browsers ─────────────────────────────────────────────────────────────
    "Google Chrome.app|google-chrome"

    # ── JetBrains ────────────────────────────────────────────────────────────
    "JetBrains Toolbox.app|jetbrains-toolbox"
    # Add individual IDEs here if installed outside Toolbox:
    # "PyCharm.app|pycharm"
    # "IntelliJ IDEA.app|intellij-idea"
    # "WebStorm.app|webstorm"

    # ── Productivity ─────────────────────────────────────────────────────────
    "1Password.app|1password"
    "Bartender 5.app|bartender"
    # "Bartender 4.app|bartender"

    # ── Media & Utilities ────────────────────────────────────────────────────
    "Gemini 2.app|gemini"
    "TigerVNC.app|tigervnc-viewer"
    "logioptionsplus.app|logitech-options-plus"
    "draw.io.app|drawio"
    "iStat Menus.app|istat-menus"

    # ── Creative / Design ────────────────────────────────────────────────────
    "Wondershare UniConverter 16.app|wondershare-uniconverter"

    # ── Add your own mappings below ──────────────────────────────────────────
    # Only needed when the .app name doesn't match the cask name.
    # Most apps (like "Cursor.app" → "cursor", "Steam.app" → "steam") are
    # auto-discovered and don't need entries here.
)
