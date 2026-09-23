# VerdictUI — Rollback

VerdictUI is released as a git tag plus a GitHub release, installed through a
Homebrew formula in `medlars/homebrew-tap` that BUILDS FROM SOURCE
(`swift build -c release --product verdictui`). The desktop app is a separate
signed and notarized GitHub release asset. A formula rollback changes what
`brew` fetches; it does not replace binaries or desktop apps already installed.

## What a rollback can and cannot do

| Layer | Rollback |
|---|---|
| New installs and `brew upgrade` | Revert the formula commit in the tap (below) |
| A binary already built on a machine | Not reachable. The user runs `brew reinstall verdictui` after the tap is fixed |
| The tag and GitHub release | Leave them. A tag is a live ref and other consumers may already pin it |
| Developer copy at `~/.local/bin/verdictui` | Rebuild from the good commit; `stage_installed_parity` in the PM compares it with the Homebrew copy |
| Desktop app | Quit VerdictUI, retain the current bundle for investigation, install the last verified notarized bundle, compare its hash/version and rerun acceptance |
| Saved workbench projects and browser profiles | Preserve Application Support state and profile directories; replacing the app must not delete user data |

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

If no previous verified desktop bundle exists, withdraw the defective desktop
asset and explain the limitation in the release notes while fixing forward.
The source-built CLI can remain available if its acceptance still passes.
For a first defective CLI release with no valid predecessor, withdraw its
formula and explain why in the tap README, as on 2026-08-14 (`no.md` #54).

**v1.0.0 is never a rollback target.** Its tag was deleted because the commit it
pointed at carried personal data; its tarball 404s, and `scripts/release.sh`
refuses the version.
