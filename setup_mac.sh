#!/bin/zsh


# ==============================================================================
# 1. GLOBAL CONFIGURATION
# ==============================================================================

# Enable colors for better terminal output visibility
autoload -U colors && colors
set -e
set -o pipefail
# Enable extended globbing to support advanced pattern matching like (#i)
setopt extended_glob

echo ""
echo "${fg[blue]}███╗   ███╗ █████╗  ██████╗ ██████╗ ███████╗${reset_color}"
echo "${fg[blue]}████╗ ████║██╔══██╗██╔════╝██╔═══██╗██╔════╝${reset_color}"
echo "${fg[blue]}██╔████╔██║███████║██║     ██║   ██║███████╗${reset_color}"
echo "${fg[blue]}██║╚██╔╝██║██╔══██║██║     ██║   ██║╚════██║${reset_color}"
echo "${fg[blue]}██║ ╚═╝ ██║██║  ██║╚██████╗╚██████╔╝███████║${reset_color}"
echo "${fg[blue]}╚═╝     ╚═╝╚═╝  ╚═╝ ╚═════╝ ╚═════╝ ╚══════╝${reset_color}"
echo ""
echo "${fg[cyan]}--------------------------------------------------${reset_color}"
echo "${fg[bold]}  mac_software_updater${reset_color} v1.3.1"
echo "${fg[cyan]}  Software Update & Application Migration Toolkit${reset_color}"
echo "${fg[cyan]}--------------------------------------------------${reset_color}"
echo "This script will: "
echo "1. Install necessary missing tools (Homebrew, mas, SwiftBar)"
echo "2. Check and Migrate your applications to managed versions"
echo "3. Configure real-time update monitoring"
echo ""

# Failover configuration
URL_PRIMARY_BASE="https://raw.githubusercontent.com/pr-fuzzylogic/mac_software_updater/main"
URL_BACKUP_BASE="https://codeberg.org/pr-fuzzylogic/mac_software_updater/raw/branch/main"

# ==============================================================================
# 2. HELPER FUNCTIONS
# ==============================================================================

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

# Helper function for yes/no confirmations
ask_confirmation() {
    local prompt="$1"
    echo -n "$prompt [y/N] "
    read -r response
    # Default to 'no' if empty
    response=${response:-n}
    # Check for y (yes) or uppercase Y
    if [[ "$response" == "y" || "$response" == "Y" ]]; then
        return 0
    else
        return 1
    fi
}

quit_app() {
    local app_name="$1"
    # Basic check if running
    if pgrep -f "$app_name" >/dev/null; then
        echo "Closing ${fg[bold]}$app_name${reset_color}..."
        # Graceful quit attempt
        osascript -e "quit app \"$app_name\"" 2>/dev/null
        # Wait up to 5 seconds
        for i in {1..5}; do
            if ! pgrep -f "$app_name" >/dev/null; then break; fi
            sleep 1
        done

        # Force kill if still lingering
        if pgrep -f "$app_name" >/dev/null; then
            echo "Forcing close..."
            # Prevent script exit if killall fails (e.g. permission mismatch)
            killall "$app_name" 2>/dev/null || true
        fi
    fi
}

# Moves the specified .app bundle to a backup location.
# Treats the application as a directory (bundle) and attempts sudo if standard move fails.
backup_app() {
    local app_path="$1"
    local backup_path="$2"
    if [[ -d "$app_path" ]]; then
        echo "Backing up original app to '$backup_path'..."
        mv "$app_path" "$backup_path" || sudo mv "$app_path" "$backup_path"
    fi
}

# Ensures a clean installation of a Homebrew Cask by removing existing metadata.
# This forces Homebrew to re-register the app bundle and update its internal database.
install_brew_cask_clean() {
    local token="$1"
    # Remove existing metadata to prevent "already installed" errors
    # and ensure the app bundle is properly linked/copied to /Applications.
    if brew list --cask "$token" &>/dev/null; then
        echo "Unlinking existing Homebrew metadata to force clean install..."
        brew uninstall --cask "$token" 2>/dev/null
    fi
    echo "Installing managed version via Homebrew..."
    brew install --cask "$token"
}

