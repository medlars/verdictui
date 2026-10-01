#!/bin/bash
# Point the tap formula at a published release archive and prove the edit took.
# Usage: scripts/bump-tap-formula.sh <Formula/verdictui.rb> <X.Y.Z> <sha256>
#
# A substitution that matches nothing exits 0 and leaves the old url in place,
# which would land a "bump" that changes nothing. The rewritten file must carry
# exactly the new url and sha256, or the script refuses. Portable sed (no -i),
# so the CI test runs it on Linux too.
set -euo pipefail

ASSETS_REPO="medlars/verdictui-releases"

fail() { echo "FORMULA BUMP REFUSED: $*" >&2; exit 1; }

[ $# -eq 3 ] || fail "usage: $0 <formula.rb> <X.Y.Z> <sha256>"
formula="$1"
version="$2"
sha="$3"
[ -f "$formula" ] || fail "no formula at $formula"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "version '$version' is not X.Y.Z"
[[ "$sha" =~ ^[0-9a-f]{64}$ ]] || fail "sha256 '$sha' is not 64 lowercase hex digits"

url="https://github.com/$ASSETS_REPO/releases/download/v$version/verdictui-$version-macos-universal.zip"
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
sed -E -e "s|^  url \"[^\"]*\"|  url \"$url\"|" \
       -e "s|^  sha256 \"[0-9a-f]*\"|  sha256 \"$sha\"|" "$formula" > "$tmp"

[ "$(grep -c '^  url "' "$tmp")" = "1" ] || fail "$formula must have exactly one top-level url"
grep -qxF "  url \"$url\"" "$tmp" || fail "url was not rewritten to $url"
grep -qxF "  sha256 \"$sha\"" "$tmp" || fail "sha256 was not rewritten"
cat "$tmp" > "$formula"
echo "formula -> v$version $sha"
