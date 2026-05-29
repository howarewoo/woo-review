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

# 4. Pre-fetch Node dependencies to speed up first run.
# Versions are overridable via env so the skill and the action stay in lockstep.
# Defaults mirror action.yml inputs (latest).
IMPECCABLE_VERSION="${IMPECCABLE_VERSION:-latest}"
REACT_DOCTOR_VERSION="${REACT_DOCTOR_VERSION:-latest}"
echo "📦 Pre-fetching Node tools (impeccable@${IMPECCABLE_VERSION}, react-doctor@${REACT_DOCTOR_VERSION})..."
npx -y "impeccable@${IMPECCABLE_VERSION}" --version > /dev/null \
  || echo "⚠️  Could not pre-fetch impeccable@${IMPECCABLE_VERSION} (will fetch on first use)."
npx -y "react-doctor@${REACT_DOCTOR_VERSION}" --version > /dev/null \
  || echo "⚠️  Could not pre-fetch react-doctor@${REACT_DOCTOR_VERSION} (will fetch on first use)."

# 5. Check for dependent AI skills
echo "🤖 Checking for dependent AI skills..."
# Note: Since the skills CLI doesn't have a 'list' or 'check' command for specific skills yet,
# we simply suggest the user ensures they are installed.
echo "Tip: Ensure you have run 'npx skills add pbakaus/impeccable' and 'npx skills add coreyhaines31/seo-audit'."

echo "🎉 All dependencies are ready!"
