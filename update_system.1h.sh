#!/bin/zsh

# <bitbar.title>macOS Software Update & Migration Toolkit</bitbar.title>
# <bitbar.version>v1.2.5</bitbar.version>
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
umask 077

# --- THEME CONFIGURATION (DUAL MODE) ---
# Format: COLOR_LIGHT,COLOR_DARK
# SwiftBar automatically switches between these based on system theme WITHOUT needing a refresh.

# Text Color: Almost Black for Light Mode, Light Gray for Dark Mode
COLOR_INFO="#333333,#B0B0B0"

# Success (Green): Deep Emerald for Light, Neon Green for Dark
COLOR_SUCCESS="#007A33,#32D74B"

# Warning (Red): Deep Red for Light, Bright Red for Dark
COLOR_WARN="#D70015,#FF453A"

# Purple: Deep Indigo for Light, Pastel Purple for Dark
COLOR_PURPLE="#5856D6,#BF5AF2"

# Blue: Deep Blue for Light, Sky Blue for Dark
COLOR_BLUE="#0040DD,#54A0FF"

# Extract version dynamically from the first 5 lines of the script
VERSION=$(head -n 5 "$0" | grep "<bitbar.version>" | sed 's/.*<bitbar.version>\(.*\)<\/bitbar.version>.*/\1/' | tr -d '\n\r')
if [[ -z "$VERSION" ]]; then VERSION="Unknown"; fi

# --- FAILOVER CONFIGURATION ---
# Primary: GitHub
URL_PRIMARY_BASE="https://raw.githubusercontent.com/pr-fuzzylogic/mac_software_updater/main"
# Backup: Codeberg (Note the syntax difference /raw/branch/main)
URL_BACKUP_BASE="https://codeberg.org/pr-fuzzylogic/mac_software_updater/raw/branch/main"

# GitHub Project URL for "Visit Website" button
PROJECT_URL="https://github.com/pr-fuzzylogic/mac_software_updater"

# Set the path to Homebrew environment
if [[ -d "/opt/homebrew/bin" ]]; then
    export PATH="/opt/homebrew/bin:$PATH"
else
    export PATH="/usr/local/bin:$PATH"
fi

# --- SELF CLEANUP ROUTINE ---
# Detects and removes utility scripts if accidentally placed in the plugin folder
PLUGIN_Location=$(dirname "$0")
Junk_Files=("setup_mac.sh" "uninstall.sh")

for junk in $Junk_Files; do
    if [[ -f "$PLUGIN_Location/$junk" ]]; then
        rm -f "$PLUGIN_Location/$junk"
    fi
done

# --- HELPER: FAILOVER DOWNLOAD ---
# Tries to download from Primary, then Backup.
# Usage: download_with_failover "filename.sh" "output_path"
download_with_failover() {
    local file_name="$1"
    local output_path="$2"
    
    # Try Primary (GitHub)
    # -f fails on HTTP errors (404), -L follows redirects, -s silent
    if curl -fLsS --proto '=https' --tlsv1.2 --connect-timeout 5 "$URL_PRIMARY_BASE/$file_name" -o "$output_path"; then
        return 0
    fi
    
    echo "⚠️ Primary source failed. Trying backup..."
    
    # Try Backup (Codeberg)
    if curl -fLsS --proto '=https' --tlsv1.2 --connect-timeout 8 "$URL_BACKUP_BASE/$file_name" -o "$output_path"; then
        return 0
    fi
    
    return 1
}


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

chmod 600 "$CONFIG_FILE" 2>/dev/null || true
chmod 700 "$APP_DIR" 2>/dev/null || true

# Load configuration safely (parse text instead of executing code)
UPDATES_ENABLED=$(grep -E '^[[:space:]]*UPDATES_ENABLED[[:space:]]*=' "$CONFIG_FILE" | head -n 1 | sed -E 's/^[[:space:]]*UPDATES_ENABLED[[:space:]]*=[[:space:]]*"(true|false)"[[:space:]]*$/\1/' || true)
if [[ "$UPDATES_ENABLED" != "true" && "$UPDATES_ENABLED" != "false" ]]; then
    UPDATES_ENABLED="true"
fi

# Escaping function
swiftbar_sq_escape() {
  print -r -- "${1//\'/\'\\\'\'}"
}

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
    BUTTON=$(osascript -e 'on run {ver}' -e 'tell application "System Events"' -e 'activate' -e 'set myResult to display dialog "Mac Software Updater" & return & "Version " & ver & return & return & "An automated toolkit to monitor and update Homebrew & App Store applications." & return & return & "Created by: pr-fuzzylogic" with title "About" buttons {"Close", "Visit GitHub"} default button "Close" with icon note' -e 'return button returned of myResult' -e 'end tell' -e 'end run' -- "$VERSION")
    
    if [[ "$BUTTON" == "Visit GitHub" ]]; then
        open "$PROJECT_URL"
    fi
    exit 0