# ==============================================================================
# 3. CORE LOGIC FUNCTIONS
# ==============================================================================
echo "Starting environment configuration..."

# Ensure Homebrew is in the PATH for the current session
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

# Check for Homebrew installation
if ! command -v brew &> /dev/null; then
    echo "${fg[yellow]}Homebrew not found in PATH. Starting installation...${reset_color}"
    echo "Homebrew is required to manage your packages and updates."
    echo "Note: If you believe Homebrew is already installed, please cancel (Ctrl+C) and add it to your PATH."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    if [[ -f /opt/homebrew/bin/brew ]]; then eval "$(/opt/homebrew/bin/brew shellenv)";
    elif [[ -f /usr/local/bin/brew ]]; then eval "$(/usr/local/bin/brew shellenv)"; fi
else
    echo "${fg[green]}Homebrew is already installed.${reset_color} No action required for this step."
fi

# Check for the mas CLI tool
if ! command -v mas &> /dev/null; then
    echo "${fg[yellow]}Installing mas via Homebrew...${reset_color}"
    brew install mas
else
    echo "${fg[green]}mas tool is present.${reset_color}"
fi

if ! brew list --cask swiftbar &> /dev/null; then
    echo "${fg[yellow]}Installing SwiftBar...${reset_color}"
    brew install --cask swiftbar
else
    echo "${fg[green]}SwiftBar is already installed.${reset_color}"
fi

echo ""

