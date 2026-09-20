#!/bin/bash
# Cut a VerdictUI release: tag, GitHub release, then the Homebrew tap formula.
# Usage: scripts/release.sh <X.Y.Z> [--dry-run]
#
# VerdictUI ships a SOURCE-BUILT Homebrew formula (the tap runs `swift build`),
# so there is no signed bundle to notarize and no server to deploy to. This
# script is the whole release: every check runs before the first mutation, and
# --dry-run stops after the checks.
set -euo pipefail

# Versions whose tags were deleted with a burned commit (no.md #54). Reusing one
# would resurrect a reference to a sha the PII remediation existed to unreach.
BURNED_VERSIONS=(1.0.0)
REPO="medlars/verdictui"
TAP="medlars/homebrew-tap"

version="${1:-}"
dry_run=0
[ "${2:-}" = "--dry-run" ] && dry_run=1

fail() { echo "RELEASE REFUSED: $*" >&2; exit 1; }

[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "usage: $0 <X.Y.Z> [--dry-run]"
for burned in "${BURNED_VERSIONS[@]}"; do
  [ "$version" != "$burned" ] || fail "v$burned is burned (its tag was deleted with a commit carrying personal data); pick a new version"
done

cd "$(dirname "$0")/.."
git fetch -q origin --tags
[ "$(git branch --show-current)" = "main" ] || fail "not on main"
[ -z "$(git status --porcelain)" ] || fail "working tree is dirty"
[ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] || fail "HEAD is not origin/main"
git rev-parse -q --verify "refs/tags/v$version" >/dev/null && fail "tag v$version already exists"

# The binary reports its own release (test_cli_version_identifies_the_release),
# so a tag that disagrees with the source ships a build that misidentifies itself.
src_version="$(sed -n 's/.*static let current = "\(.*\)".*/\1/p' Sources/VerdictUICLICore/ReleaseVersion.swift)"
[ "$src_version" = "$version" ] || fail "ReleaseVersion.current is '$src_version', not '$version'"

echo "checks passed for v$version"
[ "$dry_run" -eq 0 ] || { echo "dry run: no tag, release or formula change made"; exit 0; }

git tag -a "v$version" -m "VerdictUI $version"
git push origin "v$version"
gh release create "v$version" --repo "$REPO" --title "VerdictUI $version" --generate-notes

# Measure the sha256 from the tarball the HOST serves, and require HTTP 200: a
# locally computed hash describes a different artifact (no.md #75).
tarball="$(mktemp -t verdictui-release)"
trap 'rm -f "$tarball"' EXIT
url="https://github.com/$REPO/archive/refs/tags/v$version.tar.gz"
code="$(curl -sSL -o "$tarball" -w '%{http_code}' --max-time 120 "$url")"
[ "$code" = "200" ] || fail "tarball $url returned HTTP $code"
gzip -t "$tarball" || fail "tarball is not a valid gzip archive"
sha="$(shasum -a 256 "$tarball" | cut -d' ' -f1)"

tap_dir="$(mktemp -d -t verdictui-tap)"
gh repo clone "$TAP" "$tap_dir" -- -q
cd "$tap_dir"
sed -i '' -e "s|archive/refs/tags/v[0-9.]*\.tar\.gz|archive/refs/tags/v$version.tar.gz|" \
          -e "s|sha256 \"[0-9a-f]*\"|sha256 \"$sha\"|" Formula/verdictui.rb
git add -- Formula/verdictui.rb
git commit -q -m "verdictui $version"
git push -q origin HEAD:main
echo "RELEASED v$version sha256 $sha"
echo "next: brew update && brew upgrade verdictui; if it fails follow docs/rollback.md"