fi

# 4. Self-Update Action (WITH FAILOVER)
if [[ "$1" == "update_plugin" ]]; then
    set -e
    
    echo "⬇️  Updating all toolkit components..."

    echo "Updating Setup Wizard..."
    if download_with_failover "setup_mac.sh" "$APP_DIR/setup_mac.sh"; then
        chmod +x "$APP_DIR/setup_mac.sh"
    else
        echo "❌ Failed to download Setup Wizard from any source."
    fi

    echo "Updating Uninstaller..."
    if download_with_failover "uninstall.sh" "$APP_DIR/uninstall.sh"; then
        chmod +x "$APP_DIR/uninstall.sh"
    else
        echo "❌ Failed to download Uninstaller."
    fi

    echo "Updating Menu Bar Monitor..."
    TEMP_TARGET="$(mktemp "${TMPDIR:-/tmp}/update_system.selfupdate.XXXXXX")"
    trap 'rm -f "$TEMP_TARGET"' EXIT
    
    if download_with_failover "update_system.1h.sh" "$TEMP_TARGET"; then
        if head -n 1 "$TEMP_TARGET" | grep -q '^#!/bin/zsh'; then
            mv "$TEMP_TARGET" "$0"
            chmod +x "$0"
            rm -f "$APP_DIR/.plugin_update_pending"
            
            echo "✅ All components updated successfully."
            echo "🔄 Refreshing SwiftBar..."
            sleep 2
            open -g "swiftbar://refreshallplugins"
        else
            echo "❌ Error: Downloaded plugin file is invalid."
            exit 1
        fi
    else
        echo "❌ Error: Plugin download failed from all sources."
        exit 1
    fi
    echo "Done! Press any key to close."
    read -k1
    exit 0
fi

# --- UPDATE SECTION (Runs in Terminal) ---
if [[ "$1" == "run" ]]; then
    set -e
    set -o pipefail
    
    if [[ -d "/opt/homebrew/bin" ]]; then
        export PATH="/opt/homebrew/bin:$PATH"
    else
        export PATH="/usr/local/bin:$PATH"
    fi

    echo "🚀 Starting System Update..."
    echo "---------------------------"

    echo "📦 Updating Homebrew Database..."
    brew update

    echo "🔍 Calculating pending updates..."
    
    real_brew_count=$(brew outdated --greedy | grep -v "latest) != latest" | grep -v "^font-" | grep -c -- '[^[:space:]]' || true)
    
    real_mas_count=0
    if command -v mas &> /dev/null; then
        real_mas_count=$(mas outdated | grep -E '^[0-9]+' | wc -l | tr -d ' ' || true)
    fi
    
    updates_count=$((real_brew_count + real_mas_count))
    
    if [[ $updates_count -gt 0 ]]; then
        echo "💡 Found $updates_count updates to apply."
    else
        echo "ℹ️ System seems up to date after fetch."
    fi

    echo "📦 Upgrading Formulae and Casks..."
    brew upgrade --greedy
    
    echo "🧹 Cleaning up..."
    brew cleanup --prune=all
    
    if command -v mas &> /dev/null; then
        echo "🍎 Updating App Store Applications..."
        mas upgrade
    fi

    if [[ $updates_count -gt 0 ]]; then
        mkdir -p "$(dirname "$HISTORY_FILE")"
        if echo "$(date +%s)|$updates_count" >> "$HISTORY_FILE"; then
            echo "📝 Logged $updates_count updates to history."
        else
            echo "❌ Failed to write to history file."
        fi
        
        if [[ $(wc -l < "$HISTORY_FILE") -gt 500 ]]; then
             tail -n 100 "$HISTORY_FILE" > "$HISTORY_FILE.tmp" && mv "$HISTORY_FILE.tmp" "$HISTORY_FILE"
        fi
    fi

    echo "---------------------------"
    echo "✅ Update Complete!"
    
    echo "🔄 Refreshing SwiftBar..."
    open -g "swiftbar://refreshplugin?name=$(basename "$0")"

    echo "Done! Press any key to close."
    read -k1
    exit
fi

# --- STATUS CHECK SECTION (Background) ---

