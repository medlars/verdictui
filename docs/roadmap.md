# VerdictUI roadmap

Updated September 23, 2026. Implementation and release evidence are distinct;
[wave-status.md](wave-status.md) is the current release checkpoint.

| Phase | State | Evidence and remaining boundary |
| --- | --- | --- |
| Scaffold | Complete | Package, project floor and contracts |
| Inner loop (Waves 1–3) | Implemented | Semantic kernel, public probe, headless host and settle engine |
| Agent surface (Waves 4–7) | Implemented | Macros, scenarios, CLI, warm daemon and MCP; external consumer broker added in 1.1 |
| Independent channels (Waves 8–9) | Implemented | Accessibility reconciliation, pixel comparison and evidence; denied OS access stays unavailable |
| Proof and release (Wave 10) | Existing 1.0.1 CLI; 1.1 release gates in progress | Benchmarks and consumer dogfood are documented; public docs use the existing Vohux site without waiting for a new domain purchase |
| Native/browser acting (Wave 11) | Implemented; final combined gate in progress | CLI/MCP input with observed outcomes, isolated browser ownership, secret hygiene and restart recovery |
| Desktop workbench | Implemented; signed distribution in progress | Local web-rendered UI with motion, project checks, evidence, history and cancellation |

## Continuing adoption

Each consumer owns its screen and account coverage. The measured fleet census
and remaining product-specific work are in [product-adoption.md](product-adoption.md).
Do not turn an import, demo run or empty-state fixture into a whole-app claim.

## Future product work

Hosted baselines and team review, optional adapters for uninstrumentable
frameworks, and additional product-owned coverage can build on these contracts.
A dedicated domain remains optional; the existing Vohux publication satisfies
the requirement for a reachable public product/docs surface.
