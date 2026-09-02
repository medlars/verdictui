# Spec — Wave 11: Acting. OS events, AppKit parity, and the web backend

Status: Proposed (2026-09-02) · Owner directive: "VerdictUI becomes the single
tool to test Swift, AppKit, and web apps — not only to test them, but also to
make changes in them, such as logging to a website and doing a task inside it,
without distracting the user or obscuring the user's screen."
Confirmed mid-review (owner): the target is **in-vivo** — VerdictUI drives the
REAL Swift/AppKit/Web apps, not only headless scenarios. In-vitro (the existing
scenario harness) remains the fast inner loop; in-vivo acting (T6/T7) and real
browser sessions (T1–T5) are this wave's additions.

## Problem

Three measured gaps separate VerdictUI from that goal:

1. **No OS-level acting.** The inner loop drives scenario bindings only
   (`Sources/VerdictUIProbe/Actions.swift:4`: "no CGEvent synthesis, no
   Accessibility"); the witness path can AX-press a button
   (`AXReader.swift:110/236`) but cannot type text, move a mouse, drag, or send
   modifier keys. XCUITest-class power (real events, app lifecycle, system
   dialogs) is absent, and `docs/benchmarks.md:169` concedes the point.
2. **No web backend.** Zero web references in `Sources/`. The Playwright stack
   this would replace is, per the owner: slow, inconsistent, single logins can
   fail, and two concurrent sessions confuse each other.
3. **AppKit parity is judge-only.** `verdictui appkit` renders and judges
   headlessly but cannot act on a live AppKit app — the same gap as (1).

## Goals

- G1 — VerdictUI can ACT on a live macOS app (SwiftUI or AppKit): click,
  type, press keys with modifiers, drag — with permission-honest degradation
  (an unavailable event tap is exit 2 + an explicit warning finding, never a
  silent pass).
- G2 — VerdictUI can test a web app end-to-end: discover, render to a
  SemanticNode tree, judge with the existing kernel rules, and verify —
  three-valued exit codes preserved (a browser that fails to launch is exit 2,
  never a UI defect).
- G3 — VerdictUI can ACT on a web app: trusted input events (click, type,
  submit), including login flows, headlessly and invisibly.
- G4 — Concurrency isolation by construction: two sessions can never share a
  browser instance or profile.
- G5 — Credentials never touch code, verdicts, or logs.

## Non-goals

- No iOS simulator / mobile support in this wave.
- No pixel baselines for web in the first increment (semantic tree + verdict
  first; the pixel channel generalizes later).
- No change to the existing demo catalog, kernel rules, or wire schema
  (no SchemaVersion bump: the web surface reuses the existing contract).

## Design

### Deliberation A — web driver strategy (three options, DIR-010)

1. **CDP spoken directly from Swift (CHOSEN).** Spawn the installed stable
   Chromium-channel browser with `--headless=new --remote-debugging-port=0`
   and a per-session `--user-data-dir`; speak CDP over
   `URLSessionWebSocketTask` (macOS 13+ floor holds), discovering the port
   from DevTools' discovery output. Trusted input via
   `Input.dispatchMouseEvent`/`Input.dispatchKeyEvent`; one-shot DOM + layout
   via `DOMSnapshot.captureSnapshot` mapped to SemanticNodes (ARIA/implicit
   roles, CSS-px frames, text boxes for `TextMetrics`).
2. Wrap a browser in kiosk mode and drive it with synthetic JS events —
   rejected: visible windows violate G3, and JS-synthesized events are the
   automation fingerprint that makes logins fail.
3. Adopt a third-party Swift CDP wrapper — rejected: no mature, boring,
   well-documented Swift CDP library exists; the CDP protocol itself is the
   stable artifact (Chrome's documented DevTools protocol), and only ~10
   domains are needed.

Why (1) wins on the owner's pains: **login reliability** = trusted input
events + persistent per-identity profiles (cookies/localStorage survive), not
throwaway automation contexts; **speed** = a persistent browser per session
(no per-check launch); **screen** = `--headless=new` has no window server
surface at all; **concurrency** = G4 below.

### Deliberation B — macOS event injection (three options)

1. **CGEvent + AX hybrid (CHOSEN).** Target elements by structural path via
   AX (the read vocabulary is already one implementation); perform press-like
   actions by AX action when available, else synthesize a CGEvent mouse click
   at the element's frame; synthesize CGEvent keyboard for text and modifier
   keys; CGEvent drag for gestures. All public API.
2. AX-actions-only — rejected: cannot type, drag, or send modifiers (G1
   unmet).
3. An XCUITest-style outer runner — rejected: pays the launch-and-runner cost
   this product exists to kill.

Permission honesty (SD6 discipline): `AXIsProcessTrusted` is never the gate;
the event path is decided by whether the READ/ACTION succeeds, and denial
becomes an explicit finding + exit 2 on act flows.

### Concurrency, credentials, invisibility (G3–G5)

- **Profiles**: `~/Library/Application Support/VerdictUI/web-profiles/<name>/`
  — a named identity (cookies persist across runs); each *session* gets its
  own profile directory; a file lock per profile under `.../locks/` with
  pid-liveness theft (`kill -0`, never a framework registry lookup) so a
  crashed run's lock is recoverable and a live one never stolen. Two sessions
  therefore cannot attach to one browser by construction.
- **Credentials**: resolution order — 1Password CLI item, else
  `.env.shared` (`VERDICTUI_WEB_CRED_<NAME>`); never argv, never code, never
  the verdict JSON (redaction at the boundary, same class as the CIS
  store's literal redaction).
- **Invisibility bar**: no window in `CGWindowList` for the browser pid —
  pinned by a test with a positive control (a real window IS detected),
  mirroring the witness-window discipline (no.md #47/#50).

## Test plan

Every task lands tests alongside (rule 3) and mutation rows for new guards
(rule 6); artifact-level smoke through the built binary; no network
dependency in the suite — the web fixtures are bundled `file://` pages,
including a login form fixture. Concurrency matrix: two parallel sessions on
distinct profiles assert zero cross-attach. Invisibility: CGWindowList empty
for the browser pid, with the real-window positive control.

## Rollout and rollback

Each task ships a verb behind the existing catalog mechanism
(`contracts/mcp-tools.md` is the required-set source). Rollback is additive:
the web module is its own target; removing it leaves the existing surface
byte-identical, and the profile/lock directories are inert when unused.

<!-- SENTINEL-APPEND -->

## Wave 11 task decomposition (T1–T8)

| Task | Deliverable | Exit gate |
|---|---|---|
| T1 | Web-profile registry + lock registry + Chromium discovery + headless process lifecycle (launch, ephemeral port, health probe, `kill -0` liveness, terminate) | A launched browser answers a health probe; two sessions on one profile: second blocks; crashed-run lock stolen only after liveness check; zero CGWindowList entries (positive control: a real window IS seen) |
| T2 | CDP transport over `URLSessionWebSocketTask` (DevTools discovery, JSON-RPC framing, timeouts, fail-closed) | Talks to the T1 browser; a dead browser is exit 2 with a named reason, never a timeout hang; fake-WS unit tests + live integration |
| T3 | `DOMSnapshot.captureSnapshot` → SemanticNode assembly (ARIA/implicit roles, CSS-px frames, text boxes) | A bundled `file://` fixture page renders a tree the kernel judges; the kernel's `vacuous-verdict` guard still fires on an unprobed-mapping page |
| T4 | `verdictui web list/render/verify` through `VerdictDaemon.handle` (one-handler rule), MCP catalog + contract rows updated | cli_smoke-class stage drives the BUILT binary against the fixture site; exit 0/1/2 all asserted (0 clean, 1 planted defect, 2 browser-down) |
| T5 | Web act: trusted click/type/submit + login smoke against the local login fixture (credentials via G5 resolution) | Login-then-task flow passes; wrong password FAILS with a cited finding; credentials never appear in argv/verdict/log (asserted by a scan of the process argv + captured output) |
| T6 | macOS act: CGEvent+AX hybrid (click, type, modifiers, drag) with AX-path targeting + permission-honest paths | A bundled fixture app is driven end-to-end (type into a field, click a button, assert the app's own state changed); event-tap-denied path returns exit 2 + warning finding |
| T7 | Live-AppKit parity: act on a running AppKit app the same way; `docs/appkit.md` updated | The fixture AppKit app is judged AND acted on through the same verbs; SwiftUI and AppKit paths share the driver (no second dispatch) |
| T8 | Fleet integration: credentials doc, benchmarks.md row, `contracts/mcp-tools.md` rows, concurrency matrix, changelog | PM --full Grade A; two-session matrix green; every new verb documented in the contract the gates read |

Wave exit gate: all eight tasks closed with their gates; PM Grade A; the
demo catalog untouched (pinned by its own tests); no SchemaVersion bump.
