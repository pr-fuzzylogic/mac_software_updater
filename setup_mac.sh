#!/bin/zsh

# I enable colors for better terminal output visibility
autoload -U colors && colors

# I define a helper function for yes/no confirmations

ask_confirmation() {
    local prompt="$1"
    echo "$prompt [y/n]"
    read -k 1 response
    echo "" 
    # I check for y (yes) or uppercase Y
    if [[ "$response" == "y" || "$response" == "Y" ]]; then
        return 0
    else
        return 1
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
if ! brew list --cask sf-symbols &> /dev/null; then
    if ask_confirmation "Would you like to install SF Symbols browser?"; then
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
    echo "For each app choose: [A]ppStore, [B]rew, [L]eave"

    for app in "${app_list[@]}"; do
        source="${app_sources[$app]}"
        
        if [[ "$app" == "SF Symbols" || "$app" == "SwiftBar" || "$source" == "SYSTEM" ]]; then
            continue
        fi

        echo ""
        echo "App: ${fg[bold]}$app${reset_color} (Current: $source)"
        # I accept a single character for the action
        read -k 1 action
        echo "" 

        if [[ "$action" == "a" || "$action" == "A" ]]; then
            clean_name=$(echo "$app" | sed 's/[0-9.]*$//' | tr -d ':-')
            mas_result=$(mas search "$clean_name" | head -n 1)

            if [[ -n "$mas_result" ]]; then
                mas_id=$(echo "$mas_result" | awk '{print $1}')
                if ask_confirmation "Install from App Store and overwrite current version?"; then
                    [[ "$source" == "HOMEBREW" ]] && brew uninstall --cask "$(echo "$app" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')" 2>/dev/null
                    rm -rf "/Applications/$app.app"
                    mas install "$mas_id"
                fi
            fi

        elif [[ "$action" == "b" || "$action" == "B" ]]; then
            token=$(echo "$app" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')
            if brew info --cask "$token" &> /dev/null; then
                if ask_confirmation "Install via Brew Cask (force)?"; then
                    brew install --cask --force "$token"
                fi
            fi
        fi
    done
else
    echo "Skipping migration. Moving to plugin configuration."
fi

echo ""
echo "${fg[green]}=== SWIFTBAR CONFIGURATION ===${reset_color}"

DEFAULT_DIR="$HOME/Documents/SwiftBarPlugins"
# I use a generic placeholder for the URL
GITHUB_URL="https://raw.githubusercontent.com/USER/REPO/main/update_system.1h.sh" 

if ask_confirmation "Use default directory $DEFAULT_DIR?"; then
    PLUGIN_DIR="$DEFAULT_DIR"
else
    echo "Enter full path:"
    read user_path
    PLUGIN_DIR="${user_path/#\~/$HOME}"
fi

mkdir -p "$PLUGIN_DIR"
# I download the plugin and make it executable
curl -L -o "$PLUGIN_DIR/update_system.1h.sh" "$GITHUB_URL"
chmod +x "$PLUGIN_DIR/update_system.1h.sh"

# I update the SwiftBar preferences and restart the app
defaults write com.ameba.SwiftBar PluginDirectory -string "$PLUGIN_DIR"
killall SwiftBar 2>/dev/null
open -a SwiftBar

echo ""
echo "Setup complete."