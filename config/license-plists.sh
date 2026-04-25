#!/bin/bash
# =============================================================================
# license-plists.sh — Maps apps to their license/activation preference plists
#
# Many macOS apps store serial numbers or activation state in a plist file
# under ~/Library/Preferences/. Copying these to the new Mac avoids having
# to re-enter license keys.
#
# Format: "Display Name|com.developer.app.bundle.id"  (pipe-delimited, bash 3.2-safe)
#
# To find an app's bundle ID:
#   defaults read /Applications/AppName.app/Contents/Info.plist CFBundleIdentifier
#
# To check if it stores license data:
#   defaults read com.developer.app 2>/dev/null | grep -i 'license\|serial\|regist'
# =============================================================================

LICENSE_PLISTS=(
    # ── Text Editors ─────────────────────────────────────────────────────────
    "BBEdit|com.barebones.bbedit"
    "Sublime Text|com.sublimetext.4"

    # ── System Utilities ─────────────────────────────────────────────────────
    "Bartender|com.surteesstudios.Bartender"
    "iStat Menus|com.bjango.istatmenus"
    "iStat Menus (helper)|com.bjango.istatmenus.agent"
    "iStat Menus (status)|com.bjango.istatmenus.status"
    "TG Pro|com.tunabellysoftware.tgpro"

    # ── Productivity ─────────────────────────────────────────────────────────
    "Gemini 2|com.macpaw.site.Gemini2"

    # ── Screenshot / OCR ─────────────────────────────────────────────────────
    "Shottr|cc.shottr.shottr"
    "TextSniper|com.TextSniper.TextSniper"

    # ── Compatibility ────────────────────────────────────────────────────────
    "CrossOver|com.codeweavers.CrossOver"

    # ── Add your own license plists below ────────────────────────────────────
    # If an app asks for a serial number on launch, check if it stores
    # activation data in its preferences plist (see instructions above).
)
