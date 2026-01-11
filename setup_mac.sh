#!/bin/zsh

# I enable colors for better terminal output visibility
autoload -U colors && colors
set -e
set -o pipefail

# I define a helper function for yes/no confirmations

echo ""
echo "${fg[blue]}███╗   ███╗ █████╗  ██████╗ ██████╗ ███████╗${reset_color}"
echo "${fg[blue]}████╗ ████║██╔══██╗██╔════╝██╔═══██╗██╔════╝${reset_color}"
echo "${fg[blue]}██╔████╔██║███████║██║     ██║   ██║███████╗${reset_color}"
echo "${fg[blue]}██║╚██╔╝██║██╔══██║██║     ██║   ██║╚════██║${reset_color}"
echo "${fg[blue]}██║ ╚═╝ ██║██║  ██║╚██████╗╚██████╔╝███████║${reset_color}"
echo "${fg[blue]}╚═╝     ╚═╝╚═╝  ╚═╝ ╚═════╝ ╚═════╝ ╚══════╝${reset_color}"
echo ""
echo "${fg[bold]}macOS Maintenance & Migration Toolkit${reset_color}"
echo "-------------------------------------"
echo "This script will: "
echo "1. Install necessary tools (Homebrew, mas, SwiftBar)"
echo "2. Audit your applications"
echo "3. Help you migrate to managed updates"
echo ""