update_available=0
if [[ "$UPDATES_ENABLED" == "true" ]]; then
    LAST_CHECK_FILE="$APP_DIR/.last_plugin_check"
    ETAG_FILE="$APP_DIR/.plugin_etag"
    PENDING_FLAG="$APP_DIR/.plugin_update_pending"
    
    CURRENT_TIME=$(date +%s)
    LAST_CHECK=0
    [[ -f "$LAST_CHECK_FILE" ]] && LAST_CHECK=$(cat "$LAST_CHECK_FILE")
    
    # Check only if 3 days passed
    if [[ $((CURRENT_TIME - LAST_CHECK)) -gt 259200 ]]; then
        last_etag=""
        [[ -f "$ETAG_FILE" ]] && last_etag=$(cat "$ETAG_FILE")

        # SMART FAILOVER CHECK
        # 1. Try to get ETag from GitHub
        current_etag=$(curl -fI -LsS --proto '=https' --tlsv1.2 --connect-timeout 3 "$URL_PRIMARY_BASE/update_system.1h.sh" 2>/dev/null | grep -i "etag:" | awk '{print $2}' | tr -d '\r\n')
        
        active_url="$URL_PRIMARY_BASE"
        
        # 2. If GitHub empty (down/blocked), try Codeberg
        if [[ -z "$current_etag" ]]; then
            current_etag=$(curl -fI -LsS --proto '=https' --tlsv1.2 --connect-timeout 3 "$URL_BACKUP_BASE/update_system.1h.sh" 2>/dev/null | grep -i "etag:" | awk '{print $2}' | tr -d '\r\n')
            active_url="$URL_BACKUP_BASE"
        fi

        # If we got an ETag from ANY source, proceed
        if [[ -n "$current_etag" && "$current_etag" != "$last_etag" ]]; then
            remote_temp="$(mktemp "${TMPDIR:-/tmp}/update_system.remotecheck.XXXXXX")"
            trap 'rm -f "$remote_temp"' EXIT
            
            # Use the URL that actually responded above
            if curl -fLsS --proto '=https' --tlsv1.2 --connect-timeout 5 "$active_url/update_system.1h.sh" -o "$remote_temp"; then
                if head -n 1 "$remote_temp" | grep -q '^#!/bin/zsh'; then
                    local_hash=$(shasum -a 256 "$0" | awk '{print $1}')
                    remote_hash=$(shasum -a 256 "$remote_temp" | awk '{print $1}')
                    
                    if [[ "$local_hash" != "$remote_hash" ]]; then
                        touch "$PENDING_FLAG"
                        echo "$current_etag" > "$ETAG_FILE"
                    else
                        rm -f "$PENDING_FLAG"
                        echo "$current_etag" > "$ETAG_FILE"
                    fi
                fi
                rm -f "$remote_temp"
            fi
        fi
        echo "$CURRENT_TIME" > "$LAST_CHECK_FILE"
    fi
    
    [[ -f "$PENDING_FLAG" ]] && update_available=1
fi

# Check Homebrew for updates
list_brew=$(brew outdated --verbose --greedy | grep -v "latest) != latest" | grep -v "^font-")
count_brew=$(echo -n "$list_brew" | grep -c -- '[^[:space:]]' || true)

# Check App Store for updates
list_mas=""
count_mas=0
if command -v mas &> /dev/null; then
    list_mas=$(mas outdated)
    count_mas=$(echo "$list_mas" | grep -E '^[0-9]+' | wc -l | tr -d ' ')
fi

total=$((count_brew + count_mas))

# Collect total installed statistics for the submenu (Optimized for listing with versions)

# 1. Casks with versions
# Output format of brew list --cask --versions: "token 1.2.3"
raw_casks=$(brew list --cask --versions)
count_casks=$(echo "$raw_casks" | grep -c '[^[:space:]]' || echo 0)

# 2. Formulae with versions
# Output format of brew list --formula --versions: "token 1.2.3"
raw_formulae=$(brew list --formula --versions)
count_formulae=$(echo "$raw_formulae" | grep -c '[^[:space:]]' || echo 0)

# 3. MAS (App Store)
# Output format of mas list: "123456 App Name (1.2.3)"
installed_mas=""
count_mas_installed=0
if command -v mas &> /dev/null; then
    installed_mas=$(mas list)
    count_mas_installed=$(echo "$installed_mas" | wc -l | tr -d ' ')
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

# Set main menu bar icon status
if [[ $update_available -eq 1 ]]; then
    if [[ $total -gt 0 ]]; then
        echo " $total | sfimage=arrow.down.circle.fill color=$COLOR_PURPLE"
    else
        echo " ! | sfimage=arrow.down.circle.fill color=$COLOR_BLUE"
    fi
else
    if [[ $total -gt 0 ]]; then
        echo " $total | sfimage=arrow.triangle.2.circlepath.circle color=$COLOR_WARN"
    else
        echo " | sfimage=checkmark.circle"
    fi
fi
echo "---"

# Render Plugin Update Notification
if [[ $update_available -eq 1 ]]; then
    script_path="$(swiftbar_sq_escape "$0")"
    echo "Plugin Update Available | color=$COLOR_BLUE sfimage=arrow.down.circle.fill"
    echo "-- Update Now | bash='$script_path' param1=update_plugin terminal=true sfimage=arrow.triangle.2.circlepath"
    echo "---"
