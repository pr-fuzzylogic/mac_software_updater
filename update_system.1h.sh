#!/bin/zsh

# <bitbar.title>macOS Software Update & Migration Toolkit</bitbar.title>
# <bitbar.version>v1.3.4</bitbar.version>
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

# ==============================================================================
# 1. GLOBAL CONFIGURATION
# ==============================================================================
SCRIPT_FILE="${0:a}"
autoload -Uz is-at-least

# Set standard locale to avoid parsing errors with grep or sort on different system languages
export LC_ALL=C
umask 077

# Extract version from the first 5 lines of a file, defaults to "Unknown"
extract_version() {
    if [[ ! -f "$1" ]]; then echo "Unknown"; return 1; fi
    local ver=$(head -n 5 "$1" | grep "<bitbar.version>" | sed 's/.*<bitbar.version>\(.*\)<\/bitbar.version>.*/\1/' | tr -d 'v \n\r')
    echo "${ver:-Unknown}"
}

# Paths
APP_DIR="$HOME/Library/Application Support/MacSoftwareUpdater"
HISTORY_FILE="$APP_DIR/update_history.log"
CONFIG_FILE="$APP_DIR/settings.conf"
ETAG_FILE="$APP_DIR/.plugin_etag"
PENDING_FLAG="$APP_DIR/.plugin_update_pending"

# Ensure directories exist
mkdir -p "$APP_DIR"
chmod 700 "$APP_DIR" 2>/dev/null || true

# Load configuration
PREFERRED_TERMINAL="Terminal"  # Default to Apple Terminal
if [[ -f "$CONFIG_FILE" ]]; then
    source "$CONFIG_FILE" 2>/dev/null || true
fi

# Extract version dynamically from the first 5 lines of the script. Needed for User-Agent and About
VERSION=$(extract_version "$SCRIPT_FILE")

# Failover & Network Config
URL_PRIMARY_BASE="https://raw.githubusercontent.com/pr-fuzzylogic/mac_software_updater/main"
URL_BACKUP_BASE="https://codeberg.org/pr-fuzzylogic/mac_software_updater/raw/branch/main"
USER_AGENT="MacSoftwareUpdater/$VERSION"
PROJECT_URL="https://github.com/pr-fuzzylogic/mac_software_updater"
PROJECT_URL_CB="https://codeberg.org/pr-fuzzylogic/mac_software_updater"

# Colors (Light/Dark mode support)
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

# Set the path to Homebrew environment
if [[ -d "/opt/homebrew/bin" ]]; then
    export PATH="/opt/homebrew/bin:$PATH"
else
    export PATH="/usr/local/bin:$PATH"
fi


# ==============================================================================
# 2. PRE-FLIGHT CHECKS
# ==============================================================================

if ! command -v brew &> /dev/null; then
    if [[ "$1" == "run" ]]; then
        echo "❌ Error: Homebrew is not installed!"
        read -k1
        exit 1
    fi
    echo "⚠️ Brew Missing | color=red"
    echo "---"
    echo "Homebrew is strictly required | color=red"
    exit 0
fi

# ==============================================================================
# 3. HELPER FUNCTIONS
# ==============================================================================

# Escape strings for SwiftBar param usage
# Escapes single quotes in a string to ensure safe usage within SwiftBar parameters.
# This function replaces every single quote with a sequence that remains valid when wrapped in shell commands.
# Necessary for handling file paths or arguments containing special characters to prevent syntax breakage in the menu.
swiftbar_sq_escape() {
  print -r -- "${1//\'/\'\\\'\'}"
}

# Launch update script in the configured terminal app
launch_in_terminal() {
    local script_path="$1"
    local mode="${2:-all}" # Default to 'all' if not specified
    local terminal="${PREFERRED_TERMINAL:-Terminal}"

    # Build the command to execute
    local cmd="'$script_path' run $mode"

    case "$terminal" in
        "iTerm2")
            # iTerm2 using AppleScript
            if [[ -d "/Applications/iTerm.app" ]]; then
                osascript <<EOF
tell application "iTerm"
    activate
    create window with default profile command "$cmd"
