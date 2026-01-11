#!/bin/zsh

# I iterate through all applications found in the system
for app in /Applications/*.app; do
    name=$(basename "$app" .app)
    
    # I convert the name to homebrew format which means lowercase and hyphens
    token=$(echo "$name" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')

    # I check if the specific cask exists in the repository
    if brew info --cask "$token" &> /dev/null; then
        
        # I check if brew already manages this application
        if ! brew list --cask "$token" &> /dev/null; then
            
            echo "Found $name. It is not managed by Brew, but it is available."
            echo "I take over the application by installing it with the force flag..."
            
            # I install with force to overwrite the existing file in Applications
            brew install --cask --force "$token"
            
            echo "Success. $name is now managed by Cask."
            echo "***************************************************"
        fi
    fi
done