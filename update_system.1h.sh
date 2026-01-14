#!/bin/zsh

# <bitbar.title>macOS Software Update & Migration Toolkit</bitbar.title>
# <bitbar.version>v1.2.0</bitbar.version>
# <bitbar.author>pr-fuzzylogic</bitbar.author>
# <bitbar.author.github>pr-fuzzylogic</bitbar.author.github>
# <bitbar.desc>Monitors Homebrew and App Store updates, tracks history and stats.</bitbar.desc>
# <bitbar.dependencies>brew,mas</bitbar.dependencies>
# <bitbar.abouturl>https://github.com/pr-fuzzylogic/mac_software_updater</bitbar.abouturl>
# <swiftbar.hideSwiftBar>true</swiftbar.hideSwiftBar>
# <swiftbar.hideLastUpdated>true</swiftbar.hideLastUpdated>
# <swiftbar.hideRunInTerminal>true</swiftbar.hideRunInTerminal>
# <swiftbar.hideDisablePlugin>true</swiftbar.hideDisablePlugin>
# <swiftbar.hideAbout>true</swiftbar.hideAbout>


# --- CONFIG SECTION ---

# Set standard locale to avoid parsing errors with grep or sort on different system languages
export LC_ALL=C

# Extract version dynamically from the first 5 lines of the script
VERSION=$(head -n 5 "$0" | grep "<bitbar.version>" | sed 's/.*<bitbar.version>\(.*\)<\/bitbar.version>.*/\1/' | tr -d '\n\r')
if [[ -z "$VERSION" ]]; then VERSION="Unknown"; fi

GITHUB_URL="https://github.com/pr-fuzzylogic/mac_software_updater"
REMOTE_RAW_URL="https://raw.githubusercontent.com/pr-fuzzylogic/mac_software_updater/main/update_system.1h.sh"

# Set the path to Homebrew environment
if [[ -d "/opt/homebrew/bin" ]]; then
    export PATH="/opt/homebrew/bin:$PATH"
else
    export PATH="/usr/local/bin:$PATH"
fi

# --- CRITICAL CHECK: HOMEBREW EXISTENCE ---
# Verify if Homebrew is installed because the script cannot function without it
if ! command -v brew &> /dev/null; then
    if [[ "$1" == "run" ]]; then
        echo "❌ Error: Homebrew is not installed!"
        echo "This tool requires Homebrew to function."
        echo "Please install it from https://brew.sh/"
        echo "Press any key to exit."
        read -k1
        exit 1
    fi
    echo "⚠️ Brew Missing | color=red"
    echo "---"
    echo "Homebrew is strictly required | color=red"
    exit 0
fi

# Define the history and configuration file locations
APP_DIR="$HOME/Library/Application Support/MacSoftwareUpdater"
HISTORY_FILE="$APP_DIR/update_history.log"
CONFIG_FILE="$APP_DIR/settings.conf"
mkdir -p "$APP_DIR"

# Ensure config file exists with default value if missing
if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "UPDATES_ENABLED=\"true\"" > "$CONFIG_FILE"
fi

# Load configuration
source "$CONFIG_FILE"

# --- ACTIONS SECTION ---

# 1. Toggle Auto-Update Preference
if [[ "$1" == "toggle_updates" ]]; then
    if [[ "$UPDATES_ENABLED" == "true" ]]; then
        echo "UPDATES_ENABLED=\"false\"" > "$CONFIG_FILE"
    else
        echo "UPDATES_ENABLED=\"true\"" > "$CONFIG_FILE"
    fi
    open -g "swiftbar://refreshplugin?name=$(basename "$0")"
    exit 0
fi

