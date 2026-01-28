#!/bin/zsh

autoload -U colors && colors
set -e

# Helper function for confirmations
ask_confirmation() {
    local prompt="$1"
    echo -n "$prompt [y/N] "
    read -r response
    [[ "$response" == "y" || "$response" == "Y" ]]
}

echo "${fg[red]}=== Mac Software Updater: Uninstaller v1.3.2 ===${reset_color}"

# 1. Remove the SwiftBar Plugin
echo ""
echo "Step 1: SwiftBar Plugin"
# Try to find the plugin directory from SwiftBar settings
PLUGIN_DIR=$(defaults read com.ameba.SwiftBar PluginDirectory 2>/dev/null || echo "")
EXPANDED_DIR="${PLUGIN_DIR/#\~/$HOME}"

if [[ -d "$EXPANDED_DIR" ]]; then
    # Look for any version of the script (1h, 1d, etc.)
    FILES=($EXPANDED_DIR/update_system.*.sh)
    if [[ -e ${FILES[1]} ]]; then
        echo "Found plugin(s) in: $EXPANDED_DIR"
        if ask_confirmation "Delete update_system script from SwiftBar?"; then
            rm -f $EXPANDED_DIR/update_system.*.sh
            echo "Plugin removed."
        fi
    else
        echo "No update_system scripts found in $EXPANDED_DIR."
    fi
else
    echo "Could not automatically determine SwiftBar plugin directory."
fi

# 2. Remove Data & Config
echo ""
echo "Step 2: Local Data & Configuration"
APP_DIR="$HOME/Library/Application Support/MacSoftwareUpdater"
if [[ -d "$APP_DIR" ]]; then
    if ask_confirmation "Delete logs and configuration files in $APP_DIR?"; then
        rm -rf "$APP_DIR"
        echo "Data removed."
    fi
else
    echo "No local data directory found."
fi

# 3. Optional Dependencies
echo ""
echo "Step 3: Dependencies (Optional)"

if command -v mas &> /dev/null; then
    if ask_confirmation "Uninstall 'mas' (App Store CLI)?"; then
        brew uninstall mas
    fi
fi

if brew list --cask swiftbar &> /dev/null; then
    if ask_confirmation "Uninstall SwiftBar app?"; then
        # Remove from login items first
        echo "Removing SwiftBar from Login Items..."
        osascript -e 'tell application "System Events" to delete every login item whose name is "SwiftBar"' 2>/dev/null || true
        brew uninstall --cask swiftbar
    fi
fi

if command -v brew &> /dev/null; then
    echo ""
    echo "${fg[yellow]}WARNING: Uninstalling Homebrew will remove ALL brew-installed packages!${reset_color}"
    if ask_confirmation "Do you want to completely uninstall Homebrew from this system?"; then
        /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/uninstall.sh)"
    fi
fi

echo ""
echo "${fg[green]}Uninstallation process finished.${reset_color}"
