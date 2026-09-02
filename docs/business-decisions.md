# VerdictUI — Business & Marketing Decision History

> Record of the market/business Q&A that led to building VerdictUI, and the
> decisions taken. Written 2026-08-04 from the founding chat session (research +
> scaffold session of 2026-08-03/04). Future business decisions append here;
> technical non-decisions stay in `no.md`; architecture decisions get ADRs in
> `.decisions/`.

## The founding problem

Agent-driven development is bottlenecked by UI verification: the
screenshot → wait → click → confirm cycle is slow, lossy, and repeated on every
edit. The founding goal: automate an accurate virtual render + verification of
UIs for desktop (SwiftUI first) and web apps, eliminating repeated screenshots
and the delays between act and verify.

## Q&A history (questions asked, answers that shaped the product)

### Q1. Will it be a useful, highly demanded tool? Is there a competitor? Should we build it?

**Answer — yes, build it.** Demand is driven by the rise of coding agents: every
agent session pays the screenshot-cycle tax, and dev teams pay it again in CI.
Competitive research (5-agent deep survey, 2026-08-03) found the *components*
exist but no unified product:

- Agent-facing MCP servers exist (Playwright MCP, Xcode/Previews MCP) but are
  chatty, single-session wrappers over existing tools.
- Snapshot/pixel tools exist (swift-snapshot-testing, ODiff/SSIM compare,
  reftests) but are pixel-first, flaky, and blind to semantics.
- Bidirectional UI editors (Onlook, Tempo) target design-to-code, not
  verification.
- Semantic/accessibility linting exists on web (axe-core, layout linters) but
  nothing equivalent for SwiftUI, and nothing that unifies web + native.

**No competitor unifies in-process instrumentation + external cross-validation
+ machine-readable verdicts**, and the unified web+native verdict contract is a
completely open space. That gap is the product.

### Q2. Is the SwiftUI approach the most innovative available?

**Answer — the in-process strategy is the differentiator.** Rather than
assembling external tools (AX scraping, screenshots, XCUITest), VerdictUI
instruments SwiftUI from inside the layout pass using public API only: the
`Layout` protocol as a transparent probe, `PreferenceKey` frame streams, and
(Wave 4) Swift macros for compile-time instrumentation. The layout engine
itself emits the ground-truth semantic tree — nothing is reconstructed from
pixels or scraped trees after the fact.

### Q3. Does any competitor use this strategy?

**Answer — no.** No shipped product instruments SwiftUI's layout pass in-process
for verification. Existing tools are all out-of-process (XCUITest, AX scraping)
or pixel-based (snapshot testing).

### Q4. Does the critique apply to XCUITest too?

**Answer — yes.** XCUITest is out-of-process, black-box, slow (seconds per
query), and synchronization-blind. Decision: XCUITest is not the engine — it is
kept only as a **thin outer E2E smoke loop** for OS-level truths (permissions
dialogs, window management) that in-process code cannot see.

### Q5. Does the solution combine in-process AND out-of-process checking?

**Answer — yes, that is the architecture** (three concentric loops):
1. **Inner loop** — in-process probe + kernel verdicts on every edit (ms, no pixels).
2. **Middle loop** — external cross-validation per scenario: `AXUIElement` tree,
   real event injection, windowless pixel capture, reconciled against the
   in-process stream. **Divergence between the two views IS the bug detector.**
3. **Outer loop** — thin orchestrated XCUITest smoke.

### Q6. One-stop solution for SwiftUI + XCUITest + web?

**Answer — yes, by design.** The kernel (`VerdictUIKernel`) is platform-pure:
semantic tree, diff, lint rules, and the versioned verdict JSON schema contain
no UI-framework imports. SwiftUI is the first backend; a web backend (CDP-based)
consumes the same verdict contract later (deferred deliberately — `no.md`).
One schema means agents learn one wire format for native and web.

### Q7. What shortfalls in CDP / Playwright / axe-core can we solve?

**Answer — the cycle overhead, not the browser tech.** Playwright's perceived
slowness is mostly the MCP wrapper's chatty protocol and agent round-trips, not
browser concurrency. VerdictUI's web-facing answers, baked into the plan:
- **Atomic act-and-observe** — one call performs the action and returns the
  settled semantic delta + verdict (no act/screenshot/confirm round-trips).
- **Settle detection instead of sleeps** — rAF/MutationObserver (web),
  CATransaction/AXObserver + virtual clock (native).
- **Session pooling / multi-session** — warm daemon, parallel scenario sweeps.
- **Semantic diffing + layout linting** as first-class outputs, not screenshots.

## Monetization decision

**Open-core.** (Decided in the founding session.)

**The boundary is the MACHINE, not the feature** — see
[ADR 2026-021](../.decisions/2026-021-the-open-core-boundary-is-the-machine-not-the-feature.md),
which supersedes the founding session's feature-named split:

| Layer | License | Rationale |
|-------|---------|-----------|
| Everything that runs on ONE developer's machine — kernel, probe, macros, witness, pixel channel, CLI, daemon, MCP server, **local baselines including `BaselineStore`** | MIT | The SwiftUI engine is the adoption wedge — nothing comparable exists; open source drives trust + community rule contributions |
| Anything needing a SECOND PARTY — team-shared baselines with review by someone other than the author, cross-run/cross-machine history, hosted dashboards, a managed CI service on our infrastructure | Paid (none of it built yet) | Teams pay for workflow and history, individuals don't pay for engines |

