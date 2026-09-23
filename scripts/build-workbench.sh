#!/bin/bash
# Build a self-contained desktop workbench with its matching verification CLI.
set -euo pipefail
configuration="${1:-release}"
case "$configuration" in debug|release) ;; *) echo 'usage: build-workbench.sh [debug|release]' >&2; exit 2 ;; esac
cd "$(dirname "$0")/.."
swift build --jobs 2 --configuration "$configuration" --product VerdictUIWorkbench \
  -Xswiftc -warnings-as-errors -Xswiftc -strict-concurrency=complete
swift build --jobs 2 --configuration "$configuration" --product verdictui \
  -Xswiftc -warnings-as-errors -Xswiftc -strict-concurrency=complete
bin="$(swift build --configuration "$configuration" --show-bin-path)"
version="$(sed -n 's/.*static let current = "\([0-9.]*\)".*/\1/p' Sources/VerdictUICLICore/ReleaseVersion.swift)"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo 'missing release identity' >&2; exit 2; }
stage="$(mktemp -d "${TMPDIR:-/tmp}/verdictui-package.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
app="$stage/VerdictUI.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Helpers" "$app/Contents/Resources"
cp "$bin/VerdictUIWorkbench" "$app/Contents/MacOS/VerdictUIWorkbench"
cp "$bin/verdictui" "$app/Contents/Helpers/verdictui"
cp assets/workbench-icon.icns "$app/Contents/Resources/Workbench.icns"
ditto "$bin/VerdictUI_VerdictUIWorkbench.bundle" "$app/Contents/Resources/VerdictUI_VerdictUIWorkbench.bundle"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.vohux.verdictui.workbench</string>
<key>CFBundleName</key><string>VerdictUI</string>
<key>CFBundleDisplayName</key><string>VerdictUI</string>
<key>CFBundleExecutable</key><string>VerdictUIWorkbench</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleIconFile</key><string>Workbench</string>
<key>CFBundleShortVersionString</key><string>$version</string>
<key>CFBundleVersion</key><string>$version</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
identity="${VERDICTUI_SIGN_IDENTITY:--}"
sign_artifact() {
  if [ "$identity" = '-' ]; then
    codesign --force --sign "$identity" "$1"
  else
    codesign --force --sign "$identity" --options runtime --timestamp "$1"
  fi
}
sign_artifact "$app/Contents/Helpers/verdictui"
sign_artifact "$app"
codesign --verify --deep --strict "$app"
mkdir -p dist
# This replaces only the build artifact. Installation separately stops a running app.
if [ -e dist/VerdictUI.app ]; then mv dist/VerdictUI.app "$stage/previous.app"; fi
mv "$app" dist/VerdictUI.app
test "$(dist/VerdictUI.app/Contents/Helpers/verdictui --version)" = "$("$bin/verdictui" --version)"
echo "WORKBENCH BUILT: $PWD/dist/VerdictUI.app ($version)"