# 2. Change Update Interval
if [[ "$1" == "change_interval" ]]; then
    SELECTION=$(osascript -e 'choose from list {"1 hour", "2 hours", "6 hours", "12 hours", "1 day"} with title "Update Frequency" with prompt "Select how often to check for updates:" default items "1 hour"')

    if [[ "$SELECTION" == "false" ]]; then
        exit 0
    fi
    
    NEW_SUFFIX=""
    case "$SELECTION" in
        "1 hour")   NEW_SUFFIX="1h" ;;
        "2 hours")  NEW_SUFFIX="2h" ;;
        "6 hours")  NEW_SUFFIX="6h" ;;
        "12 hours") NEW_SUFFIX="12h" ;;
        "1 day")    NEW_SUFFIX="1d" ;;
        *)          exit 1 ;; 
    esac

    DIR=$(dirname "$0")
    # Clean current name and apply new suffix
    NEW_PATH="$DIR/update_system.${NEW_SUFFIX}.sh"

    if [[ "$0" != "$NEW_PATH" ]]; then
        mv "$0" "$NEW_PATH"
        chmod +x "$NEW_PATH"
        
        osascript -e "display notification \"Update frequency changed to $SELECTION.\" with title \"Mac Updater\""
        sleep 2
        open -g "swiftbar://refreshallplugins"
    else
         osascript -e "display notification \"Frequency is already set to $SELECTION.\" with title \"Mac Updater\""
    fi
    exit 0
fi

# 3. About Dialog
if [[ "$1" == "about_dialog" ]]; then
    # Pass VERSION variable as an argument to AppleScript for safety
    BUTTON=$(osascript -e 'on run {ver}' -e 'tell application "System Events"' -e 'activate' -e 'set myResult to display dialog "Mac Software Updater" & return & "Version " & ver & return & return & "An automated toolkit to monitor and update Homebrew & App Store applications." & return & return & "Created by: pr-fuzzylogic" with title "About" buttons {"Close", "Visit GitHub"} default button "Close" with icon note' -e 'return button returned of myResult' -e 'end tell' -e 'end run' -- "$VERSION")
    
    if [[ "$BUTTON" == "Visit GitHub" ]]; then
        open "$GITHUB_URL"
    fi
    exit 0
fi

# 4. Self-Update Action
if [[ "$1" == "update_plugin" ]]; then
    set -e
    echo "⬇️  Downloading latest version..."
    
    # Download to a temporary file first to ensure integrity
    TEMP_TARGET="/tmp/update_system.1h.sh.new"
    if curl -sL "$REMOTE_RAW_URL" -o "$TEMP_TARGET"; then
        echo "✅ Download complete."
        echo "🔄 Installing..."
        
        # Overwrite the current script
        mv "$TEMP_TARGET" "$0"
        chmod +x "$0"
        
        echo "✅ Plugin updated successfully."
        echo "🔄 Refreshing SwiftBar interface..."
        
        sleep 2
        open -g "swiftbar://refreshallplugins"
        
        echo "Done! The new version is active."
    else
        echo "❌ Error: Download failed."
        exit 1
    fi
    echo "Press any key to close."
    read -k1
    exit 0
fi