Two corrections the ADR makes to the original table, both because the code
disagreed with it: `BaselineStore` was listed as paid "baseline management" but
is local single-machine file I/O and has shipped in the MIT kernel since Wave 6;
and **CI integration is NOT reserved** — running the CLI in a customer's own
runner is a local invocation, and charging for it would require an engine that
detects its CI environment and degrades.

Explicitly rejected: fully proprietary (kills adoption for a new-category dev
tool), fully free (no revenue), consulting-led (doesn't scale).

## Naming & brand

- **Name: VerdictUI** — chosen 2026-08-04 (the product's core output is a
  machine-readable verdict with evidence).
- **Domains**: `verdictui.com` and `verdictui.dev` confirmed available
  2026-08-04 (whois/RDAP). Registration is an owner action — tracked in TODO P1.
- Positioning phrase used throughout docs: replaces the
  *screenshot–wait–click–confirm* cycle with *atomic act-and-observe verdicts*.

## Distribution & go-to-market notes (from founding session)

- Primary early audience: developers running coding agents (Claude Code, Cursor)
  on Swift/SwiftUI projects — reached via the MCP server surface (Wave 7).
- Homebrew tap + downloadable CLI at first public release (TODO P2;
  `stage_auto_release` registered False in CEO PROPAGATION_PATTERNS until then).
- Open-source launch of the engine is itself the marketing event; the
  agent-native MCP angle is the differentiator to lead with.

## Decision log

| Date | Decision | Status |
|------|----------|--------|
| 2026-08-03 | Problem validated via 5-agent research survey; build decision taken | Done |
| 2026-08-04 | Name: VerdictUI; domains .com/.dev available, registration pending | Domains pending (owner) |
| 2026-08-04 | Open-core monetization: open engine, paid team workflow | Superseded by ADR 2026-021 |
| 2026-08-14 | Open-core boundary is the MACHINE not the feature; whole tree ships MIT; CI integration explicitly not reserved | Standing (ADR 2026-021) |
| 2026-09-02 | Docs ship at **vohux.com/verdictui** (child page under the Vohux site; the verdictui.com purchase becomes optional, not a blocker). Free/MIT **reconfirmed**: Wave 11 (in-vivo acting on Swift/AppKit/Web) strengthens the engine-as-wedge strategy — the tool Vohux itself runs fleet-wide is the value, and paid dev CLIs get zero adoption | Standing (ADR 2026-021 + owner 2026-09-02) |
| 2026-08-04 | XCUITest = thin outer smoke only, never the engine | Standing |
| 2026-08-04 | Web backend deferred until native engine proves the contract | **Superseded 2026-09-02** (`no.md` #85; Wave 11, `docs/spec-web-and-act.md`) |
| 2026-08-04 | Model for build sessions: Opus; 10-wave plan is execution SSoT | Standing |

> **Provenance note**: the original chat transcript was not retained on disk;
> this history was written the same day from the session's summarized record.
> Treat quoted-sounding phrasing as faithful paraphrase, not verbatim.

## verdictui.com / verdictui.dev — still available, capability present, PAYMENT is the only blocker

Measured 2026-08-31 (CTS-962D387A). The row had been carried as OWNER-ONLY with
no probe behind it, which is an unverified claim about our own capability.

**Both domains are still unregistered**, confirmed against the authoritative
registries with a known-registered control on the same endpoint each time:

| Domain | Endpoint | Result | Control on the same endpoint |
|---|---|---|---|
| `verdictui.com` | `rdap.verisign.com/com/v1` | **404 — not registered** | `vohux.com` → 200, created 2026-04-10 |
| `verdictui.dev` | `pubapi.registry.google/rdap` | **404 — not registered** | `launchgate.dev` → 200, created 2026-08-06 |

**We CAN register them; we cannot authorise the spend.** `CF_GLOBAL_API_KEY` has
registrar scope and lists all 12 fleet domains; `CF_API_TOKEN` does NOT (error
10000). The fleet is split across two Cloudflare credential standards and the
first one tried fails in a way that reads exactly like "no access". So the
blocker is payment — a genuinely human-only gate — and nothing else.

### Two instrument traps found on the way, both of which produced a wrong answer first

**1. Cloudflare's `available` / `can_register` are NOT registrability signals.**
Both fields read `False` for `verdictui.com` — and read `False` for
`kastdrive.com`, which this account OWNS. A session acting on them would conclude
the domains are taken and close this row on false evidence. The control is what
separates the two readings; without it the fields look authoritative.

**2. `rdap.org` returns an empty body for everything here**, including
`launchgate.dev`, which is definitely registered — so its silence is the
instrument failing, not the domain being free. Resolve the registry base from the
IANA bootstrap (`data.iana.org/rdap/dns.json`) instead; a hand-guessed
`www.registry.google/rdap/` also 404s on a registered domain.

**Falsify (both halves, controls included):**

```bash
curl -sSL -o /dev/null -w '%{http_code}\n' https://rdap.verisign.com/com/v1/domain/verdictui.com   # 404 = available
curl -sSL -o /dev/null -w '%{http_code}\n' https://rdap.verisign.com/com/v1/domain/vohux.com       # 200 = reader works
```

**Goal (stated without the mechanism):** a public marketing surface for VerdictUI
is reachable at a name we own.
