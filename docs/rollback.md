# VerdictUI — Rollback

VerdictUI is released as a git tag plus a GitHub release, installed through a
Homebrew formula in `medlars/homebrew-tap` that BUILDS FROM SOURCE
(`swift build -c release --product verdictui`). Nothing is deployed to a server
and no signed bundle is distributed, so a rollback changes what the tap tells
`brew` to fetch; it cannot reach a binary a user has already built.

## What a rollback can and cannot do

| Layer | Rollback |
|---|---|
| New installs and `brew upgrade` | Revert the formula commit in the tap (below) |
| A binary already built on a machine | Not reachable. The user runs `brew reinstall verdictui` after the tap is fixed |
| The tag and GitHub release | Leave them. A tag is a live ref and other consumers may already pin it |
| Developer copy at `~/.local/bin/verdictui` | Rebuild from the good commit; `stage_installed_parity` in the PM compares it with the Homebrew copy |

## Procedure

1. Identify the last good version: `gh release list -R medlars/verdictui`.
2. In `medlars/homebrew-tap`, `git revert` the `verdictui X.Y.Z` commit so
   `Formula/verdictui.rb` points at the previous tag's tarball and its sha256.
   Push it to `main`.
3. Prove the tap serves the old version rather than trusting the push:
   `brew update && brew info medlars/tap/verdictui` must print the previous
   version, and `brew reinstall medlars/tap/verdictui && verdictui --version`
   must report it.
4. Fix forward: correct the defect and cut the next version with
   `scripts/release.sh <X.Y.Z>`. Never re-point an existing tag.

## When there is no previous version

Only v1.0.1 exists today. Rolling back the first working release means
WITHDRAWING the formula (delete `Formula/verdictui.rb` and say so in the tap
README), which is what was done on 2026-08-14 (`no.md` #54). A tap whose install
fails reads as a broken tool, so a withdrawn formula with an explanation is
better than a formula that 404s.

**v1.0.0 is never a rollback target.** Its tag was deleted because the commit it
pointed at carried personal data; its tarball 404s, and `scripts/release.sh`
refuses the version.
