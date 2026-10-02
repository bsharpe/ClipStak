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
cp "$root/Support/ClipStak.icns" "$app/Contents/Resources/ClipStak.icns"
# Ad hoc signatures get a new hash every build, which drops Accessibility and
# makes the synthesized Command-V silently do nothing. A development identity stays trusted.
identity="$(security find-identity -v -p codesigning | sed -n 's/.*"\(Apple Development:.*\)"/\1/p' | head -1)"
codesign --force --sign "${identity:--}" "$app"
echo "built $app"
