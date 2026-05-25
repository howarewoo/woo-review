#!/usr/bin/env bash
# Install dependencies for woo-review skill

set -euo pipefail

echo "🔍 Checking dependencies for woo-review..."

# 1. Check for gh CLI
if ! command -v gh &> /dev/null; then
    echo "❌ gh CLI not found. Please install it: https://cli.github.com/"
    exit 1
else
    echo "✅ gh CLI found."
fi

# 2. Check for jq
if ! command -v jq &> /dev/null; then
    echo "❌ jq not found. Please install it (e.g., brew install jq)."
    exit 1
else
    echo "✅ jq found."
fi

# 3. Check for Node.js (needed for npx)
if ! command -v node &> /dev/null; then
    echo "❌ Node.js not found. Please install it: https://nodejs.org/"
    exit 1
else
    echo "✅ Node.js found."
fi

# 4. Pre-fetch Node dependencies to speed up first run
echo "📦 Pre-fetching Node tools (impeccable, react-doctor)..."
npx -y impeccable@latest --version > /dev/null
npx -y react-doctor@latest --version > /dev/null

# 5. Check for dependent AI skills
echo "🤖 Checking for dependent AI skills..."
# Note: Since the skills CLI doesn't have a 'list' or 'check' command for specific skills yet,
# we simply suggest the user ensures they are installed.
echo "Tip: Ensure you have run 'npx skills add pbakaus/impeccable' and 'npx skills add coreyhaines31/seo-audit'."

echo "🎉 All dependencies are ready!"
