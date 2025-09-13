#!/bin/bash

# Define the path to your commands file
COMMANDS_FILE="commands.txt"

# Check if the commands file exists
if [ ! -f "$COMMANDS_FILE" ]; then
    echo "Error: Commands file '$COMMANDS_FILE' not found."
    exit 1
fi

# Read and execute each command from the file
while IFS= read -r command; do
    # Skip empty lines and lines starting with '#' (comments)
    if [[ -n "$command" && ! "$command" =~ ^# ]]; then
        echo "Executing: $command"
        eval "$command" # Use eval to correctly execute commands with arguments/redirections
        if [ $? -ne 0 ]; then
            echo "Warning: Command '$command' failed with exit code $?."
        fi
    fi
done < "$COMMANDS_FILE"

echo "All commands processed. Restart the Terminal now!!!"
