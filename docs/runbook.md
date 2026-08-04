# VerdictUI — Runbook

## Start / Stop

```bash
# Build + test (no daemon exists until Wave 6)
swift build --build-tests
swift test

# Wave 6+: daemon lifecycle (fill in when the daemon ships)
# verdictui daemon start / verdictui daemon stop
```

## Deploy

```bash
# Library-only until Wave 6; consumers add the SPM dependency.
# Wave 6+: Homebrew tap release via stage_auto_release (currently deferred).
```

## Rollback

```bash
# Rollback to previous: git revert HEAD && swift build --build-tests
```

## Logs

| Log | Path |
|-----|------|
| PM | `logs/pm.log` / `logs/pm-last-status.json` |
| Swift build | `.build/` diagnostics |

## Health Check

```bash
python3.14 scripts/verdictui-pm.py --quick
```

## Known Failure Modes

| Symptom | Cause | Fix |
|---------|-------|-----|
| `swift build` hangs on "Another instance of SwiftPM" | zombie SwiftPM holding `.build/.lock` | PM's swift_runner kills it automatically; manually: `rm .build/.lock` after killing the PID |
| Probe tests fail on CI but pass locally | NSHostingView window-server dependency (Wave 2+) | Oracle harness must stay windowless (`NSHostingView` + `cacheDisplay` pattern, displayScale pinned to 1) |
