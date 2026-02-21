#!/bin/zsh

# <bitbar.title>macOS Software Update & Migration Toolkit</bitbar.title>
# <bitbar.version>v1.4.0.6</bitbar.version>
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
zmodload zsh/datetime

# Set standard locale to avoid parsing errors with grep or sort on different system languages
export LC_ALL=C
# Suppress mas CLI Spotlight auto-indexing warning
export MAS_NO_AUTO_INDEX=1
umask 077

# Extract version from the first 5 lines of a file, defaults to "Unknown"
extract_version() {
    if [[ ! -f "$1" ]]; then echo "Unknown"; return 1; fi
    local ver=$(head -n 5 "$1" | grep --color=never "<bitbar.version>" | sed 's/.*<bitbar.version>\(.*\)<\/bitbar.version>.*/\1/' | tr -d 'v \n\r')
    echo "${ver:-Unknown}"
}

# Paths
APP_DIR="$HOME/Library/Application Support/MacSoftwareUpdater"
HISTORY_FILE="$APP_DIR/update_history.log"
CONFIG_FILE="$APP_DIR/settings.conf"
ETAG_FILE="$APP_DIR/.plugin_etag"
PENDING_FLAG="$APP_DIR/.plugin_update_pending"
IGNORED_FILE="$APP_DIR/ignored_apps.conf"

# Ensure directories exist
mkdir -p "$APP_DIR"
chmod 700 "$APP_DIR" 2>/dev/null || true

typeset -a CONFIG_WARNINGS

add_config_warning() {
    local warning="$1"
    (( ${CONFIG_WARNINGS[(Ie)$warning]} == 0 )) && CONFIG_WARNINGS+=("$warning")
}

# Validate and load configuration safely
load_config_safely() {
    [[ ! -f "$CONFIG_FILE" ]] && return 0

    local raw_line trimmed_line key value line_no=0

    while IFS= read -r raw_line || [[ -n "$raw_line" ]]; do
        ((line_no++))
        trimmed_line="${raw_line#"${raw_line%%[![:space:]]*}"}"
        trimmed_line="${trimmed_line%"${trimmed_line##*[![:space:]]}"}"

        [[ -z "$trimmed_line" || "$trimmed_line" == \#* ]] && continue

        if ! printf '%s\n' "$trimmed_line" | grep -qE '^[A-Z_]+="[^"]*"$'; then
            add_config_warning "Invalid config syntax on line $line_no."
            continue
        fi

        key="${trimmed_line%%=*}"
        value="${trimmed_line#*=}"
        value="${value#\"}"
        value="${value%\"}"

        case "$key" in
            "PREFERRED_TERMINAL")
                case "$value" in
                    "Terminal"|"iTerm2"|"Warp"|"Alacritty"|"Ghostty")
                        PREFERRED_TERMINAL="$value"
                        ;;
                    *)
                        add_config_warning "Invalid PREFERRED_TERMINAL value. Using default."
                        ;;
                esac
                ;;
            "MAS_ENABLED")
                case "$value" in
                    "0"|"1")
                        MAS_ENABLED="$value"
                        ;;
                    *)
                        add_config_warning "Invalid MAS_ENABLED value. Using default."
                        ;;
                esac
                ;;
            "UPDATE_BRANCH")
                if printf '%s\n' "$value" | grep -qE '^[A-Za-z0-9._/-]+$'; then
                    UPDATE_BRANCH="$value"
                else
                    add_config_warning "Invalid UPDATE_BRANCH value. Using default."
                fi
                ;;
            "AUTOSTART")
                AUTOSTART="$value"
                ;;
            *)
                add_config_warning "Unknown config key '$key' ignored."
                ;;
        esac
    done < "$CONFIG_FILE"
}

# Load configuration
PREFERRED_TERMINAL="Terminal"  # Default to Apple Terminal
MAS_ENABLED="1"
UPDATE_BRANCH="main"
load_config_safely

# Extract version dynamically from the first 5 lines of the script. Needed for User-Agent and About
VERSION=$(extract_version "$SCRIPT_FILE")

# Failover & Network Config
URL_PRIMARY_BASE="https://raw.githubusercontent.com/pr-fuzzylogic/mac_software_updater/$UPDATE_BRANCH"
URL_BACKUP_BASE="https://codeberg.org/pr-fuzzylogic/mac_software_updater/raw/branch/$UPDATE_BRANCH"
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

typeset -A IGNORED_APPS_MAP

# Load to memory ignored apps
load_ignored_cache() {
    IGNORED_APPS_MAP=()
    if [[ -f "$IGNORED_FILE" ]]; then
        # Read type, id AND name
        while IFS='|' read -r type id name || [[ -n "$type" ]]; do
            # Aggressive cleaning for type keeps only alphanumeric characters
            # Removes BOM spaces non breaking spaces tabs
            local clean_type=$(echo "$type" | tr -cd '[:alnum:]')

            # Aggressive cleaning for ID keeps only digits
            local clean_id=$(echo "$id" | tr -cd '0-9')

            # Skip invalid lines
            [[ -z "$clean_type" || -z "$clean_id" ]] && continue

            # Key is type pipe id
            local clean_key="${clean_type}|${clean_id}"

            # Value in the map is now the NAME stripped of newlines
            local clean_name=$(echo "${name:-$id}" | tr -d '\r\n')

            IGNORED_APPS_MAP[$clean_key]="$clean_name"
        done < "$IGNORED_FILE"
    fi
}

# Check if an app is ignored (cask or mas)
# Usage: is_ignored "type" "identifier"
is_ignored() {
    # Check if value exists for key using string test instead of arithmetic
    [[ -n "${IGNORED_APPS_MAP[$1|$2]}" ]]
}

load_ignored_cache

# Add app to ignore list (Supports: type|id|name)
add_ignored() {
    local type="$1" id="$2" name="${3:-$id}"
    # Remove pipes from name to prevent parsing errors
    name="${name//|/}"
    if ! is_ignored "$type" "$id"; then
        echo "${type}|${id}|${name}" >> "$IGNORED_FILE"
    fi
}

# Remove app from ignore list (Matches type|id ONLY)
remove_ignored() {
    local type="$1"
    local id="$2"
    # Delete line starting with type|id followed by pipe or EOL
    # This ensures strict matching of ID regardless of whether a name suffix exists
    [[ -f "$IGNORED_FILE" ]] && sed -i '' -E "/^${type}\|${id}(\||$)/d" "$IGNORED_FILE"
}

