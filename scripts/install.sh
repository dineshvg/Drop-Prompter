#!/usr/bin/env bash
# Builds DropPrompter.app and installs it into /Applications, replacing and restarting any running copy.
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/bundle.sh

pkill -x DropPrompter 2>/dev/null || true
rm -rf /Applications/DropPrompter.app
cp -R build/DropPrompter.app /Applications/
open /Applications/DropPrompter.app
echo "Installed /Applications/DropPrompter.app"
