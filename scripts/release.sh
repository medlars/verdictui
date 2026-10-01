#!/bin/bash
# Cut a VerdictUI release: tag, packaged CLI on the public assets repo, then the tap formula.
# Usage: scripts/release.sh <X.Y.Z> [--dry-run]
#
# The source repo is private (CIS-467913BC), so the Homebrew formula installs a
# signed, notarized universal binary published to the public assets-only repo.
# The optional desktop archive is signed/notarized separately per docs/signing.md.
# Every check, and the build/sign/notarize/scan of the archive, runs before the
# first public mutation; --dry-run stops after the checks.
set -euo pipefail

# Versions whose tags were deleted with a burned commit (no.md #54). Reusing one
# would resurrect a reference to a sha the PII remediation existed to unreach.
BURNED_VERSIONS=(1.0.0)
REPO="medlars/verdictui"
ASSETS_REPO="medlars/verdictui-releases"
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
root="$(pwd)"
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

pkg_dir="$(mktemp -d -t verdictui-release)"
trap 'rm -rf "$pkg_dir"' EXIT
bash "$root/scripts/package-cli-release.sh" "$version" "$pkg_dir"
asset="verdictui-$version-macos-universal.zip"
local_sha="$(cut -d' ' -f1 "$pkg_dir/$asset.sha256")"

git tag -a "v$version" -m "VerdictUI $version"
git push origin "v$version"
gh release create "v$version" --repo "$REPO" --title "VerdictUI $version" --generate-notes
gh release create "v$version" --repo "$ASSETS_REPO" --target main --title "verdictui $version" \
  --notes "Prebuilt universal macOS binary, signed with Developer ID (team P6R899T379) and notarized by Apple. Install: \`brew install medlars/tap/verdictui\`." \
  "$pkg_dir/$asset" "$pkg_dir/$asset.sha256"

# Measure the sha256 from the asset the HOST serves, and require HTTP 200: a
# locally computed hash describes a different artifact (no.md #75).
served="$pkg_dir/served.zip"
url="https://github.com/$ASSETS_REPO/releases/download/v$version/$asset"
code="$(curl -sSL -o "$served" -w '%{http_code}' --max-time 120 "$url")"
[ "$code" = "200" ] || fail "asset $url returned HTTP $code"
sha="$(shasum -a 256 "$served" | cut -d' ' -f1)"
[ "$sha" = "$local_sha" ] || fail "served asset sha256 $sha differs from the packaged $local_sha"

tap_dir="$(mktemp -d -t verdictui-tap)"
gh repo clone "$TAP" "$tap_dir" -- -q
bash "$root/scripts/bump-tap-formula.sh" "$tap_dir/Formula/verdictui.rb" "$version" "$sha"
cd "$tap_dir"
git add -- Formula/verdictui.rb
git commit -q -m "verdictui $version"
tap_pr="$(bash "$root/scripts/land-tap-formula.sh" "$tap_dir" "$version")"
echo "RELEASED v$version sha256 $sha (tap $tap_pr)"
echo "next: brew update && brew upgrade verdictui; if it fails follow docs/rollback.md"