# Migration Process
if ask_confirmation "Do you want to run the application migration? (Scanning and linking to Brew/AppStore)"; then

    echo
    echo "⚠️ Warning: Migrating paid apps to the App Store may require repurchasing. Prefer Homebrew to preserve your license."
    echo

    ENABLE_VERSION_SCAN=0
    if ask_confirmation "Enable detailed version scanning? (helps migration decisions, may slow down the scan)"; then
        ENABLE_VERSION_SCAN=1
    fi

    echo
    echo "Scanning installed applications..."

    typeset -A app_sources
    typeset -A app_versions
    typeset -a app_list

    if [[ -d "/opt/homebrew/Caskroom" ]]; then
        CASKROOM_PATH="/opt/homebrew/Caskroom"
    else
        CASKROOM_PATH="/usr/local/Caskroom"
    fi

    # Pre-fetch installed casks for robust detection
    if command -v brew &> /dev/null; then
        INSTALLED_CASKS_STR=" $(brew list --cask | tr '\n' ' ') "
    else
        INSTALLED_CASKS_STR=""
    fi

    # Scan /Applications recursively up to 2 levels deep
    # (N/) - null_glob to avoid errors if no match and restrict results to directories
    for app_path in /Applications/{,*/,*/*/}*.app(N/); do
        # Skip apps located inside other app bundles to avoid helpers or plugins
        if [[ "$app_path" == *.app/*.app* ]]; then continue; fi

        app_filename=$(basename "$app_path")
        app_name="${app_filename%.app}"

        # Exclude uninstallers and setup tools using case-insensitive globbing
        # The (#i) flag ensures matches like Uninstaller, uninstaller, or APPNAMEUninstaller
        if [[ "$app_name" == (#i)*uninstall* || "$app_name" == (#i)*updater* || "$app_name" == (#i)*setup* ]]; then
            continue
        fi

        app_list+=("$app_name")

        # Get local version
        if [[ "$ENABLE_VERSION_SCAN" -eq 1 ]]; then
            app_version=$(mdls -name kMDItemVersion -raw "$app_path" 2>/dev/null | tr -d '"' || echo "")
            # Fallback to defaults read if mdls fails or returns (null) - Spotlight dependency
            if [[ -z "$app_version" || "$app_version" == "(null)" ]]; then
                app_version=$(defaults read "$app_path/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo "")
            fi

            if [[ -n "$app_version" ]]; then
                 app_versions[$app_name]="$app_version"
            fi
        fi

        # Check if the app is managed by Homebrew via symlink in Caskroom
        if [[ -L "$app_path" ]]; then
            target_path=$(readlink "$app_path")
            if [[ "$target_path" == *"$CASKROOM_PATH"* ]]; then
                app_sources[$app_name]="HOMEBREW"
                continue
            fi
        fi

        # Identify App Store apps by checking for the receipt directory
        if [[ -d "$app_path/Contents/_MASReceipt" ]]; then
            app_sources[$app_name]="APP STORE"
            continue
        fi

        # 3. Fallback Check: Smart Heuristic Matching
        # Generates potential Cask tokens from the app filename to find matches in Homebrew.
        token_base=$(echo "$app_name" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')
        match_found=0
        candidates=()

        # Add exact match and common Homebrew suffix variant
        candidates+=("$token_base")
        candidates+=("${token_base}-app")

        # Strip trailing version numbers (e.g., "Downie 4" -> "downie")
        token_no_version=$(echo "$token_base" | sed -E 's/-[0-9]+$//')
        if [[ "$token_no_version" != "$token_base" ]]; then candidates+=("$token_no_version"); fi

        # Remove dots to match dot-less Cask names (e.g., "draw.io" -> "drawio")
        token_no_dots=$(echo "$token_base" | tr -d '.')
        if [[ "$token_no_dots" != "$token_base" ]]; then candidates+=("$token_no_dots"); fi

        # Progressive truncation: strip words from the end (e.g., "synology-drive-client" -> "synology-drive")
        current_token="$token_base"
        while [[ "$current_token" == *-* ]]; do
            current_token="${current_token%-*}"
            candidates+=("$current_token")
        done

        # Validate candidates against the list of locally installed casks
        for candidate in "${candidates[@]}"; do
            if [[ "$INSTALLED_CASKS_STR" == *" $candidate "* ]]; then
                app_sources[$app_name]="HOMEBREW"
                match_found=1
                break
            fi
        done

        if [[ "$match_found" -eq 1 ]]; then continue; fi

        # Try to get ID, but if it fails (e.g. system app on read-only volume), default to a fake apple ID
        bundle_id=$(mdls -name kMDItemCFBundleIdentifier -raw "$app_path" 2>/dev/null || echo "com.apple.unknown")
        if [[ "$bundle_id" == com.apple.* ]]; then
            app_sources[$app_name]="SYSTEM"
            continue
        fi

        app_sources[$app_name]="OTHER"
    done

    echo ""
    echo "${fg[blue]}=== INSTALLED APPLICATIONS ===${reset_color}"

    for app in "${app_list[@]}"; do
        source="${app_sources[$app]}"
        version="${app_versions[$app]}"
        color="$reset_color"
        [[ "$source" == "HOMEBREW" ]] && color="$fg[green]"
        [[ "$source" == "APP STORE" ]] && color="$fg[cyan]"
        [[ "$source" == "OTHER" ]] && color="$fg[yellow]"

        if [[ -n "$version" ]]; then
            echo "${color}[$source] $app ($version)${reset_color}"
        else
            echo "${color}[$source] $app${reset_color}"
        fi
    done

    echo ""
    echo "${fg[magenta]}=== STARTING MIGRATION PROCESS ===${reset_color}"
    STRICT_MATCH=0
    if ask_confirmation "Enable Strict Matching for App Store? (Reduces false positives, but might miss apps with different store names)"; then STRICT_MATCH=1; fi

    PROCESS_ONLY_OTHER=0
    if ask_confirmation "Process ONLY apps not currently managed by Homebrew/App Store?"; then PROCESS_ONLY_OTHER=1; fi

    echo "For each app choose: [A]ppStore, [B]rew, [L]eave"

    for app in "${app_list[@]}"; do
        source="${app_sources[$app]}"

        if [[ "$app" == "SwiftBar" || "$source" == "SYSTEM" ]]; then continue; fi
        if [[ "$PROCESS_ONLY_OTHER" -eq 1 ]]; then
            if [[ "$source" == "HOMEBREW" || "$source" == "APP STORE" ]]; then continue; fi
        fi

        echo ""
        source_color="$reset_color"
        [[ "$source" == "HOMEBREW" ]] && source_color="$fg[green]"
        [[ "$source" == "APP STORE" ]] && source_color="$fg[cyan]"
        [[ "$source" == "OTHER" ]] && source_color="$fg[yellow]"

        if [[ -n "${app_versions[$app]}" ]]; then
            echo "App: ${fg[bold]}${fg[cyan]}$app${reset_color} (Current: ${source_color}$source${reset_color}, Version: ${fg[magenta]}${app_versions[$app]}${reset_color})"
        else
            echo "App: ${fg[bold]}${fg[cyan]}$app${reset_color} (Current: ${source_color}$source${reset_color})"
        fi

        # Pre-check availability
        clean_name=$(echo "$app" | sed 's/[0-9.]*$//' | tr -d ':-')

        # Check App Store
        # Search the App Store and ensure that a failed search doesn't kill the script
        mas_check=$(mas search "$clean_name" 2>/dev/null | head -n 1 || true)
        if [[ -n "$mas_check" ]]; then
            mas_id=$(echo "$mas_check" | awk '{print $1}')
            # Extract name: remove ID from start, remove version (...) from end, trim spaces
            mas_name=$(echo "$mas_check" | sed -E 's/^[0-9]+[[:space:]]+//;s/[[:space:]]+\(.*\)$//')
            mas_url="https://apps.apple.com/app/id$mas_id"
            # Strict Matching Logic
            mas_valid=1
            if [[ "$STRICT_MATCH" -eq 1 ]]; then
                norm_app=$(echo "$app" | tr '[:upper:]' '[:lower:]' | tr -d ' -_.:')
                norm_mas=$(echo "$mas_name" | tr '[:upper:]' '[:lower:]' | tr -d ' -_.:')
                # Allow prefix match (e.g. "Almighty" matches "Almighty - Powerful Tweaks")
                if [[ "$norm_mas" != "$norm_app"* ]]; then mas_valid=0; fi
            fi
            if [[ "$mas_valid" -eq 1 ]]; then
                # Extract version from parentheses if present
                if [[ "$ENABLE_VERSION_SCAN" -eq 1 ]]; then
                    mas_version=$(echo "$mas_check" | sed -E 's/.*\(([^)]+)\)$/\1/')
                    if [[ "$mas_version" != "$mas_check" ]]; then
                        mas_status="${fg[green]}Available${reset_color} (${fg[cyan]}$mas_name${reset_color} ${fg[magenta]}$mas_version${reset_color}) ${fg[blue]}($mas_url)${reset_color}"
                    else
                        mas_status="${fg[green]}Available${reset_color} (${fg[cyan]}$mas_name${reset_color}) ${fg[blue]}($mas_url)${reset_color}"
                    fi
                else
                    mas_status="${fg[green]}Available${reset_color} (${fg[cyan]}$mas_name${reset_color}) ${fg[blue]}($mas_url)${reset_color}"
                fi
                mas_available=1
            else
                mas_status="${fg[red]}Mismatch in Strict Mode${reset_color} (${fg[yellow]}$mas_name${reset_color})"
                mas_available=0
            fi
        else
            mas_status="${fg[red]}Not found${reset_color}"
            mas_available=0
        fi

        # Check Homebrew
        token=$(echo "$app" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')
        brew_info_output=$(brew info --cask "$token" 2>/dev/null || true)

        if [[ -n "$brew_info_output" ]]; then
            brew_url="https://formulae.brew.sh/cask/$token"

            if [[ "$ENABLE_VERSION_SCAN" -eq 1 ]]; then
                brew_version=$(echo "$brew_info_output" | head -n 1 | awk '{print $3}')
                brew_status="${fg[green]}Available${reset_color} (${fg[cyan]}$token${reset_color} ${fg[magenta]}$brew_version${reset_color}) ${fg[blue]}($brew_url)${reset_color}"
            else
                brew_status="${fg[green]}Available${reset_color} (${fg[cyan]}$token${reset_color}) ${fg[blue]}($brew_url)${reset_color}"
            fi
            brew_available=1
        else
             # Sanity Check for Search Results (Eve != deveco-studio)
             brew_search=$(brew search --cask "$clean_name" 2>/dev/null | grep -v "Warning" | head -n 1 || true)
             match_valid=0
             if [[ -n "$brew_search" ]]; then
                norm_app=$(echo "$clean_name" | tr '[:upper:]' '[:lower:]')
                norm_result=$(echo "$brew_search" | tr '[:upper:]' '[:lower:]')
                # Strict prefix matching
                if [[ "$norm_result" == "$norm_app"* ]]; then
                    match_valid=1
                fi
             fi

              if [[ "$match_valid" -eq 1 ]]; then
                 token="$brew_search"
                 brew_url="https://formulae.brew.sh/cask/$token"

                 if [[ "$ENABLE_VERSION_SCAN" -eq 1 ]]; then
                     brew_version=$(brew info --cask "$token" | head -n 1 | awk '{print $3}')
                     brew_status="${fg[yellow]}Found as${reset_color} (${fg[cyan]}$token${reset_color} ${fg[magenta]}$brew_version${reset_color}) ${fg[blue]}($brew_url)${reset_color}"
                 else
                     brew_status="${fg[yellow]}Found as${reset_color} (${fg[cyan]}$token${reset_color}) ${fg[blue]}($brew_url)${reset_color}"
                 fi
                 brew_available=1
             else
                brew_status="${fg[red]}Not found${reset_color}"
                brew_available=0
             fi
        fi

        echo "Options:"
        echo "[A]pp Store : $mas_status"
        echo "[B]rew Cask : $brew_status"
        echo "[L]eave     : Keep as is"
        echo "[Q]uit      : Stop migration and continue setup"

        echo -n "Choose action [a/b/l/q]: "
        read -r action
        echo ""

        if [[ "$action" == "q" || "$action" == "Q" ]]; then
            echo "Stopping migration process..."
            break
        fi

        if [[ "$action" == "a" || "$action" == "A" ]]; then
            if [[ "$mas_available" -eq 1 ]]; then
                echo "Using detected App Store match: ${mas_check%% *}"
                # mas_check format is "12345 Name", we want just the ID or just run logic with ID extraction
                mas_id=$(echo "$mas_check" | awk '{print $1}')
                if ask_confirmation "Install from App Store and overwrite current version?"; then
                    # Check if running before closing
                    was_running=0
                    if pgrep -f "$app" >/dev/null; then was_running=1; fi
                    quit_app "$app"

                    app_path="/Applications/${app}.app"
                    backup_path="/Applications/${app}.app.bak"
                    backup_app "$app_path" "$backup_path"

                    [[ "$source" == "HOMEBREW" ]] && brew uninstall --cask "$(echo "$app" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')" 2>/dev/null

                    if mas install "$mas_id"; then
                        echo "Migration successful. Removing backup..."
                        rm -rf "$backup_path" || sudo rm -rf "$backup_path"
                        if [[ "$was_running" -eq 1 ]]; then
                            echo "Restarting ${fg[bold]}$app${reset_color}..."
                            open -a "$app" || echo "${fg[yellow]}Could not restart app automatically.${reset_color}"
                        fi
                    else
                         echo "${fg[red]}Error: App Store installation failed. Restoring original app...${reset_color}"
                        if [[ -d "$backup_path" ]]; then mv "$backup_path" "$app_path" || sudo mv "$backup_path" "$app_path"; fi
                    fi
                fi
            else
                echo "${fg[red]}Not available on App Store.${reset_color}"
            fi

        elif [[ "$action" == "b" || "$action" == "B" ]]; then
             if [[ "$brew_available" -eq 1 ]]; then
                 # Clarify action to the user
                 if ask_confirmation "Install '$token' via Brew Cask (Migrate to managed)?"; then
                    # Graceful application termination
                    was_running=0
                    if pgrep -f "$app" >/dev/null; then was_running=1; fi
                    quit_app "$app"

                    app_path="/Applications/${app}.app"
                    backup_path="/Applications/${app}.app.bak"
                    backup_app "$app_path" "$backup_path"

                    if install_brew_cask_clean "$token"; then
                         echo "${fg[green]}Migration successful!${reset_color}"
                         echo "Removing backup..."
                         rm -rf "$backup_path" || sudo rm -rf "$backup_path"
                         # Restart app if it was previously running
                         if [[ "$was_running" -eq 1 ]]; then
                            echo "Restarting ${fg[bold]}$app${reset_color}..."
                            # Wait till system registers new bundle
                            sleep 1
                            open -a "$app" || echo "${fg[yellow]}Could not restart app automatically.${reset_color}"
                        fi
                    else
                        # FAILURE - ROLLBACK
                        echo ""
                        echo "${fg[red]}❌ Error: Homebrew installation failed!${reset_color}"
                        echo "Restoring original application from backup..."
                        if [[ -d "$app_path" ]]; then rm -rf "$app_path" || sudo rm -rf "$app_path"; fi
                        mv "$backup_path" "$app_path" || sudo mv "$backup_path" "$app_path"
                        echo "${fg[yellow]}Original application restored. Nothing changed.${reset_color}"
                    fi
                 fi
             else
                 # Manual fallback logic
                 echo "${fg[yellow]}No automatic match found.${reset_color}"
                 echo -n "Enter Cask name manually (or enter to skip): "
                 read -r user_token
                 if [[ -n "$user_token" ]]; then
                     if brew info --cask "$user_token" &> /dev/null; then
                        if ask_confirmation "Try installing '$user_token'?"; then
                            was_running=0
                            if pgrep -f "$app" >/dev/null; then was_running=1; fi
                            quit_app "$app"
                            app_path="/Applications/${app}.app"
                            backup_path="/Applications/${app}.app.bak"
                            backup_app "$app_path" "$backup_path"

                            if install_brew_cask_clean "$user_token"; then
                                echo "${fg[green]}Migration successful!${reset_color}"
                                rm -rf "$backup_path" || sudo rm -rf "$backup_path"
                                # Restart app if it was previously running
                                if [[ "$was_running" -eq 1 ]]; then
                                    echo "Restarting ${fg[bold]}$app${reset_color}..."
                                    # Wait till system registers new bundle
                                    sleep 1
                                    open -a "$app" || echo "${fg[yellow]}Could not restart app automatically.${reset_color}"
                                fi
                            else
                                # FAILURE - ROLLBACK
                                echo ""
                                echo "${fg[red]}❌ Error: Homebrew installation failed!${reset_color}"
                                echo "Restoring original application..."
                                if [[ -d "$app_path" ]]; then rm -rf "$app_path" || sudo rm -rf "$app_path"; fi
                                mv "$backup_path" "$app_path" || sudo mv "$backup_path" "$app_path"
                                echo "${fg[yellow]}Restored.${reset_color}"
                            fi
                        fi
                     else
                        echo "Skipping: '$user_token' is not a valid Cask."
                     fi
                 fi
             fi
        fi
    done
fi

echo ""
echo "${fg[green]}=== SWIFTBAR CONFIGURATION ===${reset_color}"

# Handle SwiftBar configuration safely
EXISTING_DIR=$(defaults read com.ameba.SwiftBar PluginDirectory 2>/dev/null || echo "")

if [[ -n "$EXISTING_DIR" ]]; then
    # Expand tilde if present
    EXPANDED_EXISTING="${EXISTING_DIR/#\~/$HOME}"
    echo "SwiftBar is already configured to use: ${fg[cyan]}$EXPANDED_EXISTING${reset_color}"
    if ask_confirmation "Use this existing directory for the plugin?"; then
        PLUGIN_DIR="$EXPANDED_EXISTING"
    fi
fi

if [[ -z "$PLUGIN_DIR" ]]; then
    DEFAULT_DIR="$HOME/Documents/SwiftBarPlugins"
    if ask_confirmation "Use default directory $DEFAULT_DIR?"; then
        PLUGIN_DIR="$DEFAULT_DIR"
    else
        echo "Enter full path for plugins:"
        read -r user_path
        PLUGIN_DIR="${user_path/#\~/$HOME}"
    fi
    # Only update global setting if it's different or missing
    # Use quotes for variables that might contain spaces in paths
    if [[ "$PLUGIN_DIR" != "$EXPANDED_EXISTING" ]]; then
        defaults write com.ameba.SwiftBar PluginDirectory -string "$PLUGIN_DIR"
    fi
fi

# Create plugin directory
mkdir -p "$PLUGIN_DIR"

# Define directory and configuration file path for the updater
APP_DIR="$HOME/Library/Application Support/MacSoftwareUpdater"
# Left in code for future use. Removed auto plugin updates to avoid block by github
#CONFIG_FILE="$APP_DIR/settings.conf"
mkdir -p "$APP_DIR"
chmod 700 "$APP_DIR" 2>/dev/null || true

echo ""
echo "${fg[yellow]}=== PLUGIN SETTINGS ===${reset_color}"
# Left in code for future use.
# chmod 600 "$CONFIG_FILE" 2>/dev/null || true

# Install/Update the Main Plugin (Only this goes to SwiftBar folder)
echo "Fetching latest monitor plugin..."
TARGET_PLUGIN="$PLUGIN_DIR/update_system.1h.sh"

if download_with_failover "update_system.1h.sh" "$TARGET_PLUGIN"; then
    echo "Latest version downloaded successfully."
elif [[ -f "./update_system.1h.sh" ]]; then
    echo "Download failed, using local copy..."
    cp "./update_system.1h.sh" "$TARGET_PLUGIN"
else
    echo "${fg[red]}❌ Critical Error: No source found for plugin.${reset_color}"
    exit 1
fi
chmod +x "$TARGET_PLUGIN"

# Install Uninstaller to App Support (Not Plugin Dir)
echo "Updating Uninstaller..."
if ! download_with_failover "uninstall.sh" "$APP_DIR/uninstall.sh"; then
    [[ -f "./uninstall.sh" ]] && cp "./uninstall.sh" "$APP_DIR/uninstall.sh"
fi
chmod +x "$APP_DIR/uninstall.sh"

# Backup Setup Script to App Support
echo "Backing up Setup Wizard..."
cp "$0" "$APP_DIR/setup_mac.sh"
chmod +x "$APP_DIR/setup_mac.sh"

# Remove utility scripts from SwiftBar Plugin Directory if they exist (bug in previous version)
echo "Cleaning up SwiftBar Plugin Directory..."
rm -f "$PLUGIN_DIR/setup_mac.sh"
rm -f "$PLUGIN_DIR/uninstall.sh"

# Restart SwiftBar application to apply changes
echo "Refreshing SwiftBar..."
open -g "swiftbar://refreshallplugins"

echo ""
echo "${fg[green]}Setup complete!${reset_color}"
echo "1. Plugin installed in: ${fg[cyan]}$PLUGIN_DIR${reset_color}"
echo "2. System files moved to: ${fg[cyan]}$APP_DIR${reset_color}"
echo ""
echo "You can now safely delete the Installer folder from your Downloads."
