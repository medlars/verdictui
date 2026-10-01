#!/bin/bash
# Land a committed tap formula bump through an auto-merge PR, then wait for it.
# Usage: scripts/land-tap-formula.sh <tap-checkout> <X.Y.Z>
#
# The tap's main is PR-only (DIR-045): push a release branch, open (or reuse)
# its PR, arm squash auto-merge with branch deletion, and return only once the
# PR is MERGED, so "RELEASED" is never printed for a formula still in review.
# Prints the PR URL on success. LAND_TAP_TIMEOUT / LAND_TAP_POLL are seconds.
set -euo pipefail

tap_dir="${1:?usage: $0 <tap-checkout> <X.Y.Z>}"
version="${2:?usage: $0 <tap-checkout> <X.Y.Z>}"
branch="release/verdictui-$version"
deadline=$(( $(date +%s) + ${LAND_TAP_TIMEOUT:-1800} ))

cd "$tap_dir"
git push -q --force origin "HEAD:refs/heads/$branch"
# `gh pr view` exits non-zero when the branch has no PR yet; that is the create case.
url="$(gh pr view "$branch" --json url,state --jq 'select(.state == "OPEN") | .url' 2>/dev/null || true)"
if [ -z "$url" ]; then
  url="$(gh pr create --base main --head "$branch" --title "verdictui $version" \
    --body "Formula bump for VerdictUI $version, landed by scripts/release.sh (DIR-045).")"
fi
if ! gh pr merge "$url" --auto --squash --delete-branch >/dev/null 2>&1 \
  && ! gh pr merge "$url" --squash --delete-branch >/dev/null 2>&1; then
  echo "tap PR $url: merge not accepted yet; waiting for its checks" >&2
fi

while :; do
  state="$(gh pr view "$url" --json state --jq .state)"
  case "$state" in
    MERGED) echo "$url"; exit 0 ;;
    CLOSED) echo "tap PR closed without merging: $url" >&2; exit 1 ;;
  esac
  [ "$(date +%s)" -lt "$deadline" ] || { echo "tap PR not merged before the deadline: $url" >&2; exit 1; }
  sleep "${LAND_TAP_POLL:-15}"
done