end tell
EOF
            else
                # Fallback to Terminal if iTerm2 not found
                osascript -e "tell app \"Terminal\" to do script \"$cmd\""
            fi
            ;;
        "Warp")
            # Warp terminal
            if [[ -d "/Applications/Warp.app" ]]; then
                open -a Warp "$script_path" --args run
            else
                # Fallback to Terminal
                osascript -e "tell app \"Terminal\" to do script \"$cmd\""
            fi
            ;;
        "Alacritty")
            # Alacritty terminal
            if [[ -d "/Applications/Alacritty.app" ]]; then
                open -a Alacritty --args -e zsh -c "$cmd; exec zsh"
            else
                # Fallback to Terminal
                osascript -e "tell app \"Terminal\" to do script \"$cmd\""
            fi
            ;;
        *)
            # Default: Apple Terminal
            osascript -e "tell app \"Terminal\" to do script \"$cmd\""
            ;;
    esac
}

# Download with Failover (GitHub -> Codeberg)
# Usage: download_with_failover "filename.sh" "output_path"
download_with_failover() {
    local file_name="$1"
    local output_path="$2"

    # Try Primary (GitHub)
    # -f fails on HTTP errors (404), -L follows redirects, -s silent
    if curl -fLsS --proto '=https' --tlsv1.2 --connect-timeout 5 "$URL_PRIMARY_BASE/$file_name" -o "$output_path"; then
        echo "✅ GitHub available, file downloaded"
        return 0
    fi

    echo "⚠️ Primary source (Github) failed. Trying backup..."

    # Try Backup (Codeberg)
    if curl -fLsS --proto '=https' --tlsv1.2 --connect-timeout 8 "$URL_BACKUP_BASE/$file_name" -o "$output_path"; then
        echo "✅ Codeberg available, file downloaded"
        return 0
    fi
    echo "⚠️ Secondary source (Codeberg) failed too."
    return 1
}



# Calculate SHA256 Hash
calculate_hash() {
    if [[ ! -f "$1" ]]; then return 1; fi
    shasum -a 256 "$1" | awk '{print $1}'
}