fi

# Show update details
if [[ $total -eq 0 ]]; then
    if [[ $update_available -eq 1 ]]; then
        echo "Local apps are up to date | color=$COLOR_INFO size=10"
    else
        echo "System is up to date | color=$COLOR_SUCCESS sfimage=checkmark.shield"
    fi
else
    if [[ $count_brew -gt 0 ]]; then
        echo "Homebrew ($count_brew): | color=$COLOR_INFO size=12 sfimage=shippingbox"
        echo "$list_brew" | while read -r line; do echo "$line | size=12 font=Monaco"; done
        echo "---"
    fi
    if [[ $count_mas -gt 0 ]]; then
        echo "App Store ($count_mas): | color=$COLOR_INFO size=12 sfimage=bag"
        # Hide IDs in the update list as well - aggressively
        echo "$list_mas" | sed -E 's/^[[:space:]]*[0-9]+[[:space:]]+//' | while read -r line; do echo "$line | size=12 font=Monaco"; done
    fi
fi

# Render statistics and history with submenus
echo "---"
echo "Monitored: $total_installed items | color=$COLOR_INFO size=12 sfimage=chart.bar.xaxis"

# Casks submenu with versions (Truncated to 20 chars)
echo "-- Apps (Brew Cask): $count_casks | color=$COLOR_INFO size=11 sfimage=square.stack.3d.up"
if [[ -n "$raw_casks" ]]; then
    # Format: "Token (Version)" - Version truncated if > 20 chars
    echo "$raw_casks" | awk '{
        ver=$2;
        if (length(ver) > 20) {
            ver = substr(ver, 1, 18) ".."
        }
        print $1 " (" ver ")"
    }' | while read -r item; do
        [[ -n "$item" ]] && echo "---- $item | size=11 font=Monaco trim=true"
    done
fi

# Formulae submenu with versions (Truncated)
echo "-- CLI Tools (Brew Formulae): $count_formulae | color=$COLOR_INFO size=11 sfimage=terminal"
if [[ -n "$raw_formulae" ]]; then
    # Format: "Token (Version)" - Version truncated
    echo "$raw_formulae" | awk '{
        ver=$2;
        if (length(ver) > 20) {
            ver = substr(ver, 1, 18) ".."
        }
        print $1 " (" ver ")"
    }' | while read -r item; do
        [[ -n "$item" ]] && echo "---- $item | size=11 font=Monaco trim=true"
    done
fi

# App Store submenu (ID removed aggressively)
echo "-- App Store: $count_mas_installed | color=$COLOR_INFO size=11 sfimage=bag"
if [[ -n "$installed_mas" ]]; then
    # Regex: Remove leading digits and ANY whitespace (space, tab, etc)
    echo "$installed_mas" | sed -E 's/^[[:space:]]*[0-9]+[[:space:]]+//' | while read -r item; do
        [[ -n "$item" ]] && echo "---- $item | size=11 font=Monaco trim=true"
    done
fi

echo "History: | color=$COLOR_INFO size=12 sfimage=clock.arrow.circlepath"
echo "-- Past 7 days: $updates_week updates | color=$COLOR_INFO size=11 sfimage=calendar"
echo "-- Past 30 days: $updates_month updates | color=$COLOR_INFO size=11 sfimage=calendar.badge.clock"

# Render the footer with operational buttons
echo "---"
script_path="${0// /\\ }"
if [[ $total -gt 0 ]]; then
    echo "Update All | bash='$script_path' param1=run terminal=true sfimage=arrow.triangle.2.circlepath.circle"
else
    echo "Update All | color=$COLOR_INFO sfimage=checkmark.circle"
fi
echo "Last check: $(date +%H:%M) | size=10 color=$COLOR_INFO"
echo "Refresh now | refresh=true sfimage=arrow.clockwise"

# Bottom Group: Preferences & About
echo "---"
echo "Preferences | sfimage=gearshape"
echo "-- Change Update Frequency | bash='$script_path' param1=change_interval terminal=false refresh=true sfimage=hourglass"
echo "-- Force Plugin Update | bash='$script_path' param1=update_plugin terminal=true sfimage=arrow.down.to.line.circle"

if [[ "$UPDATES_ENABLED" == "true" ]]; then
    echo "-- Disable Self-Update | bash='$script_path' param1=toggle_updates terminal=false refresh=true sfimage=xmark.circle"
else
    echo "-- Enable Self-Update | bash='$script_path' param1=toggle_updates terminal=false refresh=true sfimage=checkmark.circle"
fi
echo "About | bash='$script_path' param1=about_dialog terminal=false sfimage=info.circle"