# --- UPDATE SECTION (Runs in Terminal) ---
if [[ "$1" == "run" ]]; then
    # Set error flags to stop on failure
    set -e
    set -o pipefail
    
    # Refresh PATH inside the run block
    if [[ -d "/opt/homebrew/bin" ]]; then
        export PATH="/opt/homebrew/bin:$PATH"
    else
        export PATH="/usr/local/bin:$PATH"
    fi

    echo "🚀 Starting System Update..."
    echo "---------------------------"

    # Update the repositories first to get the latest state
    echo "📦 Updating Homebrew Database..."
    brew update

    # Calculate the actual number of pending updates AFTER the fresh fetch
    echo "🔍 Calculating pending updates..."
    # Using 'grep -c' is safer than 'wc -l' to avoid counting empty lines
    real_brew_count=$(brew outdated --greedy | grep -c -- '[^[:space:]]' || true)
    
    real_mas_count=0
    if command -v mas &> /dev/null; then
        real_mas_count=$(mas outdated | grep -c -- '[^[:space:]]' || true)
    fi
    
    updates_count=$((real_brew_count + real_mas_count))
    
    if [[ $updates_count -gt 0 ]]; then
        echo "💡 Found $updates_count updates to apply."
    else
        echo "ℹ️ System seems up to date after fetch."
    fi

    # Perform the upgrades
    echo "📦 Upgrading Formulae and Casks..."
    brew upgrade --greedy
    
    echo "🧹 Cleaning up..."
    brew cleanup --prune=all
    
    if command -v mas &> /dev/null; then
        echo "🍎 Updating App Store Applications..."
        mas upgrade
    fi

    # Log to history ONLY if the upgrade process finished successfully
    if [[ $updates_count -gt 0 ]]; then
        mkdir -p "$(dirname "$HISTORY_FILE")"
        if echo "$(date +%s)|$updates_count" >> "$HISTORY_FILE"; then
            echo "📝 Logged $updates_count updates to history."
        else
            echo "❌ Failed to write to history file."
        fi
        
        # Log rotation
        if [[ $(wc -l < "$HISTORY_FILE") -gt 500 ]]; then
             tail -n 100 "$HISTORY_FILE" > "$HISTORY_FILE.tmp" && mv "$HISTORY_FILE.tmp" "$HISTORY_FILE"
        fi
    fi

    echo "---------------------------"
    echo "✅ Update Complete!"
    
    # Trigger a refresh in SwiftBar
    echo "🔄 Refreshing SwiftBar..."
    open -g "swiftbar://refreshplugin?name=$(basename "$0")"

    echo "Done! Press any key to close."
    read -k1
    exit
fi

# --- STATUS CHECK SECTION (Background) ---

# Check for Plugin Update using SHA-256 Hash
update_available=0
if [[ "$UPDATES_ENABLED" == "true" ]]; then
    local_hash=$(shasum -a 256 "$0" | awk '{print $1}')
    remote_temp="/tmp/update_system_remote_check.tmp"

    if curl -sL --max-time 5 "$REMOTE_RAW_URL" -o "$remote_temp"; then
        remote_hash=$(shasum -a 256 "$remote_temp" | awk '{print $1}')
        if [[ "$local_hash" != "$remote_hash" ]]; then
            update_available=1
        fi
        rm -f "$remote_temp"
    fi
fi

# Check Homebrew for updates
list_brew=$(brew outdated --verbose --greedy)
count_brew=$(echo -n "$list_brew" | grep -c -- '[^[:space:]]')

# Check App Store for updates
list_mas=""
count_mas=0
if command -v mas &> /dev/null; then
    list_mas=$(mas outdated)
    count_mas=$(echo -n "$list_mas" | grep -c -- '[^[:space:]]')
fi

total=$((count_brew + count_mas))

# Collect total installed statistics for the submenu
count_casks=$(brew list --cask | wc -l | tr -d ' ')
count_formulae=$(brew list --formula | wc -l | tr -d ' ')
count_mas_installed=0
if command -v mas &> /dev/null; then
    count_mas_installed=$(mas list | wc -l | tr -d ' ')
fi
total_installed=$((count_casks + count_formulae + count_mas_installed))

# Calculate history statistics safely
updates_week=0
updates_month=0
current_time=$(date +%s)

if [[ -f "$HISTORY_FILE" ]]; then
    while IFS='|' read -r log_time log_count; do
        if [[ -z "$log_time" ]] || [[ -z "$log_count" ]]; then continue; fi
        if [[ ! "$log_time" =~ ^[0-9]+$ ]] || [[ ! "$log_count" =~ ^[0-9]+$ ]]; then continue; fi

        diff=$((current_time - log_time))
        if [[ $diff -le 604800 ]]; then updates_week=$((updates_week + log_count)); fi
        if [[ $diff -le 2592000 ]]; then updates_month=$((updates_month + log_count)); fi
    done < "$HISTORY_FILE"