# Launch update script in the configured terminal app
launch_in_terminal() {
    local script_path="$1"
    shift
    local args=("${@:-all}")
    local terminal="${PREFERRED_TERMINAL:-Terminal}"

    # Build the command: quote script path + run + quote EACH arg separately
    # Utilize single quotes formatting to prevent AppleScript escape sequence failures
    local cmd="${(qq)script_path} run ${(@qq)args}"

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
                osascript -e "tell app \"Terminal\" to activate" -e "tell app \"Terminal\" to do script \"$cmd\""
            fi
            ;;
        "Warp")
            # Warp terminal
            if [[ -d "/Applications/Warp.app" ]]; then
                # Force focus first
                osascript -e 'tell application "Warp" to activate'
                # Warp accepts args naturally, but constructing a clean command string is safer
                open -a Warp "$script_path" --args run "${args[@]}"
            else
                # Fallback
                osascript -e "tell app \"Terminal\" to activate" -e "tell app \"Terminal\" to do script \"$cmd\""
            fi
            ;;
        "Alacritty")
            # Alacritty terminal
            if [[ -d "/Applications/Alacritty.app" ]]; then
                # Force focus first
                osascript -e 'tell application "Alacritty" to activate'
                open -a Alacritty --args -e zsh -c "$cmd; exec zsh"
            else
                # Fallback to Terminal
                osascript -e "tell app \"Terminal\" to activate" -e "tell app \"Terminal\" to do script \"$cmd\""
            fi
            ;;
        "Ghostty")
            # Ghostty terminal
            if [[ -d "/Applications/Ghostty.app" ]]; then
                # Force focus first
                osascript -e 'tell application "Ghostty" to activate'
                # Use zsh -c to ensure the quoted command string is parsed correctly
                open -na Ghostty --args -e zsh -c "$cmd; exec zsh"
            else
                # Fallback to Terminal
                osascript -e "tell app \"Terminal\" to activate" -e "tell app \"Terminal\" to do script \"$cmd\""
            fi
            ;;
        *)
            # Default: Apple Terminal
            # Force focus first
            osascript -e "tell app \"Terminal\" to activate" -e "tell app \"Terminal\" to do script \"$cmd\""
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

