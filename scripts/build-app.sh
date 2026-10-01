#!/bin/zsh
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
swift test
swift build -c release
app="$HOME/Applications/Stack.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$root/.build/release/Stack" "$app/Contents/MacOS/Stack"
cp "$root/Support/Info.plist" "$app/Contents/Info.plist"
codesign --force --sign - "$app"
echo "built $app"