fi

# --- UI RENDERING ---

# Set main menu bar icon status based on updates and plugin availability
if [[ $update_available -eq 1 ]]; then
    if [[ $total -gt 0 ]]; then
        echo " $total | sfimage=arrow.down.circle.fill color=purple"
    else
        echo " ! | sfimage=arrow.down.circle.fill color=blue"
    fi
else
    if [[ $total -gt 0 ]]; then
        echo " $total | sfimage=arrow.triangle.2.circlepath.circle color=red"
    else
        echo " | sfimage=checkmark.circle"
    fi
fi
echo "---"

# Render Plugin Update Notification
if [[ $update_available -eq 1 ]]; then
    script_path="${0// /\\ }"
    echo "Plugin Update Available | color=blue sfimage=arrow.down.circle.fill"
    echo "-- Update Now | bash='$script_path' param1=update_plugin terminal=true sfimage=arrow.triangle.2.circlepath"
    echo "---"
fi

# Show update details
if [[ $total -eq 0 ]]; then
    if [[ $update_available -eq 1 ]]; then
        echo "Local apps are up to date | color=gray size=10"
    else
        echo "System is up to date | color=green sfimage=checkmark.shield"
    fi
else
    if [[ $count_brew -gt 0 ]]; then
        echo "Homebrew ($count_brew): | color=gray size=12 sfimage=shippingbox"
        echo "$list_brew" | while read -r line; do echo "$line | size=12 font=Monaco"; done
        echo "---"
    fi
    if [[ $count_mas -gt 0 ]]; then
        echo "App Store ($count_mas): | color=gray size=12 sfimage=bag"
        # Show App Store updates without the numerical digital ID for a cleaner UI
        echo "$list_mas" | awk '{$1=""; print $0}' | while read -r line; do echo "$line | size=12 font=Monaco"; done
    fi
fi

# Render statistics and history with submenus
echo "---"
echo "Monitored: $total_installed items | color=gray size=12 sfimage=chart.bar.xaxis"
echo "-- Apps (Brew Cask): $count_casks | color=gray size=11 sfimage=square.stack.3d.up"
echo "-- CLI Tools (Brew Formulae): $count_formulae | color=gray size=11 sfimage=terminal"
echo "-- App Store: $count_mas_installed | color=gray size=11 sfimage=bag"

echo "History: | color=gray size=12 sfimage=clock.arrow.circlepath"
echo "-- Past 7 days: $updates_week updates | color=gray size=11 sfimage=calendar"
echo "-- Past 30 days: $updates_month updates | color=gray size=11 sfimage=calendar.badge.clock"

# Render the footer with operational buttons
echo "---"
script_path="${0// /\\ }"
if [[ $total -gt 0 ]]; then
    echo "Update All | bash='$script_path' param1=run terminal=true sfimage=arrow.triangle.2.circlepath.circle"
else
    echo "Update All | color=gray sfimage=checkmark.circle"
fi
echo "Last check: $(date +%H:%M) | size=10 color=gray"
echo "Refresh now | refresh=true sfimage=arrow.clockwise"

# Bottom Group: Preferences & About
echo "---"
echo "Preferences | sfimage=gearshape"
echo "-- Change Update Frequency | bash='$script_path' param1=change_interval terminal=false refresh=true sfimage=hourglass"
if [[ "$UPDATES_ENABLED" == "true" ]]; then
    echo "-- Disable Self-Update | bash='$script_path' param1=toggle_updates terminal=false refresh=true sfimage=xmark.circle"
else
    echo "-- Enable Self-Update | bash='$script_path' param1=toggle_updates terminal=false refresh=true sfimage=checkmark.circle"
fi
echo "About | bash='$script_path' param1=about_dialog terminal=false sfimage=info.circle"