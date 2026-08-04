# VerdictUI

SwiftUI verification engine that replaces the screenshot–wait–click–confirm cycle with in-process instrumentation, virtual-clock settling, and atomic act-and-observe verdicts.

**The problem:** AI agents and developers verify SwiftUI work by screenshotting, sleeping, clicking, and screenshotting again — slow, flaky, permission-gated, and blind between frames. XCUITest's idle-wait is documented-broken; SwiftUI has no `pumpAndSettle`.

**The approach:** make SwiftUI testify about itself. Views instrumented via public API (Layout-protocol probes, `PreferenceKey` frame streams, `@Verifiable` macro) emit a ground-truth semantic tree during the layout pass itself. A platform-pure kernel turns that tree into machine-readable `PASS`/`FAIL` verdicts with cited evidence. An external cross-validation loop (accessibility tree + real events + windowless pixel diff) keeps the fast channel honest.

## Quick Start

```bash
bash scripts/dev.sh                          # setup + build + test
swift test                                   # kernel + probe test suites
python3.14 scripts/verdictui-pm.py --quick   # project health (Grade A expected)
```

## Status

Wave 0 (scaffold) complete. See `docs/implementation-plan.md` for the full multi-wave plan and `docs/roadmap.md` for phase status.

## Layout

- `Sources/VerdictUIKernel` — semantic tree, lint rules, verdict schema (platform-pure)
- `Sources/VerdictUIProbe` — SwiftUI instrumentation runtime
- `docs/implementation-plan.md` — ultra-detailed wave plan (execution spec for Opus 5)

## Health

```bash
python3.14 scripts/verdictui-pm.py --quick
```
