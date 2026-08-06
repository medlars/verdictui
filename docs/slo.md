# VerdictUI — SLOs

| # | SLO | Target | Measurement | Owner |
|---|-----|--------|-------------|-------|
| 1 | Inner-loop verify cycle (act → settle → verdict) on the demo app | < 100 ms p95 | PM `stage_runtime_bench` (`HarnessPerformanceTests`, `SLO1-PERFORM` line) | medlars@gmail.com |
| 2 | PM quick pipeline health | Grade A on every run | `python3.14 scripts/verdictui-pm.py --quick` | medlars@gmail.com |

## Notes

- SLO 1 is the product thesis in one number: if the in-process loop isn't an order of magnitude faster than a screenshot round trip (~1–10 s with model latency), the product has no reason to exist. Benchmarked on the Wave 2 demo app, macOS 14+, Apple Silicon.
- **Measured 2026-08-06 (Wave 3 Task 6):** act→settle→verdict p50 19.9 ms, p95 20.9 ms over 60 samples — roughly 5x headroom against the 100 ms target. The figure is stable in isolation (three consecutive runs: 20.87 / 20.90 / 20.30 ms p95) but degrades sharply under concurrent CPU load — a run sampled while a full package build was compiling measured 92 ms p95. The budget stays at the published 100 ms rather than being tightened to the observed figure, because the gate has to survive a loaded CI runner; a threshold set near the quiet-machine number would fail for load rather than for regression.
- A third SLO (cross-validation loop < 5 s per scenario) is added when Wave 8 lands (see TODO.md P2).
