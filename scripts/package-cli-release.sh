#!/bin/bash
# Build, sign, notarize and audit the CLI release archive for the public assets repo.
# Usage: scripts/package-cli-release.sh <X.Y.Z> <out-dir>
#        scripts/package-cli-release.sh --scan <archive.zip>
#
# The source repo is private (CIS-467913BC), so Homebrew installs a prebuilt
# universal binary published to medlars/verdictui-releases. That archive is
# world-readable: it is refused unless the binary carries no /Users/<name> path
# and gitleaks finds nothing in the extracted files or the binary's strings.
# Writes <out-dir>/verdictui-<X.Y.Z>-macos-universal.zip and its .sha256.
set -euo pipefail

TEAM_ID="P6R899T379"
SIGN_IDENTITY="${VERDICTUI_SIGN_IDENTITY:-Developer ID Application: Eiman Rahimi ($TEAM_ID)}"
NOTARY_PROFILE="${VERDICTUI_NOTARY_PROFILE:-vohux-notary}"
CLI_BUNDLE_ID="com.vohux.verdictui.cli"

fail() { echo "PACKAGE REFUSED: $*" >&2; exit 1; }

scan_zip() {
  local zip="$1" work
  [ -f "$zip" ] || fail "no archive at $zip"
  command -v gitleaks >/dev/null || fail "gitleaks is not installed"
  if /usr/bin/zipinfo -1 "$zip" | grep -E '(^|/)(\._|__MACOSX/)' >&2; then
    fail "$zip contains AppleDouble/__MACOSX entries (listed above)"
  fi
  work="$(mktemp -d -t verdictui-cli-scan)"
  # shellcheck disable=SC2064 # expand now: the path is fixed for this call
  trap "rm -rf '$work'" RETURN
  mkdir "$work/files"
  unzip -q "$zip" -d "$work/files"
  find "$work/files" -type f -print0 | xargs -0 strings -a > "$work/strings.txt"
  if grep -n -E '/Users/[A-Za-z0-9_-]' "$work/strings.txt" | head -5 >&2; then
    fail "$zip embeds a /Users/<name> path (first hits above)"
  fi
  gitleaks dir "$work/files" --no-banner --redact --exit-code 1 >&2 \
    || fail "gitleaks flagged the extracted files of $zip"
  gitleaks dir "$work/strings.txt" --no-banner --redact --exit-code 1 >&2 \
    || fail "gitleaks flagged the binary strings of $zip"
  echo "scanned $zip (no AppleDouble entries, no /Users paths, gitleaks clean)"
}

if [ "${1:-}" = "--scan" ]; then
  [ $# -eq 2 ] || fail "usage: $0 --scan <archive.zip>"
  scan_zip "$2"
  exit 0
fi

[ $# -eq 2 ] || fail "usage: $0 <X.Y.Z> <out-dir>"
version="$1"
out_dir="$2"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "usage: $0 <X.Y.Z> <out-dir>"
[ "$(uname -s)" = "Darwin" ] || fail "the release binary is built, signed and notarized on macOS"
security find-identity -v -p codesigning | grep -qF "$SIGN_IDENTITY" \
  || fail "signing identity '$SIGN_IDENTITY' is not in the keychain"
command -v gitleaks >/dev/null || fail "gitleaks is not installed"

cd "$(dirname "$0")/.."
root="$(pwd)"
mkdir -p "$out_dir"
out_dir="$(cd "$out_dir" && pwd)"
name="verdictui-$version"
zip="$out_dir/$name-macos-universal.zip"

# The prefix maps keep the build machine's checkout and home paths out of the
# shipped binary; scan_zip refuses the archive if one survives.
build=(swift build -c release --product verdictui --arch arm64 --arch x86_64 --disable-sandbox
  -Xswiftc -file-prefix-map -Xswiftc "$root=/verdictui"
  -Xswiftc -debug-prefix-map -Xswiftc "$HOME=~")
"${build[@]}"
binary="$("${build[@]}" --show-bin-path)/verdictui"
[ -x "$binary" ] || fail "no built binary at $binary"
for arch in arm64 x86_64; do
  lipo "$binary" -verify_arch "$arch" || fail "$binary lacks $arch"
done
reported="$("$binary" --version | cut -d' ' -f1)"
[ "$reported" = "$version" ] || fail "built binary reports '$reported', not '$version'"

stage="$(mktemp -d -t verdictui-cli-stage)"
trap 'rm -rf "$stage"' EXIT
mkdir "$stage/$name"
cp "$binary" "$stage/$name/verdictui"
cp LICENSE "$stage/$name/LICENSE"
codesign --force --options runtime --timestamp --identifier "$CLI_BUNDLE_ID" \
  --sign "$SIGN_IDENTITY" "$stage/$name/verdictui"
codesign --verify --strict "$stage/$name/verdictui" || fail "signature does not verify"
codesign -dv "$stage/$name/verdictui" 2>&1 | grep -qx "TeamIdentifier=$TEAM_ID" \
  || fail "signature is not from team $TEAM_ID"
xattr -c "$stage/$name/verdictui" "$stage/$name/LICENSE"

# DELETION-REVIEW: 1) Remove a previous release zip and its .sha256 so the archive is rebuilt cleanly from the freshly signed binary. 2) Consequences: the earlier zip for this version in the chosen output directory is replaced; only the two files named after the release archive are removed. 3) Backup: none needed, the zip is rebuilt from the signed binary on the next line and published release assets are stored on the release page. 4) Following steps: zip the stage directory, scan the zip and write the new checksum.
rm -f "$zip" "$zip.sha256"
(cd "$stage" && COPYFILE_DISABLE=1 zip -q -X -r "$zip" "$name")
scan_zip "$zip"

# A bare Mach-O cannot be stapled; Gatekeeper checks the ticket online.
notary_json="$out_dir/$name-notary.json"
xcrun notarytool submit "$zip" --keychain-profile "$NOTARY_PROFILE" --wait \
  --output-format json > "$notary_json"
status="$(python3.14 -c 'import json,sys; print(json.load(open(sys.argv[1]))["status"])' "$notary_json")"
[ "$status" = "Accepted" ] || fail "notarization status is '$status' (see $notary_json)"

(cd "$out_dir" && shasum -a 256 "$(basename "$zip")" > "$(basename "$zip").sha256")
echo "packaged $zip"
echo "sha256 $(cut -d' ' -f1 "$zip.sha256")"
