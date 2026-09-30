#!/bin/bash
# Self-test for package-desktop-zip.sh on a throwaway ad-hoc-signed bundle:
# the packager must produce an archive that survives CLI unzip, and its verifier
# must refuse the archive shape that shipped in v1.1.3 (plain ditto with xattrs).
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
pkg="$here/package-desktop-zip.sh"
work="$(mktemp -d -t verdictui-zip-selftest)"
trap 'rm -rf "$work"' EXIT

app="$work/Fixture.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.vohux.verdictui.zip-selftest</string>
<key>CFBundleExecutable</key><string>fixture</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PLIST
cp /usr/bin/true "$app/Contents/MacOS/fixture"
echo "resource" > "$app/Contents/Resources/data.txt"
/usr/bin/codesign --force --deep --sign - "$app"
# The metadata that produced ._ entries in v1.1.3: xattrs on sealed files.
for f in "$app/Contents/MacOS/fixture" "$app/Contents/Resources/data.txt" "$app/Contents"; do
  /usr/bin/xattr -w com.vohux.selftest 1 "$f"
done

bash "$pkg" "$app" "$work/good.zip"
if /usr/bin/zipinfo -1 "$work/good.zip" | grep -qE '(^|/)\._'; then
  echo "FAIL: packager left AppleDouble entries" >&2
  exit 1
fi

/usr/bin/ditto -c -k --keepParent "$app" "$work/bad.zip"
/usr/bin/zipinfo -1 "$work/bad.zip" | grep -qE '(^|/)\._' \
  || { echo "FAIL: fixture did not reproduce the AppleDouble archive" >&2; exit 1; }
if bash "$pkg" --verify "$work/bad.zip" 2>/dev/null; then
  echo "FAIL: verifier accepted an archive with AppleDouble entries" >&2
  exit 1
fi
echo "package-desktop-zip self-test passed"
