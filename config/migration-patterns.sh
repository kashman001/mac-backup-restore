#!/bin/bash
# =============================================================================
# migration-patterns.sh — Classify apps by their migration pattern
#
# This file defines which apps fall into each migration pattern:
#   SIGN-IN      → install, sign into account, everything syncs
#   CONFIG       → install, restore config files from backup
#   LICENSE-KEY  → install, restore license plist or re-enter serial
#   RE-DOWNLOAD  → install, sign in, re-download content
#   EXTENSION    → host app handles it (sync or reinstall from list)
#
# Apps not listed here are classified automatically:
#   - Apps with backed-up settings → CONFIG
#   - Apps with license plists → LICENSE-KEY
#   - Apps installed via Homebrew → BREW-AUTO
#   - Everything else → shown in the migration manifest for manual review
#
# Only list apps here that need explicit classification. The backup script
# auto-detects CONFIG and LICENSE-KEY apps from the other config files.
# =============================================================================

# Apps that restore everything via account login (cloud-synced).
# Format: one app name per line (must match the .app name without the .app suffix)
SIGN_IN_APPS=(
    "1Password"
    "OneDrive"
    "Dropbox"
    "Google Drive"
    "iCloud"        # Not an app, but a reminder in the manifest
    "ChatGPT"
    "Claude"
    "Perplexity"
    "WhatsApp"
    "Telegram"
    "Signal"
    "Slack"
    "Discord"
    "Zoom"
    "Microsoft Teams"
    "Microsoft Word"
    "Microsoft Excel"
    "Microsoft PowerPoint"
    "Microsoft Outlook"
    "Microsoft OneNote"
    "Notion"
    "Todoist"
    "Figma"
    "Spotify"
    "Netflix"
)

# Apps that manage large content requiring re-download after install.
# Format: "App Name|restore instructions"
RE_DOWNLOAD_APPS=(
    "Steam|sign in and re-download games from your library"
    "CrossOver|restore bottles from backup OR re-download"
    "Docker|pull images after install (docker pull)"
)
# Note: Anaconda/conda is auto-detected from conda-envs/ in the backup.
