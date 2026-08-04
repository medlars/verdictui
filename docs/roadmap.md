# VerdictUI — Roadmap

> Phases in intended sequence. Current phase is bold.
> Update after each milestone ships: mark ✓, add next phase.
> Full execution detail per wave: `docs/implementation-plan.md`.

## Phase 0 — Scaffold ✓ (2026-08-04)

Project floor, buildable package (kernel + probe seeds), wave plan, registrations.

## **Phase 1 — Trustworthy Inner Loop (Waves 1–3)** ← CURRENT

**Goal**: An agent can render a probed SwiftUI view headless, act on it, and get a PASS/FAIL verdict with evidence in <100 ms — no screenshots, no sleeps.
**Waves**: 1 Kernel · 2 Probe runtime + oracle harness · 3 Settle engine ("pumpAndSettle for SwiftUI")
**Status**: In progress

## Phase 2 — Ergonomics & Agent Surface (Waves 4–7)

**Goal**: Zero-boilerplate adoption (`@Verifiable` macro, `#Preview` auto-registration) and the agent-facing surface (CLI + warm daemon + MCP server with atomic act→diff).
**Status**: Not started

## Phase 3 — Honest Channels (Waves 8–9)

**Goal**: Cross-validation (external AX tree + real events + windowless pixel diff reconciled against the in-process stream) and the deterministic pixel exception path with subtree-hash render caching.
**Status**: Not started

## Phase 4 — Proof & Release (Wave 10)

**Goal**: Dogfood on SagaMail/PanoMac, benchmark vs SLO, MIT release, Homebrew tap, docs site on verdictui.com.
**Status**: Not started

## Icebox (future ideas, not committed)

- Web backend behind the same CLI/MCP contract (assembly over CDP/Playwright engines)
- Optional private-API adapter (`_viewDebugData` backend) for apps that can't add the package
- Hosted workflow layer (baseline storage, team review, CI policy) — the open-core monetization
- UIKit/AppKit probe variants (NSViewController render-fleet pattern)
