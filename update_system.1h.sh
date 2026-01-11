#!/bin/zsh

# <bitbar.title>macOS Software Update & Migration Toolkit</bitbar.title>
# <bitbar.version>v1.0.0</bitbar.version>
# <bitbar.author>pr-fuzzylogic</bitbar.author>
# <bitbar.author.github>pr-fuzzylogic</bitbar.author.github>
# <bitbar.desc>Monitors Homebrew and App Store updates.</bitbar.desc>
# <bitbar.dependencies>brew,mas</bitbar.dependencies>
# <bitbar.abouturl>https://github.com/pr-fuzzylogic/mac_software_updater</bitbar.abouturl>
# <swiftbar.hideSwiftBar>true</swiftbar.hideSwiftBar>
# <swiftbar.hideLastUpdated>true</swiftbar.hideLastUpdated>
# <swiftbar.hideRunInTerminal>true</swiftbar.hideRunInTerminal>
# <swiftbar.hideDisablePlugin>true</swiftbar.hideDisablePlugin>

# UPDATE SECTION (Runs after clicking)
if [[ "$1" == "run" ]]; then
    set -e
    set -o pipefail
    echo "Downloading definitions..."
    brew update
    echo "Updating Formulae and Casks..."
    brew upgrade --greedy
    echo "Cleaning up..."
    brew cleanup --prune=all
    if command -v mas &> /dev/null; then
        echo "Updating App Store..."
        mas upgrade
    fi

    echo "Sending refresh signal to SwiftBar..."
    # I call the URL that forces a reload of this specific plugin
    # I use basename $0 to automatically get the filename
    open -g "swiftbar://refreshplugin?name=$(basename "$0")"

    echo "Done! Press any key."
    read -k1
    exit
fi

# STATUS CHECK SECTION (Runs in background)
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

# I check Homebrew
list_brew=""
count_brew=0
if command -v brew &> /dev/null; then
    list_brew=$(brew outdated --verbose --greedy)
    count_brew=$(echo -n "$list_brew" | grep -c '[^[:space:]]')
fi

# I check App Store
list_mas=""
count_mas=0
if command -v mas &> /dev/null; then
    list_mas=$(mas outdated)
    count_mas=$(echo -n "$list_mas" | grep -c '[^[:space:]]')
fi

total=$((count_brew + count_mas))

# I display the ICON in the menu bar
if [[ $total -gt 0 ]]; then
    echo "$total | sfimage=arrow.triangle.2.circlepath color=red"
else
    echo " | sfimage=checkmark.circle"
fi

# Dropdown menu separator
echo "---"

if [[ $total -eq 0 ]]; then
    echo "System is up to date | color=green"
else
    # Homebrew Section
    if [[ $count_brew -gt 0 ]]; then
        echo "Homebrew ($count_brew): | color=gray size=12"
        echo "$list_brew" | while read -r line; do
             echo "$line | size=12 font=Monaco"
        done
        echo "---"
    fi

    # App Store Section
    if [[ $count_mas -gt 0 ]]; then
        echo "App Store ($count_mas): | color=gray size=12"
        echo "$list_mas" | while read -r line; do
             echo "$line | size=12 font=Monaco"
        done
        echo "---"
    fi
fi

# Menu footer
script_path="${0// /\\ }"
echo "🚀 Update All | bash='$script_path' param1=run terminal=true"
echo "Last check: $(date +%H:%M) | size=10 color=gray"
echo "Refresh now | refresh=true"
