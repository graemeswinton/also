#!/bin/bash
# Builds Also from source and installs it in your Applications folder.
# Run from the downloaded project folder:  bash install.sh
set -euo pipefail
cd "$(dirname "$0")"

if ! xcrun --find swiftc >/dev/null 2>&1 && [ ! -d /Library/Developer/CommandLineTools ]; then
  echo "Apple's Command Line Tools aren't installed (they include the Swift compiler)."
  echo "Opening the installer now. When it finishes, run this script again."
  xcode-select --install || true
  exit 1
fi

bash scripts/build.sh

# Quit Also (and Jot, its earlier name) if running. Your note is saved as you type.
for name in Also Jot; do
  if pgrep -x "$name" >/dev/null; then osascript -e "quit app \"$name\"" >/dev/null 2>&1 || true; sleep 1; fi
done

if [ -w /Applications ]; then DEST=/Applications; else DEST="$HOME/Applications"; mkdir -p "$DEST"; fi

# Remove the old Jot app; Also brings its note and settings across on first launch
for old in /Applications/Jot.app "$HOME/Applications/Jot.app"; do
  if [ -d "$old" ]; then rm -rf "$old"; echo "Removed old $old"; fi
done

rm -rf "$DEST/Also.app"
cp -R build/Also.app "$DEST/Also.app"
touch "$DEST/Also.app"

echo "Done. Also is in $DEST. Opening it now; look for its icon in the menu bar."
open "$DEST/Also.app"