ask_confirmation() {
    local prompt="$1"
    echo -n "$prompt [y/N] "
    read -r response
    # Default to 'no' if empty
    response=${response:-n}
    # I check for y (yes) or uppercase Y
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
            if ! pgrep -f "$app_name" >/dev/null; then
                break
            fi
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

echo "Starting environment configuration..."

# I ensure Homebrew is in the PATH for the current session
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

# I check for Homebrew installation
if ! command -v brew &> /dev/null; then
    echo "Homebrew is missing. Installing now..."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

    if [[ -f /opt/homebrew/bin/brew ]]; then
        eval "$(/opt/homebrew/bin/brew shellenv)"
    elif [[ -f /usr/local/bin/brew ]]; then
        eval "$(/usr/local/bin/brew shellenv)"
    fi
else
    echo "Homebrew is already installed."
fi

# I check for the mas CLI tool
if ! command -v mas &> /dev/null; then
    echo "Installing mas via Homebrew..."
    brew install mas
else
    echo "mas tool is present."
fi

# I check for SF Symbols
# I check for SF Symbols
if ! brew list --cask sf-symbols &> /dev/null; then
    echo "Optional: The 'SF Symbols' browser is only needed if you want to browse/customize icons."
    if ask_confirmation "Would you like to install SF Symbols browser? (press 'y' if you plan to customize icons, otherwise 'n')"; then
        echo "Installing SF Symbols..."
        brew install --cask sf-symbols
    fi
fi

# I check for SwiftBar
if ! brew list --cask swiftbar &> /dev/null; then
    echo "Installing SwiftBar..."
    brew install --cask swiftbar
fi

echo ""
# I ask if the user wants to perform the optional migration process
if ask_confirmation "Do you want to run the application migration? (Scanning and linking to Brew/AppStore)"; then

    echo "Scanning installed applications..."

    typeset -A app_sources
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

    for app_path in /Applications/*.app(N); do
        app_filename=$(basename "$app_path")
        app_name="${app_filename%.app}"
        app_list+=("$app_name")

        if [[ -L "$app_path" ]]; then
            target_path=$(readlink "$app_path")
            if [[ "$target_path" == *"$CASKROOM_PATH"* ]]; then
                app_sources[$app_name]="HOMEBREW"
                continue
            fi
        fi

        if [[ -d "$app_path/Contents/_MASReceipt" ]]; then
            app_sources[$app_name]="APP STORE"
            continue
        fi

        # Fallback Check: Is it in 'brew list --cask'?
        # (Handles cases where symlink is broken/overwritten but brew still manages it)
        token_check=$(echo "$app_name" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')
        if [[ "$INSTALLED_CASKS_STR" == *" $token_check "* ]]; then
            app_sources[$app_name]="HOMEBREW"
            continue
        fi

        bundle_id=$(mdls -name kMDItemCFBundleIdentifier -raw "$app_path" 2>/dev/null)
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
        color="$reset_color"
        [[ "$source" == "HOMEBREW" ]] && color="$fg[green]"
        [[ "$source" == "APP STORE" ]] && color="$fg[cyan]"
        [[ "$source" == "OTHER" ]] && color="$fg[yellow]"
        echo "${color}[$source] $app${reset_color}"
    done

    echo ""
    echo "${fg[magenta]}=== STARTING MIGRATION PROCESS ===${reset_color}"
    STRICT_MATCH=0
    if ask_confirmation "Enable Strict Matching for App Store? (Reduces false positives, but might miss apps with different store names)"; then
        STRICT_MATCH=1
    fi

    PROCESS_ONLY_OTHER=0
    if ask_confirmation "Process ONLY apps not currently managed by Homebrew/App Store?"; then
        PROCESS_ONLY_OTHER=1
    fi

    echo "For each app choose: [A]ppStore, [B]rew, [L]eave"

    for app in "${app_list[@]}"; do
        source="${app_sources[$app]}"

        if [[ "$app" == "SF Symbols" || "$app" == "SwiftBar" || "$source" == "SYSTEM" ]]; then
            continue
        fi

        # Skip managed apps if user requested
        if [[ "$PROCESS_ONLY_OTHER" -eq 1 ]]; then
            if [[ "$source" == "HOMEBREW" || "$source" == "APP STORE" ]]; then
                continue
            fi
        fi

        echo ""
        echo "App: ${fg[bold]}$app${reset_color} (Current: $source)"

        # Pre-check availability
        clean_name=$(echo "$app" | sed 's/[0-9.]*$//' | tr -d ':-')

        # Check App Store
        mas_check=$(mas search "$clean_name" | head -n 1)
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
                if [[ "$norm_mas" != "$norm_app"* ]]; then
                    mas_valid=0
                fi
            fi

            if [[ "$mas_valid" -eq 1 ]]; then
                mas_status="${fg[green]}Available${reset_color} (${fg[cyan]}$mas_name${reset_color}) ${fg[blue]}($mas_url)${reset_color}"
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
        if brew info --cask "$token" &> /dev/null; then
            brew_url="https://formulae.brew.sh/cask/$token"
            brew_status="${fg[green]}Available${reset_color} (${fg[cyan]}$token${reset_color}) ${fg[blue]}($brew_url)${reset_color}"
            brew_available=1
        else
             # Fallback search
             brew_search=$(brew search --cask "$app" 2>/dev/null | grep -v "Warning" | head -n 1)
             if [[ -n "$brew_search" ]]; then
                token="$brew_search"
                brew_url="https://formulae.brew.sh/cask/$token"
                brew_status="${fg[yellow]}Found as${reset_color} (${fg[cyan]}$brew_search${reset_color}) ${fg[blue]}($brew_url)${reset_color}"
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

        echo -n "Choose action [a/b/L/q]: "
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
                    if pgrep -f "$app" >/dev/null; then
                        was_running=1
                    fi

                    quit_app "$app"

                    backup_name="${app}.app.bak"
                    if [[ -n "${app}" && -d "/Applications/${app}.app" ]]; then
                        echo "Backing up original app..."
                        mv "/Applications/${app}.app" "/Applications/$backup_name"
                    fi

                    [[ "$source" == "HOMEBREW" ]] && brew uninstall --cask "$(echo "$app" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')" 2>/dev/null

                    if mas install "$mas_id"; then
                        echo "Migration successful. Removing backup..."
                        rm -rf "/Applications/$backup_name"

                        if [[ "$was_running" -eq 1 ]]; then
                            echo "Restarting ${fg[bold]}$app${reset_color}..."
                            open -a "$app" || echo "${fg[yellow]}Could not restart app automatically.${reset_color}"
                        fi
                    else
                         echo "${fg[red]}Error: App Store installation failed. Restoring original app...${reset_color}"
                        [[ -d "/Applications/$backup_name" ]] && mv "/Applications/$backup_name" "/Applications/${app}.app"
                    fi
                fi
            else
                echo "${fg[red]}Not available on App Store.${reset_color}"
            fi

        elif [[ "$action" == "b" || "$action" == "B" ]]; then
             if [[ "$brew_available" -eq 1 ]]; then
                 if ask_confirmation "Install '$token' via Brew Cask (force)?"; then
                    # Check if running before closing
                    was_running=0
                    if pgrep -f "$app" >/dev/null; then
                         was_running=1
                    fi

                    quit_app "$app"

                    if brew install --cask --force "$token"; then
                         if [[ "$was_running" -eq 1 ]]; then
                            echo "Restarting ${fg[bold]}$app${reset_color}..."
                            open -a "$app" || echo "${fg[yellow]}Could not restart app automatically.${reset_color}"
                        fi
                    fi
                 fi
             else
                 # Manual fallback if they insist on B even though we didn't find it automatically
                 echo "${fg[yellow]}No automatic match found.${reset_color}"
                 echo -n "Enter Cask name manually (or enter to skip): "
                 read -r user_token

                 if [[ -n "$user_token" ]]; then
                     if brew info --cask "$user_token" &> /dev/null; then
                        if ask_confirmation "Install '$user_token' via Brew Cask (force)?"; then
                            # Check if running
                            was_running=0
                            if pgrep -f "$app" >/dev/null; then
                                was_running=1
                            fi

                            quit_app "$app"
                            if brew install --cask --force "$user_token"; then
                                if [[ "$was_running" -eq 1 ]]; then
                                    echo "Restarting ${fg[bold]}$app${reset_color}..."
                                    open -a "$app" || echo "${fg[yellow]}Could not restart app automatically.${reset_color}"
                                    fi
                            fi
                        fi
                     else
                        echo "Skipping: '$user_token' is not a valid Cask."
                     fi
                 fi
             fi
        fi
    done
else
    echo "Skipping migration. Moving to plugin configuration."
fi

echo ""
echo "${fg[green]}=== SWIFTBAR CONFIGURATION ===${reset_color}"

# I handle SwiftBar configuration safely
EXISTING_DIR=$(defaults read com.ameba.SwiftBar PluginDirectory 2>/dev/null || echo "")
GITHUB_URL="https://raw.githubusercontent.com/pr-fuzzylogic/mac_software_updater/main/update_system.1h.sh"

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
    if [[ "$PLUGIN_DIR" != "$EXPANDED_EXISTING" ]]; then
        defaults write com.ameba.SwiftBar PluginDirectory -string "$PLUGIN_DIR"
    fi
fi

mkdir -p "$PLUGIN_DIR"
# I download the plugin and make it executable
curl -L -o "$PLUGIN_DIR/update_system.1h.sh" "$GITHUB_URL"
chmod +x "$PLUGIN_DIR/update_system.1h.sh"

# I restart SwiftBar to pick up the new plugin
killall SwiftBar 2>/dev/null || true
open -a SwiftBar

echo ""
echo "Setup complete."
