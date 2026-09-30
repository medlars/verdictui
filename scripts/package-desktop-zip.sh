#!/bin/bash
# Archive a signed VerdictUI.app for distribution, then prove the archive is sound.
# Usage: scripts/package-desktop-zip.sh <path/to/VerdictUI.app> <out.zip>
#        scripts/package-desktop-zip.sh --verify <archive.zip>
#
# Plain `ditto -c -k --keepParent` stores extended attributes as AppleDouble `._*`
# entries. Finder and ditto fold them back into xattrs, but `unzip` writes them as
# real files inside the bundle, which breaks the code-signature seal
# (v1.1.3, CIS-353E4881). The archive is refused unless it has no AppleDouble or
# __MACOSX entries and the app passes `codesign --verify --deep --strict` after
# BOTH a CLI unzip and a ditto extract.
set -euo pipefail

fail() { echo "PACKAGE REFUSED: $*" >&2; exit 1; }

verify_zip() {
  local zip="$1" work app
  [ -f "$zip" ] || fail "no archive at $zip"
  if /usr/bin/zipinfo -1 "$zip" | grep -E '(^|/)(\._|__MACOSX/)' >&2; then
    fail "$zip contains AppleDouble/__MACOSX entries (listed above)"
  fi
  work="$(mktemp -d -t verdictui-zip-verify)"
  # shellcheck disable=SC2064 # expand now: the path is fixed for this call
  trap "rm -rf '$work'" RETURN
  mkdir "$work/unzip" "$work/ditto"
  /usr/bin/unzip -q "$zip" -d "$work/unzip"
  /usr/bin/ditto -x -k "$zip" "$work/ditto"
  for dir in "$work/unzip" "$work/ditto"; do
    app="$(find "$dir" -maxdepth 1 -name '*.app' -print -quit)"
    [ -n "$app" ] || fail "$zip does not contain a top-level .app"
    /usr/bin/codesign --verify --deep --strict "$app" \
      || fail "codesign rejects the app after extracting with $(basename "$dir")"
  done
  echo "verified $zip (no AppleDouble entries; codesign passes after unzip and ditto)"
  echo "sha256 $(shasum -a 256 "$zip" | cut -d' ' -f1)"
}

if [ "${1:-}" = "--verify" ]; then
  [ $# -eq 2 ] || fail "usage: $0 --verify <archive.zip>"
  verify_zip "$2"
  exit 0
fi

[ $# -eq 2 ] || fail "usage: $0 <path/to/App.app> <out.zip>"
app="${1%/}"
out="$2"
[ -d "$app" ] && [[ "$app" == *.app ]] || fail "$app is not an .app bundle"
/usr/bin/codesign --verify --deep --strict "$app" || fail "$app does not verify before archiving"
rm -f "$out"
COPYFILE_DISABLE=1 /usr/bin/ditto -c -k --norsrc --noextattr --noqtn --noacl --keepParent "$app" "$out"
verify_zip "$out"
