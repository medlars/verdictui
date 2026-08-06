# VerdictUI — SLOs

| # | SLO | Target | Measurement | Owner |
|---|-----|--------|-------------|-------|
| 1 | Inner-loop verify cycle (act → settle → verdict) on the demo app | < 100 ms p95 | PM `stage_runtime_bench` (`HarnessPerformanceTests`, `SLO1-PERFORM` line) | medlars@gmail.com |
| 2 | PM quick pipeline health | Grade A on every run | `python3.14 scripts/verdictui-pm.py --quick` | medlars@gmail.com |

## Notes

- SLO 1 is the product thesis in one number: if the in-process loop isn't an order of magnitude faster than a screenshot round trip (~1–10 s with model latency), the product has no reason to exist. Benchmarked on the Wave 2 demo app, macOS 14+, Apple Silicon.
- **Measured 2026-08-06 (Wave 3 Task 6):** act→settle→verdict p50 19.9 ms, p95 20.9 ms over 60 samples — roughly 5x headroom against the 100 ms target. The figure is stable in isolation (three consecutive runs: 20.87 / 20.90 / 20.30 ms p95) but degrades sharply under concurrent CPU load — a run sampled while a full package build was compiling measured 92 ms p95. The budget stays at the published 100 ms rather than being tightened to the observed figure, because a threshold set near the quiet-machine number would fail for load rather than for regression.
- **Where the 100 ms is asserted (owner decision 2026-08-06).** SLO 1 is a claim about the product on the hardware named above. A shared GitHub macOS runner is not that hardware: the same commit measures p95 **20.9 ms locally and 154 ms on CI**, and the Wave 2 `currentTree()` gate shows the identical ~7x gap (6.6 ms vs 54.5 ms), so the difference is the machine and not the code. The assertion therefore runs on developer hardware — where PM `stage_runtime_bench` enforces it before every push — while CI **records** the figure as `SLO1-PERFORM-CI` without failing. Everything that proves the benchmark actually ran (sample count, finite samples, every cycle PASSing with a non-empty delta) stays a hard failure in both environments, so a benchmark that silently stopped running can never read as a fast one. Rejected alternatives: raising the product SLO to ~250 ms to accommodate a build machine, which would weaken the published claim below 'an order of magnitude faster than a screenshot round trip'; and a second CI-calibrated ceiling, which is a number that drifts with GitHub's runner specs and that nobody would recalibrate.
- A third SLO (cross-validation loop < 5 s per scenario) is added when Wave 8 lands (see TODO.md P2).
