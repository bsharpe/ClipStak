#!/bin/zsh
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
swift test
swift build -c release
app="$HOME/Applications/ClipStak.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$root/.build/release/ClipStak" "$app/Contents/MacOS/ClipStak"
cp "$root/Support/Info.plist" "$app/Contents/Info.plist"
codesign --force --sign - "$app"
echo "built $app"