# Manual application version check via iTunes Lookup API
# Redundant check: tries mdls first, falls back to defaults read (Info.plist)
check_manual_app_version() {
    local app_name="$1"
    local app_id="$2"
    local local_path="/Applications/$app_name.app"

    # Skip if application does not exist locally
    if [[ ! -d "$local_path" ]]; then return; fi

    # Try mdls (Spotlight metadata) as primary source
    local local_ver=$(mdls -name kMDItemVersion -raw "$local_path" 2>/dev/null)

    # Fallback to defaults read (Info.plist) if mdls is empty, null or fails
    if [[ -z "$local_ver" || "$local_ver" == "(null)" ]]; then
        local_ver=$(defaults read "$local_path/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null)
    fi

    # Final validation of local version string
    if [[ -z "$local_ver" || "$local_ver" == "(null)" ]]; then return; fi

    # Auto-detect system region (e.g., 'en_US' -> 'us', 'pl_PL' -> 'pl')
    # fallback to 'us' if detection fails
    local store_region=$(defaults read NSGlobalDomain AppleLocale 2>/dev/null | cut -d'_' -f2 | tr '[:upper:]' '[:lower:]')
    if [[ -z "$store_region" || ${#store_region} -ne 2 ]]; then
        store_region="us"
    fi

    # Retrieve remote version from iTunes Lookup API
    # curl fetches JSON with dynamic country code
    # plutil extracts 'results.0.version' safely
    local remote_ver=$(curl -sL "https://itunes.apple.com/lookup?id=$app_id&country=$store_region" \
        | plutil -extract results.0.version raw -o - - 2>/dev/null)

    # Validate if version was retrieved
    if [[ -z "$remote_ver" ]]; then return; fi

    # Compare versions using zsh is-at-least function
    if [[ "$local_ver" != "$remote_ver" ]]; then
        if ! is-at-least "$remote_ver" "$local_ver"; then
            echo "$app_name|$local_ver|$remote_ver|$app_id"
        fi
    fi
}

# ==============================================================================
# 4. MENU SUB FUNCTIONS
# ==============================================================================

check_for_updates_manual() {
    echo "Checking for updates..."

    local temp_headers="$(mktemp "${TMPDIR:-/tmp}/update_headers.XXXXXX")"
    local temp_body="$(mktemp "${TMPDIR:-/tmp}/update_body.XXXXXX")"

    trap 'rm -f "$temp_headers" "$temp_body"' EXIT

    local local_etag=""

    [[ -f "$ETAG_FILE" ]] && local_etag=$(cat "$ETAG_FILE")

    # Check ETag (Primary Source)
    local http_code=$(curl -s -o /dev/null -w "%{http_code}" -D "$temp_headers" \
        -H "If-None-Match: $local_etag" \
        -H "User-Agent: $USER_AGENT" \
        --connect-timeout 5 \
        "$URL_PRIMARY_BASE/update_system.1h.sh")

    if [[ "$http_code" == "304" ]]; then
        echo "✅ Status 304: No changes."
        rm -f "$PENDING_FLAG" "$temp_headers" "$temp_body"
        osascript -e "display notification \"Plugin is up to date.\" with title \"Mac Software Updater\""
        return 0
    fi

    # Download (Failover Logic)
    local source_verified="false"

    if [[ "$http_code" == "200" ]]; then
        if curl -s -o "$temp_body" "$URL_PRIMARY_BASE/update_system.1h.sh"; then
            grep -i "etag:" "$temp_headers" | awk '{print $2}' | tr -d '"\r\n' > "$ETAG_FILE"
            source_verified="true"
        fi
    fi

    if [[ "$source_verified" == "false" ]]; then
        echo "⚠️ Primary failed (HTTP $http_code). Downloading from Backup..."
        if curl -fLsS --connect-timeout 8 "$URL_BACKUP_BASE/update_system.1h.sh" -o "$temp_body"; then
            source_verified="true"
        fi
    fi

    if [[ "$source_verified" != "true" ]]; then
        echo "❌ Error: Update connection to GitHub and Codeberg failed."
        osascript -e "display notification \"Update connection to Github and Codeberg failed.\" with title \"Mac Software Updater\""
        #rm -f "$temp_headers" "$temp_body"
        return 1
    fi

    # Verify & Compare
    local local_ver="${VERSION//v/}"
    local remote_ver=$(extract_version "$temp_body")
    local local_hash=$(calculate_hash "$SCRIPT_FILE")
    local remote_hash=$(calculate_hash "$temp_body")

    echo "Verify: Local v$local_ver vs Remote v$remote_ver"

    if [[ -z "$local_ver" ]]; then
        echo "❌ Critical Error: Could not determine local version."
        #rm -f "$temp_body" "$temp_headers"
        return 1
    fi

    if [[ "$local_hash" == "$remote_hash" ]]; then
        echo "ℹ️ Files are identical."
        rm -f "$PENDING_FLAG"
        osascript -e "display notification \"You have the latest version (v$local_ver).\" with title \"Mac Software Updater\""

    elif [[ "$local_ver" == "$remote_ver" ]]; then
        echo "ℹ️ Version matches, but hashes not. Ignoring. Verify local and remote version, probably cosmetical changes..."
        rm -f "$PENDING_FLAG"
        osascript -e "display notification \"Up to date (v$local_ver).\" with title \"Mac Software Updater\""

    elif is-at-least "$remote_ver" "$local_ver"; then
        echo "⚠️ Remote version (v$remote_ver) is OLDER than local (v$local_ver)."
        rm -f "$PENDING_FLAG"
        osascript -e "display notification \"Server has older version (v$remote_ver).\" with title \"Mac Software Updater\" subtitle \"Keeping local v$local_ver.\""

    else
        echo "✅ Valid Update: v$remote_ver > v$local_ver"
        touch "$PENDING_FLAG"
        osascript -e "display notification \"New version v$remote_ver available!\" with title \"Mac Software Updater\" subtitle \"Click 'Update All' to install.\""
    fi
}


# ==============================================================================
# 5. ACTION HANDLING (ARGUMENTS)
# ==============================================================================

# Change Interval
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
        mv "$0" "$NEW_PATH" && chmod +x "$NEW_PATH"
        osascript -e "display notification \"Update frequency changed to $SELECTION.\" with title \"Mac Software Updater\""
        sleep 2
        open -g "swiftbar://refreshallplugins"
    else
         osascript -e "display notification \"Frequency is already set to $SELECTION.\" with title \"Mac Software Updater\""
    fi
    exit 0
fi

# Change Terminal App
if [[ "$1" == "change_terminal" ]]; then
    # Detect available terminals
    typeset -a available_terminals
    available_terminals=("Terminal")

    [[ -d "/Applications/iTerm.app" ]] && available_terminals+=("iTerm2")
    [[ -d "/Applications/Warp.app" ]] && available_terminals+=("Warp")
    [[ -d "/Applications/Alacritty.app" ]] && available_terminals+=("Alacritty")

    # Build AppleScript list
    terminal_list=$(printf '"%s", ' "${available_terminals[@]}" | sed 's/, $//')

    # Show selection dialog with current selection as default
    CURRENT="${PREFERRED_TERMINAL:-Terminal}"
    SELECTION=$(osascript -e "choose from list {$terminal_list} with title \"Terminal App Selection\" with prompt \"Select your preferred terminal for running updates:\" default items \"$CURRENT\"")

    if [[ "$SELECTION" == "false" ]]; then
        exit 0
    fi

    # Update config file
    if [[ ! -f "$CONFIG_FILE" ]]; then
        mkdir -p "$APP_DIR"
        cat > "$CONFIG_FILE" << EOF
# Mac Software Updater Configuration
# Generated on $(date)

# Terminal app to use for running updates
# Valid values: Terminal, iTerm2, Warp, Alacritty
PREFERRED_TERMINAL="$SELECTION"
EOF
        chmod 600 "$CONFIG_FILE" 2>/dev/null || true
    else
        # Update existing config
        if grep -q "^PREFERRED_TERMINAL=" "$CONFIG_FILE" 2>/dev/null; then
            sed -i '' "s/^PREFERRED_TERMINAL=.*/PREFERRED_TERMINAL=\"$SELECTION\"/" "$CONFIG_FILE"
        else
            echo "PREFERRED_TERMINAL=\"$SELECTION\"" >> "$CONFIG_FILE"
        fi
    fi

    if [[ "$SELECTION" == "$CURRENT" ]]; then
        osascript -e "display notification \"Terminal is already set to $SELECTION.\" with title \"Mac Software Updater\""
    else
        osascript -e "display notification \"Terminal changed to $SELECTION.\" with title \"Mac Software Updater\""
    fi

    exit 0
fi


# About Dialog
if [[ "$1" == "about_dialog" ]]; then
    BUTTON=$(osascript -e 'on run {ver}' -e 'tell application "System Events"' -e 'activate' -e 'set myResult to display dialog "Mac Software Updater" & return & "Version " & ver & return & return & "An automated toolkit to monitor and update Homebrew & App Store applications." & return & return & "Created by: pr-fuzzylogic" with title "About" buttons {"Visit Codeberg", "Visit GitHub", "Close"} default button "Close" cancel button "Close" with icon note' -e 'return button returned of myResult' -e 'end tell' -e 'end run' -- "$VERSION")
    if [[ "$BUTTON" == "Visit GitHub" ]]; then
        open "$PROJECT_URL"
    elif [[ "$BUTTON" == "Visit Codeberg" ]]; then
        open "$PROJECT_URL_CB"
    fi
    exit 0
fi

# Launch Update in Terminal
if [[ "$1" == "launch_update" ]]; then
    launch_in_terminal "$0" "$2"
    exit 0
fi

# Manual Update Check
if [[ "$1" == "check_updates" ]]; then
    check_for_updates_manual
    open -g "swiftbar://refreshplugin?name=$(basename "$0")"
    exit 0
fi

# Main Update Execution (Run)
if [[ "$1" == "run" ]]; then
    MODE="${2:-all}"
    
    set -e
    set -o pipefail

    # --- PLUGIN UPDATE SECTION ---
    if [[ "$MODE" == "all" || "$MODE" == "plugin" ]]; then
        if [[ -f "$PENDING_FLAG" ]]; then
            echo "🚀 Updating toolkit components..."
            download_with_failover "setup_mac.sh" "$APP_DIR/setup_mac.sh" && chmod +x "$APP_DIR/setup_mac.sh"
            download_with_failover "uninstall.sh" "$APP_DIR/uninstall.sh" && chmod +x "$APP_DIR/uninstall.sh"

            TEMP_TARGET="$(mktemp "${TMPDIR:-/tmp}/update_system.selfupdate.XXXXXX")"

            trap 'rm -f "$TEMP_TARGET"' EXIT

            if download_with_failover "update_system.1h.sh" "$TEMP_TARGET"; then
                mv "$TEMP_TARGET" "$0" && chmod +x "$0"
                rm -f "$PENDING_FLAG"
                echo "✅ Toolkit updated successfully."
                
                # If only updating plugin, refresh and exit
                if [[ "$MODE" == "plugin" ]]; then
                    echo "🔄 Refreshing SwiftBar..."
                    open -g "swiftbar://refreshplugin?name=$(basename "$0")"
                    echo "Done! Press any key to close."
                    read -k1
                    exit 0
                else
                    echo "➡️ Proceeding with system apps..."
                fi
            fi
        elif [[ "$MODE" == "plugin" ]]; then
            echo "ℹ️ No pending plugin updates found."
            read -k1
            exit 0
        fi
    fi

    # --- SYSTEM UPDATE SECTION ---
    if [[ "$MODE" == "all" || "$MODE" == "system" ]]; then
        echo "🚀 Starting System Update (Homebrew & MAS)..."
        echo "---------------------------"

        echo "📦 Updating Homebrew Database..."
        brew update

        echo "🔍 Calculating pending updates..."
        real_brew_count=$(brew outdated --greedy | grep -v "latest) != latest" | grep -v "^font-" | grep -c -- '[^[:space:]]' || true)

        real_mas_count=0
        if command -v mas &> /dev/null; then
            real_mas_count=$(mas outdated | grep -E '^[[:space:]]*[0-9]+' | wc -l | tr -d ' ' || true)
        fi

        updates_count=$((real_brew_count + real_mas_count))

        echo "🍺 Upgrading Homebrew Formulae and Casks  ($real_brew_count pending)..."
        brew upgrade --greedy
        echo "🧹 Cleaning up..."
        brew cleanup --prune=all

        if command -v mas &> /dev/null; then
            echo "🍎 Updating App Store Applications ($real_mas_count pending)..."
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
    fi

    echo "---------------------------"
    echo "✅ Update Complete!"
    echo "🔄 Refreshing SwiftBar..."
    open -g "swiftbar://refreshplugin?name=$(basename "$0")"
    echo "Done! Press any key to close."
    read -k1
    exit
fi

# ==============================================================================
# 6. BACKGROUND CHECKS & STATS
# ==============================================================================

# Check pending flag
update_available=0
[[ -f "$PENDING_FLAG" ]] && update_available=1

# Check Homebrew for updates
list_brew=$(brew outdated --verbose --greedy | grep -v "latest) != latest" | grep -v "^font-")
count_brew=$(echo -n "$list_brew" | grep -c -- '[^[:space:]]' || true)

# Check App Store for updates
list_mas=""
count_mas=0
if command -v mas &> /dev/null; then
    list_mas=$(mas outdated)
    count_mas=$(echo "$list_mas" | grep -E '^[[:space:]]*[0-9]+' | wc -l | tr -d ' ')
fi

# MANUAL CHECK FOR GHOST APPS
# List of applications often missed by mas CLI
typeset -A ghost_apps
ghost_apps=(
    # --- Legacy / Standard Versions ---
    "Numbers"                         "409203825"
    "Pages"                           "409201541"
    "Keynote"                         "409183694"
    "iMovie"                          "408981434"
    "GarageBand"                      "682658836"
    "Xcode"                           "497799835"
    "Final Cut Pro"                   "424389933"
    "Logic Pro"                       "634148309"
    "Motion"                          "434290957"
    "Compressor"                      "424390742"
    "MainStage"                       "634159523"

    # --- NEW: Creator Studio Versions (Released Jan 2026) ---
    "Keynote Creator Studio"          "647829103"
    "Pages Creator Studio"            "647829104"
    "Numbers Creator Studio"          "647829105"
    "Final Cut Pro Creator Studio"    "424389933" # Shares ID but uses separate binary
    "Logic Pro Creator Studio"        "634148309" # Shares ID but uses separate binary
)

manual_updates_list=""
count_manual=0

for app_name in ${(k)ghost_apps}; do
    app_id=$ghost_apps[$app_name]

    # Prevent duplicate checks if mas CLI already detected the update
    if echo "$list_mas" | grep -q "$app_id"; then
        continue
    fi

    result=$(check_manual_app_version "$app_name" "$app_id")
    if [[ -n "$result" ]]; then
        manual_updates_list+="$result"$'\n'
        ((count_manual++))
    fi
done

# Aggregate total updates count
total=$((count_brew + count_mas + count_manual))

# Collect installed stats
# Casks
raw_casks=$(brew list --cask --versions)
count_casks=$(echo "$raw_casks" | grep -c '[^[:space:]]' || echo 0)

# Formulae
raw_formulae=$(brew list --formula --versions)
count_formulae=$(echo "$raw_formulae" | grep -c '[^[:space:]]' || echo 0)

# MAS (App Store)
installed_mas=""
count_mas_installed=0
if command -v mas &> /dev/null; then
    installed_mas=$(mas list)
    count_mas_installed=$(echo "$installed_mas" | wc -l | tr -d ' ')
fi
total_installed=$((count_casks + count_formulae + count_mas_installed))

# History Stats
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

# ==============================================================================
# 7. UI RENDERING
# ==============================================================================

# Prepare script path for buttons
script_path="$(swiftbar_sq_escape "$0")"

# Main Bar Icon
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
    echo "Plugin Update Available (Click to Install) | color=$COLOR_BLUE sfimage=arrow.down.circle.fill bash='$script_path' param1=launch_update param2=plugin terminal=false refresh=true"
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
    # System Updates Header (Clickable)
    if [[ $((count_brew + count_mas)) -gt 0 ]]; then
        echo "Update System Apps ($((count_brew + count_mas))) | color=$COLOR_INFO size=12 sfimage=arrow.triangle.2.circlepath bash='$script_path' param1=launch_update param2=system terminal=false refresh=true"
    fi

    if [[ $count_brew -gt 0 ]]; then
        echo "Homebrew ($count_brew): | color=$COLOR_INFO size=12 sfimage=shippingbox"
        echo "$list_brew" | while read -r line; do echo "$line | size=12 font=Monaco"; done
        echo "---"
    fi

    if [[ $count_mas -gt 0 ]]; then
        echo "App Store ($count_mas): | color=$COLOR_INFO size=12 sfimage=bag"
        # Hide IDs and clean up extra spaces for consistent styling
        echo "$list_mas" | sed -E 's/^[[:space:]]*[0-9]+[[:space:]]+//' | while read -r line; do
            # Clean up potential extra spaces between name and version
            line=$(echo "$line" | sed -E 's/[[:space:]]{2,}/ /g')
            echo "$line | size=12 font=Monaco"
        done
    fi

    # Manual updates for apps often missed by mas CLI (Ghost Apps)
    if [[ $count_manual -gt 0 ]]; then
        echo "Manual Update Required ($count_manual): | color=$COLOR_WARN size=12 sfimage=exclamationmark.triangle"
        echo "$manual_updates_list" | while IFS='|' read -r name local remote id; do
            if [[ -n "$name" ]]; then
                # Link directs to App Store or web, as these are manual
                echo "Update $name ($local -> $remote) | href='https://apps.apple.com/app/id$id' size=12 font=Monaco color=$COLOR_WARN"
            fi
        done
        echo "---"
    fi

fi



# Statistics Submenu
echo "---"
echo "Monitored: $total_installed items | color=$COLOR_INFO size=12 sfimage=chart.bar.xaxis"

# Casks submenu with versions (Truncated to 20 chars)
# Processes installed Homebrew Casks into a formatted SwiftBar submenu
# Captures full version strings including spaces by re-evaluating the current line after token extraction
# Generates interactive menu items with direct links to Homebrew formula pages using safe quote injection
# Enforces a 20 character limit on version strings to maintain menu readability and consistent layout
echo "-- Apps (Brew Cask): $count_casks | color=$COLOR_INFO size=11 sfimage=square.stack.3d.up"
if [[ -n "$raw_casks" ]]; then
    echo "$raw_casks" | awk -v q="'" '{
        token=$1;
        $1="";
        ver=$0;
        gsub(/^[ \t]+|[ \t]+$/, "", ver); # Remove redundant spaces
        if (length(ver) > 20) ver = substr(ver, 1, 18) "..";
        # Safe link in AWK
        print "---- " token " (" ver ") | href=" q "https://formulae.brew.sh/cask/" token q " size=11 font=Monaco trim=true"
    }'
fi

# Brew Formulae
# Formats installed Homebrew Formulae into a SwiftBar submenu with interactive links.
# Handles multi-part version strings by clearing the first field and capturing remaining text.
# Links directly to the Homebrew formula documentation using the package token.
# Limits version length to 20 characters for UI consistency.
echo "-- CLI Tools (Brew Formulae): $count_formulae | color=$COLOR_INFO size=11 sfimage=terminal"
if [[ -n "$raw_formulae" ]]; then
    echo "$raw_formulae" | awk -v q="'" '{
        token=$1;
        $1="";
        ver=$0;
        gsub(/^[ \t]+|[ \t]+$/, "", ver);
        if (length(ver) > 20) ver = substr(ver, 1, 18) "..";
        print "---- " token " (" ver ") | href=" q "https://formulae.brew.sh/formula/" token q " size=11 font=Monaco trim=true"
    }'
fi

# App Store
# Processes installed App Store applications into a formatted SwiftBar submenu with direct store links
# Extracts numeric application identifiers to construct web URLs for each entry
# Cleans application names by removing leading identifiers and trimming whitespace for consistent display
# Ensures proper parameter escaping for interactive menu items using standard web link formats
echo "-- App Store: $count_mas_installed | color=$COLOR_INFO size=11 sfimage=bag"
if [[ -n "$installed_mas" ]]; then
    echo "$installed_mas" | awk -v q="'" '{
        id=$1;
        $1="";
        name=$0;
        gsub(/^[ \t]+|[ \t]+$/, "", name); # Remove leading space after ID extraction
        # Build link: https://apps.apple.com/app/id<NUMER>
        print "---- " name " | href=" q "https://apps.apple.com/app/id" id q " size=11 font=Monaco trim=true"
    }'
fi

echo "History: | color=$COLOR_INFO size=12 sfimage=clock.arrow.circlepath"
echo "-- Past 7 days: $updates_week updates | color=$COLOR_INFO size=11 sfimage=calendar"
echo "-- Past 30 days: $updates_month updates | color=$COLOR_INFO size=11 sfimage=calendar.badge.clock"

# Footer & Controls
echo "---"
if [[ $total -gt 0 || $update_available -eq 1 ]]; then
    echo "Update Everything | bash='$script_path' param1=launch_update param2=all terminal=false refresh=true sfimage=arrow.triangle.2.circlepath.circle"
else
    echo "Update All | color=$COLOR_INFO sfimage=checkmark.circle"
fi
echo "Last check: $(date +%H:%M) | size=10 color=$COLOR_INFO"
echo "Refresh now | refresh=true sfimage=arrow.clockwise"

echo "---"
echo "Preferences | sfimage=gearshape"
echo "-- Change Update Frequency | bash='$script_path' param1=change_interval terminal=false refresh=true sfimage=hourglass"
echo "-- Change Terminal App | bash='$script_path' param1=change_terminal terminal=false refresh=false sfimage=terminal"
echo "-- Check for Plugin Update | bash='$script_path' param1=check_updates terminal=false refresh=true sfimage=arrow.clockwise.icloud"
echo "Quit SwiftBar | bash='osascript' param1=-e param2='quit app \"SwiftBar\"' terminal=false sfimage=xmark.circle"
echo "About | bash='$script_path' param1=about_dialog terminal=false sfimage=info.circle"