# Truncate version string to a given limit (default 10) for menu readability
truncate_ver() {
    local ver="$1"
    local limit="${2:-10}"
    if [[ ${#ver} -gt $limit ]]; then
        # Subtract 2 for the dots
        echo "${ver:0:$((limit-2))}.."
    else
        echo "$ver"
    fi
}

# Clean version string by removing commit hashes (40-char hex after comma)
clean_version() {
    local ver="$1"
    if [[ "$ver" == *,* ]]; then
        local suffix="${ver#*,}"
        if [[ ${#suffix} -eq 40 && "$suffix" =~ ^[0-9a-fA-F]+$ ]]; then
            echo "${ver%%,*}"
            return
        fi
    fi
    echo "$ver"
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
    local remote_ver=$(curl -sL --max-time 3 "https://itunes.apple.com/lookup?id=$app_id&country=$store_region" \
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



# Helper: Clean App Store Name (Removes leading ID/whitespace and trailing version info)
clean_mas_name() {
    # 1. Remove leading ID (digits + space), handling potential leading whitespace (^[[:space:]]*)
    # 2. Remove trailing version info (last parenthesis group)
    # 3. Trim whitespace via xargs
    echo "$1" | sed -E 's/^[[:space:]]*[0-9]+[[:space:]]+//' | sed -E 's/[[:space:]]*\([^)]+\)$//' | xargs
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

    DIR=$(dirname "$SCRIPT_FILE")
    # Clean current name and apply new suffix
    NEW_PATH="$DIR/update_system.${NEW_SUFFIX}.sh"

    if [[ "$SCRIPT_FILE" != "$NEW_PATH" ]]; then
        mv "$SCRIPT_FILE" "$NEW_PATH" && chmod +x "$NEW_PATH"
        osascript -e "display notification \"Update frequency changed to $SELECTION.\" with title \"Mac Software Updater\""
        sleep 2
        open -g "swiftbar://refreshallplugins"
    else
         osascript -e "display notification \"Frequency is already set to $SELECTION.\" with title \"Mac Software Updater\""
    fi
    exit 0
fi

# Toggle Autostart (SwiftBar)
if [[ "$1" == "toggle_autostart" ]]; then
    # Verify actual system state via AppleScript
    if osascript -e 'tell application "System Events" to get the name of every login item' 2>/dev/null | grep -q "SwiftBar"; then
        osascript -e 'tell application "System Events" to delete login item "SwiftBar"'
        NEW_STATE="0"
        MSG="SwiftBar removed from Login Items."
    else
        osascript -e 'tell application "System Events" to make login item at end with properties {path:"/Applications/SwiftBar.app", hidden:false}' >/dev/null 2>&1
        NEW_STATE="1"
        MSG="SwiftBar added to Login Items."
    fi

    # Update configuration file to reflect new state
    if [[ ! -f "$CONFIG_FILE" ]]; then
        mkdir -p "$APP_DIR"
        echo "AUTOSTART=\"$NEW_STATE\"" > "$CONFIG_FILE"
    else
        if grep -q "^AUTOSTART=" "$CONFIG_FILE" 2>/dev/null; then
            sed -i '' "s/^AUTOSTART=.*/AUTOSTART=\"$NEW_STATE\"/" "$CONFIG_FILE"
        else
            echo "AUTOSTART=\"$NEW_STATE\"" >> "$CONFIG_FILE"
        fi
    fi

    osascript -e "display notification \"$MSG\" with title \"Mac Software Updater\""
    open -g "swiftbar://refreshplugin?name=$(basename "$SCRIPT_FILE")"
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
    [[ -d "/Applications/Ghostty.app" ]] && available_terminals+=("Ghostty")

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
# Valid values: Terminal, iTerm2, Warp, Alacritty, Ghostty
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

# Change Update Branch (Stable/Beta)
if [[ "$1" == "change_branch" ]]; then
    # Detect current state for default selection
    CURRENT="${UPDATE_BRANCH:-main}"
    DEFAULT_ITEM="Stable (Main)"
    if [[ "$CURRENT" == "develop" ]]; then
        DEFAULT_ITEM="Beta (Develop)"
    fi

    # Show selection dialog
    SELECTION=$(osascript -e "choose from list {\"Stable (Main)\", \"Beta (Develop)\"} with title \"Update Channel\" with prompt \"Select update source:\" default items \"$DEFAULT_ITEM\"")

    if [[ "$SELECTION" == "false" ]]; then
        exit 0
    fi

    # Map selection to branch name
    NEW_BRANCH="main"
    if [[ "$SELECTION" == "Beta (Develop)" ]]; then
        NEW_BRANCH="develop"
    fi

    # Check if change is actually needed
    if [[ "$NEW_BRANCH" == "$CURRENT" ]]; then
        osascript -e "display notification \"Already on $SELECTION channel.\" with title \"Mac Software Updater\""
        exit 0
    fi

    echo "⚙️ Switching to: $SELECTION..."

    # Update Configuration File
    if [[ ! -f "$CONFIG_FILE" ]]; then
        mkdir -p "$APP_DIR"
        echo "UPDATE_BRANCH=\"$NEW_BRANCH\"" > "$CONFIG_FILE"
    else
        if grep -q "^UPDATE_BRANCH=" "$CONFIG_FILE" 2>/dev/null; then
            sed -i '' "s/^UPDATE_BRANCH=.*/UPDATE_BRANCH=\"$NEW_BRANCH\"/" "$CONFIG_FILE"
        else
            echo "UPDATE_BRANCH=\"$NEW_BRANCH\"" >> "$CONFIG_FILE"
        fi
    fi

    # Update URLs in memory immediately
    URL_PRIMARY_BASE="https://raw.githubusercontent.com/pr-fuzzylogic/mac_software_updater/$NEW_BRANCH"
    URL_BACKUP_BASE="https://codeberg.org/pr-fuzzylogic/mac_software_updater/raw/branch/$NEW_BRANCH"

    # Force Download and Overwrite
    TEMP_TARGET="$(mktemp "${TMPDIR:-/tmp}/update_system.branch_switch.XXXXXX")"
    trap 'rm -f "$TEMP_TARGET"' EXIT

    echo "⬇️ Downloading version from $NEW_BRANCH..."

    if download_with_failover "update_system.1h.sh" "$TEMP_TARGET"; then
        if grep -q "bitbar.title" "$TEMP_TARGET"; then
            mv "$TEMP_TARGET" "$SCRIPT_FILE" && chmod +x "$SCRIPT_FILE"

            # Clean up flags
            rm -f "$PENDING_FLAG"
            rm -f "$ETAG_FILE"

            osascript -e "display notification \"Switched to $SELECTION channel.\" with title \"Mac Software Updater\""
            open -g "swiftbar://refreshplugin?name=$(basename "$SCRIPT_FILE")"
        else
            echo "❌ Error: Downloaded file corrupt."
            osascript -e "display notification \"Error: Downloaded file corrupt.\" with title \"Mac Software Updater\""
        fi
    else
        echo "❌ Error: Could not download from $NEW_BRANCH."
        osascript -e "display notification \"Connection failed. Reverting config.\" with title \"Mac Software Updater\""
        sed -i '' "s/^UPDATE_BRANCH=.*/UPDATE_BRANCH=\"$CURRENT\"/" "$CONFIG_FILE"
    fi
    exit 0
fi

# Update Single App (launches in user's configured terminal via launch_in_terminal)
if [[ "$1" == "update_app" ]]; then
    load_config_safely
    launch_in_terminal "$SCRIPT_FILE" "single" "$2" "$3" "$4" "$5" "$6"
    exit 0
fi

# Ignore App
if [[ "$1" == "ignore_app" ]]; then
    type="$2"  # brew, cask, or mas
    id="$3"    # package name or app ID
    name="${4:-$id}"  # display name (fallback to id)

    case "$type" in
        "brew")
            brew pin "$id" 2>/dev/null
            ;;
        "cask"|"mas")
            add_ignored "$type" "$id" "$name"
            ;;
    esac
    osascript -e "display dialog \"$name has been ignored.\" & return & return & \"It will no longer appear in the updates list.\" buttons {\"OK\"} default button \"OK\" with title \"App Ignored\" with icon note giving up after 5"
    open -g "swiftbar://refreshplugin?name=$(basename "$SCRIPT_FILE")"
    exit 0
fi

# Unignore App
if [[ "$1" == "unignore_app" ]]; then
    type="$2"
    id="$3"
    name="${4:-$id}"  # display name (fallback to id)

    case "$type" in
        "brew")
            brew unpin "$id" 2>/dev/null
            ;;
        "cask"|"mas")
            remove_ignored "$type" "$id"
            ;;
    esac
    osascript -e "display dialog \"$name has been restored.\" & return & return & \"It will now appear in the updates list.\" buttons {\"OK\"} default button \"OK\" with title \"App Restored\" with icon note giving up after 5"
    open -g "swiftbar://refreshplugin?name=$(basename "$SCRIPT_FILE")"
    exit 0
fi

# Toggle App Store Updates
if [[ "$1" == "toggle_mas" ]]; then
    # Force reload config
    load_config_safely

    CURRENT_STATE="${MAS_ENABLED:-1}"

    if [[ "$CURRENT_STATE" == "1" ]]; then
        NEW_STATE="0"
        MSG="App Store updates DISABLED."
    else
        NEW_STATE="1"
        MSG="App Store updates ENABLED."
    fi

    # Update Config File
    if [[ ! -f "$CONFIG_FILE" ]]; then
        mkdir -p "$APP_DIR"
        echo "MAS_ENABLED=\"$NEW_STATE\"" > "$CONFIG_FILE"
    else
        if grep -q "^MAS_ENABLED=" "$CONFIG_FILE" 2>/dev/null; then
            sed -i '' "s/^MAS_ENABLED=.*/MAS_ENABLED=\"$NEW_STATE\"/" "$CONFIG_FILE"
        else
            echo "MAS_ENABLED=\"$NEW_STATE\"" >> "$CONFIG_FILE"
        fi
    fi

    osascript -e "display dialog \"$MSG\" & return & return & \"The plugin will now refresh to reflect this change.\" buttons {\"OK\"} default button \"OK\" with title \"App Store updates\" with icon note giving up after 5"
    open -g "swiftbar://refreshplugin?name=$(basename "$SCRIPT_FILE")"
    exit 0
fi

# About Dialog
if [[ "$1" == "about_dialog" ]]; then
    BUTTON=$(osascript -e 'on run {ver}' -e 'tell application "System Events"' -e 'activate' -e 'set myResult to display dialog "Mac Software Updater" & return & "Version " & ver & return & return & "An automated toolkit to monitor and update Homebrew & App Store applications." & return & return & "Created by: pr-fuzzylogic" with title "About" buttons {"Visit Codeberg", "Visit GitHub", "Close"} default button "Close" cancel button "Close" with icon path to resource "Terminal.icns" in bundle (path to application "Terminal")' -e 'return button returned of myResult' -e 'end tell' -e 'end run' -- "$VERSION")
    if [[ "$BUTTON" == "Visit GitHub" ]]; then
        open "$PROJECT_URL"
    elif [[ "$BUTTON" == "Visit Codeberg" ]]; then
        open "$PROJECT_URL_CB"
    fi
    exit 0
fi

# Launch Update in Terminal
if [[ "$1" == "launch_update" ]]; then
    # Force reload config to ensure latest terminal choice is used
    load_config_safely
    launch_in_terminal "$SCRIPT_FILE" "$2"
    exit 0
fi

# Manual Update Check
if [[ "$1" == "check_updates" ]]; then
    check_for_updates_manual
    open -g "swiftbar://refreshplugin?name=$(basename "$SCRIPT_FILE")"
    exit 0
fi

# Main Update Execution (Run)
if [[ "$1" == "run" ]]; then
    MODE="${2:-all}"

    set -e
    set -o pipefail

    # --- SINGLE APP UPDATE ---
    if [[ "$MODE" == "single" ]]; then
        type="$3"  # brew, cask, or mas
        id="$4"    # package name or app ID
        name="${5:-$id}"  # display name (fallback to id)
        old_ver="${6:-?}"
        new_ver="${7:-?}"

        echo "🚀 Updating $name ($old_ver -> $new_ver)..."
        echo "---------------------------"

        case "$type" in
            "brew"|"cask")
                brew upgrade "$id"
                ;;
            "mas")
                # Use upgrade instead of install to force update for existing apps
                if [[ "$MAS_ENABLED" == "1" ]]; then
                    mas upgrade "$id" || true
                else
                    echo "❌ Error: App Store updates are disabled."
                    exit 1
                fi
                ;;
        esac

        # Log update to history
        timestamp=$(date +%s)
        # Format: timestamp|source|name|old_ver|new_ver|id
        if echo "$timestamp|$type|$name|$old_ver|$new_ver|$id" >> "$HISTORY_FILE"; then
            echo "📝 Added to history log."
        fi

        echo "---------------------------"
        echo "✅ Update Complete!"
        echo "🔄 Refreshing SwiftBar..."
        open -g "swiftbar://refreshplugin?name=$(basename "$SCRIPT_FILE")"
        echo "Done! Press any key to close."
        read -k1
        exit 0
    fi

    # --- PLUGIN UPDATE SECTION ---
    if [[ "$MODE" == "all" || "$MODE" == "plugin" ]]; then
        if [[ -f "$PENDING_FLAG" ]]; then
            echo "🚀 Updating toolkit components..."
            download_with_failover "setup_mac.sh" "$APP_DIR/setup_mac.sh" && chmod +x "$APP_DIR/setup_mac.sh"
            download_with_failover "uninstall.sh" "$APP_DIR/uninstall.sh" && chmod +x "$APP_DIR/uninstall.sh"

            TEMP_TARGET="$(mktemp "${TMPDIR:-/tmp}/update_system.selfupdate.XXXXXX")"

            trap 'rm -f "$TEMP_TARGET"' EXIT

            if download_with_failover "update_system.1h.sh" "$TEMP_TARGET"; then
                mv "$TEMP_TARGET" "$SCRIPT_FILE" && chmod +x "$SCRIPT_FILE"
                rm -f "$PENDING_FLAG"
                echo "✅ Toolkit updated successfully."

                # If only updating plugin, refresh and exit
                if [[ "$MODE" == "plugin" ]]; then
                    echo "🔄 Refreshing SwiftBar..."
                    open -g "swiftbar://refreshplugin?name=$(basename "$SCRIPT_FILE")"
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

		# Analyze pending updates to create a snapshot before upgrading
		echo "🔍 Analyzing pending updates..."
		typeset -a update_log_buffer
		integer count_brew_pending=0
        integer count_mas_pending=0
		timestamp=$(date +%s)

		# Parse 'brew outdated' output using ZSH line splitting flag (f)
		raw_brew_outdated=$(brew outdated --verbose --greedy || true)
        typeset -a brew_targets
		for line in "${(@f)raw_brew_outdated}"; do
			if [[ "$line" == *"("*")"* ]]; then
				name=${line%% *}
                # Escape parenthesis here too (Brew section)
				old_ver=${${line#*\(}%%\)*}
				new_ver=${line##* }

				src="brew"
				[[ "$line" == *"!="* ]] && src="cask"

                # Check if ignored (skip adding to updates)
                if [[ "$src" == "cask" ]] && is_ignored "cask" "$name"; then
                     echo "🚫 Skipping ignored cask: $name"
                     continue
                fi

                brew_targets+=("$name")
				update_log_buffer+=("$timestamp|$src|$name|$old_ver|$new_ver")
				((++count_brew_pending))
			fi
		done

		# Parse 'mas outdated' output
		if [[ "$MAS_ENABLED" == "1" ]] && command -v mas &> /dev/null; then
			# Redirect stderr to /dev/null to suppress warnings completely
			raw_mas_outdated=$(mas outdated 2>/dev/null || true)
			for line in "${(@f)raw_mas_outdated}"; do
				# Ignore non-application lines. Valid lines MUST start with a number (App ID)
				[[ ! "$line" =~ ^[[:space:]]*[0-9]+ ]] && continue
				[[ -z "$line" ]] && continue

				# Extract ID (First word) - safe string manipulation
				app_id=${line%% *}

				# Skip ignored apps before adding to log buffer
				if is_ignored "mas" "$app_id"; then
					continue
				fi

				# Extract Version Info (Content inside the LAST parentheses)
				# Uses printf for safety against special chars, greedily removes up to last open paren
				ver_info=$(printf '%s\n' "$line" | sed -E 's/.*\(//; s/\)$//')

				# Clean Name using shared function
				app_name=$(clean_mas_name "$line")

				# Split Versions (Old -> New)
				if [[ "$ver_info" == *"->"* ]]; then
					old_ver=${ver_info%% ->*}
					new_ver=${ver_info##*-> }
				else
					old_ver="?"
					new_ver="$ver_info"
				fi

				# Add to buffer
				update_log_buffer+=("$timestamp|mas|$app_name|$old_ver|$new_ver|$app_id")
				((++count_mas_pending))
			done
		fi

		# Execute updates
		echo "🍺 Upgrading Homebrew Formulae and Casks ($count_brew_pending pending)..."

        # Capture brew upgrade output to detect renamed casks
        if [[ ${#brew_targets[@]} -gt 0 ]]; then
            upgrade_output=$(brew upgrade --greedy "${brew_targets[@]}" 2>&1 | tee /dev/tty) || true
        else
            echo "✨ No Homebrew updates to install (ignored apps skipped)."
            upgrade_output=""
        fi

        # Check for renamed cask pattern and auto-migrate
        if echo "$upgrade_output" | grep -q "was renamed to"; then
            echo "🔄 Detected renamed cask(s), attempting auto-migration..."
            echo "$upgrade_output" | grep "was renamed to" | while read -r line; do
                old_cask=$(echo "$line" | sed -E "s/.*Cask ([^ ]+) was renamed to.*/\1/")
                new_cask=$(echo "$line" | sed -E "s/.*was renamed to ([^.]+).*/\1/")
                if [[ -n "$old_cask" && -n "$new_cask" ]]; then
                    echo "  Migrating: $old_cask → $new_cask"
                    brew uninstall --cask "$old_cask" 2>/dev/null || true
                    brew install --cask "$new_cask" 2>/dev/null || true
                fi
            done
            # Re-run upgrade to catch anything else
            echo "📦 Re-running upgrade after migration..."
            if [[ ${#brew_targets[@]} -gt 0 ]]; then
                 brew upgrade --greedy "${brew_targets[@]}" || true
            fi
        fi

		echo "🧹 Cleaning up..."
		brew cleanup --prune=all

		if [[ "$MAS_ENABLED" == "1" ]] && command -v mas &> /dev/null; then
			echo "🍎 Updating App Store Applications ($count_mas_pending pending)..."

			# Check if we have any ignored MAS apps
			has_ignored_mas=false
			if [[ -f "$IGNORED_FILE" ]] && grep -q "^mas|" "$IGNORED_FILE" 2>/dev/null; then
				has_ignored_mas=true
			fi

			if [[ "$has_ignored_mas" == "true" ]]; then
				# Update each non-ignored app individually to respect ignore list
				echo "   (Updating apps individually to respect ignore list)"
				mas outdated 2>/dev/null | while read -r line; do
					[[ ! "$line" =~ ^[[:space:]]*[0-9]+ ]] && continue
					app_id=${line%% *}
					# Skip if this app is in our ignore list
					if grep -qE "^mas\|${app_id}(\||$)" "$IGNORED_FILE" 2>/dev/null; then
						continue
					fi
					mas upgrade "$app_id" || true
				done
			else
				# No ignored apps, use faster bulk upgrade
				mas upgrade || true
			fi
		fi

		# Write snapshot to history log if updates occurred
		if [[ ${#update_log_buffer[@]} -gt 0 ]]; then
			mkdir -p "$(dirname "$HISTORY_FILE")"

            # Use 'printf' instead of 'print' to avoid "bad output format" errors
			if printf "%s\n" "${update_log_buffer[@]}" >> "$HISTORY_FILE"; then
			    echo "📝 Logged ${#update_log_buffer[@]} updates details."
            else
                echo "❌ Failed to write to history file."
            fi

			# Keep file size manageable
			if [[ $(wc -l < "$HISTORY_FILE") -gt 500 ]]; then
				 tail -n 300 "$HISTORY_FILE" > "$HISTORY_FILE.tmp" && mv "$HISTORY_FILE.tmp" "$HISTORY_FILE"
			fi
        fi
    fi

    echo "---------------------------"
    echo "✅ Update Complete!"
    echo "🔄 Refreshing SwiftBar..."
    open -g "swiftbar://refreshplugin?name=$(basename "$SCRIPT_FILE")"
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

# Check Homebrew for updates (filter pinned formulae and ignored casks)
list_brew=$(brew outdated --verbose --greedy | grep -v "latest) != latest" | grep -v "^font-")

# Filter out pinned formulae (native brew pin)
pinned_formulae=$(brew list --pinned 2>/dev/null | tr '\n' '|')
if [[ -n "$pinned_formulae" ]]; then
    list_brew=$(echo "$list_brew" | grep -vE "^(${pinned_formulae%|}) ")
fi

# OPTIMIZED: Filter out ignored CASKS using memory cache (One-pass)
typeset -a ignored_patterns
for key in ${(k)IGNORED_APPS_MAP}; do
    if [[ "$key" == cask\|* ]]; then
        # Extract ID and append to patterns (match start of line + ID + space)
        ignored_patterns+=("^${key#cask|} ")
    fi
done

if [[ ${#ignored_patterns[@]} -gt 0 ]]; then
    # Join patterns with pipe | to create a single regex: ^id1 |^id2 |^id3
    # (j:|:) is a Zsh flag to join array elements with |
    list_brew=$(grep -vE "${(j:|:)ignored_patterns}" <<< "$list_brew" || true)
fi

count_brew=$(echo -n "$list_brew" | grep -c -- '[^[:space:]]' || true)

# Check App Store for updates (filter ignored MAS apps)
list_mas=""
count_mas=0
if [[ "$MAS_ENABLED" == "1" ]] && command -v mas &> /dev/null; then
    list_mas=$(mas outdated)

    # OPTIMIZED: Filter out ignored MAS apps using memory cache
    typeset -a ignored_mas_patterns
    for key in ${(k)IGNORED_APPS_MAP}; do
        if [[ "$key" == mas\|* ]]; then
            # Match ID at start of line + TRAILING SPACE to avoid partial ID matches
            # e.g. ensure ID "123" doesn't match "12345"
            ignored_mas_patterns+=("^[[:space:]]*${key#mas|}[[:space:]]")
        fi
    done

    if [[ ${#ignored_mas_patterns[@]} -gt 0 ]]; then
        # Use <<< for safety and || true to prevent exit code 1 if all updates are ignored
        list_mas=$(grep -vE "${(j:|:)ignored_mas_patterns}" <<< "$list_mas" || true)
    fi

    count_mas=$(echo "$list_mas" | grep -E '^[[:space:]]*[0-9]+' | wc -l | tr -d ' ')
fi

# MANUAL CHECK FOR GHOST APPS
# List of applications often missed by mas CLI
manual_updates_list=""
count_manual=0

if [[ "$MAS_ENABLED" == "1" ]]; then
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
        "Keynote Creator Studio"          "361285480"
        "Pages Creator Studio"            "361309726"
        "Numbers Creator Studio"          "361304891"
        "Pixelmator Pro Creator Studio"   "6746662575"
        "Final Cut Pro Creator Studio"    "1631624924"
        "Logic Pro Creator Studio"        "1615087040"
    )

    for app_name in ${(k)ghost_apps}; do
        app_id=$ghost_apps[$app_name]

        # Prevent duplicate checks if mas CLI already detected the update
        if echo "$list_mas" | grep -q "$app_id"; then
            continue
        fi

        # Respect ignore list for Ghost Apps too
        # If user ignored this ID, do not perform manual check
        if is_ignored "mas" "$app_id"; then
            continue
        fi

        result=$(check_manual_app_version "$app_name" "$app_id")
        if [[ -n "$result" ]]; then
            manual_updates_list+="$result"$'\n'
            ((++count_manual))
        fi
    done
fi

# Aggregate total updates count
total=$((count_brew + count_mas + count_manual))

# Collect installed stats
# Casks
raw_casks=$(brew list --cask --versions)
count_casks=$(echo -n "$raw_casks" | grep -c -- '[^[:space:]]' || true)

# Formulae
raw_formulae=$(brew list --formula --versions)
count_formulae=$(echo -n "$raw_formulae" | grep -c -- '[^[:space:]]' || true)

# MAS (App Store)
installed_mas=""
count_mas_installed=0
if [[ "$MAS_ENABLED" == "1" ]] && command -v mas &> /dev/null; then
    installed_mas=$(mas list)
    count_mas_installed=$(echo "$installed_mas" | wc -l | tr -d ' ')
fi
total_installed=$((count_casks + count_formulae + count_mas_installed))

# History Stats
updates_week=0
updates_month=0
count_7d=0
count_30d=0
history_7d=""
history_30d=""
# Track last printed date for grouping headers
last_date_7d=""
last_date_30d=""
current_time=$(date +%s)

if [[ -f "$HISTORY_FILE" ]]; then
    # Read file in reverse order (newest first) using sed
    while IFS='|' read -r log_time log_src log_name log_old log_new log_id; do

        # Skip legacy entries, invalid timestamps
        if [[ -z "$log_time" || ! "$log_time" =~ ^[0-9]+$ ]]; then continue; fi
        if [[ -z "$log_name" || -z "$log_new" ]]; then continue; fi

        # Calculate age of the update
        diff=$((current_time - log_time))

        # Stop processing if older than 30 days (optimization)
        if [[ $diff -gt 2592000 ]]; then break; fi

        # Determine Icon
        icon="terminal"
        [[ "$log_src" == "cask" ]] && icon="square.stack.3d.up"
        [[ "$log_src" == "mas" ]] && icon="bag"

        # Clean up log_name for display (fixes corrupted entries with IDs or versions)
        clean_name=$(clean_mas_name "$log_name")

        # Truncate versions
        short_old=$(truncate_ver "$log_old")
        short_new=$(truncate_ver "$log_new")
        strftime -s log_date_str "%d %b" "$log_time"
        local link_param=""
        case "$log_src" in
            "brew") link_param=" href='https://formulae.brew.sh/formula/${log_name}'" ;;
            "cask") link_param=" href='https://formulae.brew.sh/cask/${log_name}'" ;;
            "mas")
                # Checks if ID exists for backward compatibility
                if [[ -n "$log_id" ]]; then
                    link_param=" href='https://apps.apple.com/app/id${log_id}'"
                else
                    link_param=" href='https://apps.apple.com/search?term=${clean_name// /%20}'"
                fi
                ;;
        esac

        # Format date header line
        header_line="---- ${log_date_str}: | color=$COLOR_INFO size=11 sfimage=calendar"

        # Format item line with visual indentation (spaces) instead of date
        # Use clean_name instead of raw log_name
        item_line="----    ${clean_name} [${short_old} → ${short_new}] | size=11 sfimage=$icon font=Monaco${link_param}"

        # Populate 7 Days Bucket
        if [[ $diff -le 604800 ]]; then
            if [[ "$log_date_str" != "$last_date_7d" ]]; then
                history_7d+="${header_line}"$'\n'
                last_date_7d="$log_date_str"
            fi
            history_7d+="${item_line}"$'\n'
            ((++count_7d))
        fi

        # Populate 30 Days Bucket (includes 7 days items)
        if [[ $diff -le 2592000 ]]; then
            if [[ "$log_date_str" != "$last_date_30d" ]]; then
                history_30d+="${header_line}"$'\n'
                last_date_30d="$log_date_str"
            fi
            history_30d+="${item_line}"$'\n'
            ((++count_30d))
        fi

    done < <(tail -r "$HISTORY_FILE")
fi

# ==============================================================================
# 7. UI RENDERING
# ==============================================================================

# Prepare script path for buttons
script_path="$(swiftbar_sq_escape "$SCRIPT_FILE")"

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
if [[ ${#CONFIG_WARNINGS[@]} -gt 0 ]]; then
    echo "Config Warnings (${#CONFIG_WARNINGS[@]}) | color=$COLOR_WARN size=11 sfimage=exclamationmark.triangle"
    for warning in "${CONFIG_WARNINGS[@]}"; do
        echo "-- $warning | color=$COLOR_WARN size=10 trim=true"
    done
    echo "---"
fi

if [[ $total -eq 0 ]]; then
    if [[ $update_available -eq 1 ]]; then
        echo "Local apps are up to date | color=$COLOR_INFO size=10"
    else
        echo "System is up to date | color=$COLOR_SUCCESS sfimage=checkmark.shield"
    fi
    echo "Last check: $(date +%H:%M) | size=10 color=$COLOR_INFO"
else
    # System Updates Header (Clickable)
    if [[ $((count_brew + count_mas)) -gt 0 ]]; then
        echo "Update System Apps ($((count_brew + count_mas))) | color=$COLOR_INFO size=12 sfimage=arrow.triangle.2.circlepath bash='$script_path' param1=launch_update param2=system terminal=false refresh=true"
        echo "Last check: $(date +%H:%M) | size=10 color=$COLOR_INFO"
    fi

    if [[ $count_brew -gt 0 ]]; then
        echo "Homebrew ($count_brew): | color=$COLOR_INFO size=12 sfimage=shippingbox"
        echo "$list_brew" | while read -r line; do
            name=${line%% *}

            old_ver_raw=${${line#*\(}%%\)*}
            new_ver_raw=${line##* }
            old_ver_clean=$(clean_version "$old_ver_raw")
            new_ver_clean=$(clean_version "$new_ver_raw")

            # Determine type: cask (contains !=) or formula
            if [[ "$line" == *"!="* ]]; then
                pkg_type="cask"
                link="https://formulae.brew.sh/cask/$name"
                # Clean cask display: extract and clean versions (remove commit hashes)
                display_line="$name ($old_ver_clean) != $new_ver_clean"
            else
                pkg_type="brew"
                link="https://formulae.brew.sh/formula/$name"
                display_line="$line"
            fi
            echo "$display_line | size=12 font=Monaco color=$COLOR_INFO"
            echo "-- Update $name | bash='$script_path' param1=update_app param2=$pkg_type param3='$name' param4='$name' param5='$old_ver_clean' param6='$new_ver_clean' terminal=false refresh=true sfimage=arrow.down.circle"
            echo "-- Ignore $name | bash='$script_path' param1=ignore_app param2=$pkg_type param3='$name' param4='$name' terminal=false refresh=true sfimage=eye.slash"
        done
        echo "---"
    fi

    if [[ $count_mas -gt 0 ]]; then
        echo "App Store ($count_mas): | color=$COLOR_INFO size=12 sfimage=bag"
        echo "$list_mas" | while read -r line; do
            app_id=${line%% *}
            # Clean display line: remove ID, clean extra spaces
            display_line=$(echo "$line" | sed -E 's/^[[:space:]]*[0-9]+[[:space:]]+//' | sed -E 's/[[:space:]]{2,}/ /g')

            # Extract app name (remove version info in parentheses)
            app_name=$(echo "$display_line" | sed -E 's/[[:space:]]*\([^)]+\)$//')

            # Extract versions for history logging
            # Format usually: Name (OldVer -> NewVer)
            ver_info=$(echo "$display_line" | sed -E 's/.*\(//; s/\)$//')
            if [[ "$ver_info" == *"->"* ]]; then
                old_ver=${ver_info%% ->*}
                new_ver=${ver_info##*-> }
            else
                old_ver="?"
                new_ver="$ver_info"
            fi

            echo "$display_line | size=12 font=Monaco color=$COLOR_INFO"
            # Added param5 and param6 for version logging
            echo "-- Update $app_name | bash='$script_path' param1=update_app param2=mas param3=\"$app_id\" param4=\"$app_name\" param5=\"$old_ver\" param6=\"$new_ver\" terminal=false refresh=true sfimage=arrow.down.circle"
        echo "-- Ignore $app_name | bash='$script_path' param1=ignore_app param2=mas param3=\"$app_id\" param4=\"$app_name\" terminal=false refresh=true sfimage=eye.slash"
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

ignored_casks_list=()
for key in ${(k)IGNORED_APPS_MAP}; do
    [[ "$key" == cask\|* ]] && ignored_casks_list+=("${key#cask|}")
done
ignored_casks="${ignored_casks_list[*]}"

# Casks submenu with versions (Truncated to 20 chars)
echo "-- Apps (Brew Cask): $count_casks | color=$COLOR_INFO size=11 sfimage=square.stack.3d.up"
if [[ -n "$raw_casks" ]]; then
    # Pass ignored_casks generated from memory, not file
    echo "$raw_casks" | awk -v q="'" -v sp="$script_path" -v ign="$ignored_casks" '{
        token=$1;
        $1="";
        ver=$SCRIPT_FILE;
        gsub(/^[ \t]+|[ \t]+$/, "", ver);
        if (length(ver) > 20) ver = substr(ver, 1, 18) "..";

        is_ignored = (index(" " ign " ", " " token " ") > 0);
        color_str = is_ignored ? " color=#808080 sfimage=eye.slash" : "";
        action = is_ignored ? "Unignore" : "Ignore";
        param1 = is_ignored ? "unignore_app" : "ignore_app";

        print "---- " token " (" ver ") | href=" q "https://formulae.brew.sh/cask/" token q " size=11 font=Monaco trim=true" color_str;
        print "------ " action " | bash=" q sp q " param1=" param1 " param2=cask param3=" q token q " param4=" q token q " terminal=false refresh=true sfimage=eye";
    }'
fi

pinned_formulae_list=$(brew list --pinned 2>/dev/null | xargs)

# Brew Formulae
echo "-- CLI Tools (Brew Formulae): $count_formulae | color=$COLOR_INFO size=11 sfimage=terminal"
if [[ -n "$raw_formulae" ]]; then
    echo "$raw_formulae" | awk -v q="'" -v sp="$script_path" -v ign="$pinned_formulae_list" '{
        token=$1;
        $1="";
        ver=$SCRIPT_FILE;
        gsub(/^[ \t]+|[ \t]+$/, "", ver);
        if (length(ver) > 20) ver = substr(ver, 1, 18) "..";

        is_ignored = (index(" " ign " ", " " token " ") > 0);
        color_str = is_ignored ? " color=#808080 sfimage=eye.slash" : "";

        action = is_ignored ? "Unignore" : "Ignore";

        param1 = is_ignored ? "unignore_app" : "ignore_app";

        print "---- " token " (" ver ") | href=" q "https://formulae.brew.sh/formula/" token q " size=11 font=Monaco trim=true" color_str;
        print "------ " action " | bash=" q sp q " param1=" param1 " param2=brew param3=" q token q " param4=" q token q " terminal=false refresh=true sfimage=eye";
    }'
fi

ignored_mas_list=()
for key in ${(k)IGNORED_APPS_MAP}; do
    [[ "$key" == mas\|* ]] && ignored_mas_list+=("${key#mas|}")
done
ignored_mas="${ignored_mas_list[*]}"

# App Store
if [[ "$MAS_ENABLED" == "1" ]]; then
	echo "-- App Store: $count_mas_installed | color=$COLOR_INFO size=11 sfimage=bag"
	if [[ -n "$installed_mas" ]]; then
	    echo "$installed_mas" | awk -v q="'" -v sp="$script_path" -v ign="$ignored_mas" '{
	        id=$1;
	        $1="";
	        name=$SCRIPT_FILE;
	        gsub(/^[ \t]+|[ \t]+$/, "", name);

	        is_ignored = (index(" " ign " ", " " id " ") > 0);
	        color_str = is_ignored ? " color=#808080 sfimage=eye.slash" : "";
	        action = is_ignored ? "Unignore" : "Ignore";
	        param1 = is_ignored ? "unignore_app" : "ignore_app";

	        print "---- " name " | href=" q "https://apps.apple.com/app/id" id q " size=11 font=Monaco trim=true" color_str;
	        print "------ " action " | bash=" q sp q " param1=" param1 " param2=mas param3=" q id q " param4=" q name q " terminal=false refresh=true sfimage=eye";
	    }'
	fi
else
    echo "-- App Store: Disabled | color=#808080 size=11"
fi
echo "History: | color=$COLOR_INFO size=12 sfimage=clock.arrow.circlepath"

# Render the menus
echo "-- Past 7 days: $count_7d updates | color=$COLOR_INFO size=11 sfimage=calendar"
echo -n "$history_7d"
echo "-- Past 30 days: $count_30d updates | color=$COLOR_INFO size=11 sfimage=calendar.badge.clock"
echo -n "$history_30d"

# Footer & Controls
echo "---"
if [[ $total -gt 0 || $update_available -eq 1 ]]; then
    echo "Update Everything | bash='$script_path' param1=launch_update param2=all terminal=false refresh=true sfimage=arrow.triangle.2.circlepath.circle"
else
    echo "Update All | color=$COLOR_INFO sfimage=checkmark.circle"
fi

echo "Refresh now | refresh=true sfimage=arrow.clockwise"

echo "---"
echo "Preferences | sfimage=gearshape"
echo "-- Change Update Frequency | bash='$script_path' param1=change_interval terminal=false refresh=true sfimage=hourglass"

# Autostart Logic check (Configuration based for performance)
if [[ "${AUTOSTART:-0}" == "1" ]]; then
    as_label="Disable Autostart"
    as_icon="autostartstop.slash"
else
    as_label="Enable Autostart"
    as_icon="autostartstop"
fi
echo "-- $as_label | bash='$script_path' param1=toggle_autostart terminal=false refresh=true sfimage=$as_icon"

echo "-- Change Terminal App | bash='$script_path' param1=change_terminal terminal=false refresh=false sfimage=terminal"

# App Store Toggle Logic
if [[ "$MAS_ENABLED" == "1" ]]; then
    MAS_ICON="bag.fill"
    MAS_LABEL="Disable App Store Updates"
else
    MAS_ICON="bag"
    MAS_LABEL="Enable App Store Updates"
fi
echo "-- $MAS_LABEL | bash='$script_path' param1=toggle_mas terminal=false refresh=true sfimage=$MAS_ICON"

# Re-check pinned items to ensure variable is valid in this scope
pinned_list=$(brew list --pinned 2>/dev/null)
has_ignored=false
[[ -n "$pinned_list" ]] && has_ignored=true
# Check memory map instead of file size
[[ ${#IGNORED_APPS_MAP} -gt 0 ]] && has_ignored=true

if [[ "$has_ignored" == "true" ]]; then
    # Parent menu item (Active)
    echo "-- Manage Ignored Apps | sfimage=eye.slash"

    # List Pinned Brew Formulae
    if [[ -n "$pinned_list" ]]; then
        echo "---- Formulae (Pinned) | color=$COLOR_INFO size=11"
        echo "$pinned_list" | while read -r pin_name; do
             echo "----   $pin_name | size=11 font=Monaco"
             echo "------   Unignore | bash='$script_path' param1=unignore_app param2=brew param3='$pin_name' param4='$pin_name' terminal=false refresh=true sfimage=eye"
        done
    fi

    # OPTIMIZED: Generate Cask and Mas lists from memory map
    typeset -a sorted_keys
    sorted_keys=("${(@k)IGNORED_APPS_MAP}")
    sorted_keys=("${(@o)sorted_keys}")

    local menu_casks=""
    local menu_mas=""

    for key in "${sorted_keys[@]}"; do

        local ig_type="${key%%|*}"
        local ig_id="${key#*|}"

        # Get name stored in map value
        local display_name="${IGNORED_APPS_MAP[$key]}"
        # Fallback for safety
        [[ -z "$display_name" ]] && display_name="$ig_id"

        # Single line definition to prevent indentation bugs
        safe_name=$(swiftbar_sq_escape "$display_name")
        local item="----   $display_name | size=11 font=Monaco"$'\n'"------   Unignore | bash='$script_path' param1=unignore_app param2=$ig_type param3=\"$ig_id\" param4=\"$display_name\" terminal=false refresh=true sfimage=eye"

        if [[ "$ig_type" == "cask" ]]; then
            menu_casks+="$item"$'\n'
        elif [[ "$ig_type" == "mas" ]]; then
            menu_mas+="$item"$'\n'
        fi
    done

    # Use echo -n strictly because $item already contains newlines
    if [[ -n "$menu_casks" ]]; then
        echo "---- Casks (Ignored) | color=$COLOR_INFO size=11"
        echo -n "$menu_casks"
    fi

    if [[ -n "$menu_mas" ]]; then
        echo "---- App Store (Ignored) | color=$COLOR_INFO size=11"
        echo -n "$menu_mas"
    fi

else
    # Parent menu item (Disabled/Grayed out)
    echo "-- Manage Ignored Apps (Empty) | color=#808080 sfimage=eye.slash"
fi
# Branch selection menu item
CURRENT_CHANNEL="Stable"
BRANCH_ICON="network"

if [[ "$UPDATE_BRANCH" == "develop" ]]; then
    CURRENT_CHANNEL="Beta/Dev"
    BRANCH_ICON="hammer.fill"
fi

echo "-- Change Channel (Current: $CURRENT_CHANNEL) | bash='$script_path' param1=change_branch terminal=false refresh=true sfimage=$BRANCH_ICON"

echo "-----"
echo "-- Check for Plugin Update | bash='$script_path' param1=check_updates terminal=false refresh=true sfimage=sparkles"
echo "About | bash='$script_path' param1=about_dialog terminal=false sfimage=info.circle"
echo "---"
echo "Quit | bash='osascript' param1=-e param2='quit app \"SwiftBar\"' terminal=false sfimage=power"
