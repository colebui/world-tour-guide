#!/usr/bin/env bash
# Copies the staged Swift sources (ios-src/) into the Xcode project you created.
# Xcode 16+ uses synchronized folder groups, so copied files appear automatically.
#
# Usage:  ./scripts/install-ios-files.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/ios-src"

# The synchronized source folder Xcode creates is WorldGuide/WorldGuide/.
DEST="$ROOT/WorldGuide/WorldGuide"

if [ ! -d "$DEST" ]; then
  echo "ERROR: $DEST not found."
  echo "Create the Xcode project first: App named 'WorldGuide', saved into $ROOT."
  exit 1
fi

echo "Copying Swift sources into $DEST ..."
# Copy everything except the example secrets file.
rsync -a --exclude 'Secrets.example.swift' "$SRC"/ "$DEST"/

# Remove Xcode's template files (our root view is MapScreen; we don't use SwiftData yet).
rm -f "$DEST/ContentView.swift" "$DEST/Item.swift"

# Create a real Secrets.swift from the template if it doesn't exist yet.
if [ ! -f "$DEST/Secrets.swift" ]; then
  cp "$SRC/Secrets.example.swift" "$DEST/Secrets.swift"
  # Fix the header comment so it reads as the real file.
  echo "Created $DEST/Secrets.swift — fill in your Google Places key + backend URL."
fi

echo "Done. Open Xcode; the new files should appear under the WorldGuide group."
