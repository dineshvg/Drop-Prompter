#!/usr/bin/env bash
# Builds Shade.app and installs it into /Applications, replacing and restarting any running copy.
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/bundle.sh

# Shade used to be called Drop Prompter: stop and remove the old app so only one is installed.
# Its cards and settings are copied over when Shade starts for the first time.
pkill -x DropPrompter 2>/dev/null || true
rm -rf /Applications/DropPrompter.app

pkill -x Shade 2>/dev/null || true
rm -rf /Applications/Shade.app
# Move rather than copy, so Spotlight and Launchpad only ever see the installed app.
mv build/Shade.app /Applications/
open /Applications/Shade.app
echo "Installed /Applications/Shade.app"
