#!/bin/bash

# Check if a commit message is provided
if [ -z "$1" ]; then
  echo "Error: Task description is required. Example: bash step.sh 'Added email validation'"
  exit 1
fi

MESSAGE=$1
TIMESTAMP=$(date +"%Y-%m-%d %H:%M:%S")

# 1. Update context file for the next agent
echo -e "### $TIMESTAMP\n- **Task:** $MESSAGE\n- **Status:** Done\n" >> .ai_session_log.md

# 2. Git routine
git add .
git commit -m "$MESSAGE" -m "Automated checkpoint at $TIMESTAMP. Context updated in .ai_session_log.md"
git push

echo "✅ Progress saved and pushed to the repository."