# VerdictUI — SLOs

| # | SLO | Target | Measurement | Owner |
|---|-----|--------|-------------|-------|
| 1 | Inner-loop verify cycle (act → settle → verdict) on the demo app | < 100 ms p95 | PM `stage_runtime_bench` (lands Wave 3; until then `swift test` duration of the oracle suite is the proxy) | medlars@gmail.com |
| 2 | PM quick pipeline health | Grade A on every run | `python3.14 scripts/verdictui-pm.py --quick` | medlars@gmail.com |

## Notes

- SLO 1 is the product thesis in one number: if the in-process loop isn't an order of magnitude faster than a screenshot round trip (~1–10 s with model latency), the product has no reason to exist. Benchmarked on the Wave 2 demo app, macOS 14+, Apple Silicon.
- A third SLO (cross-validation loop < 5 s per scenario) is added when Wave 8 lands (see TODO.md P2).
