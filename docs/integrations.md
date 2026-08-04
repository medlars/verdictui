# VerdictUI — Integrations

> SSoT for all connections into and out of this project.
> Update when adding/removing any API, dependency, or cross-project call.

## Outbound — APIs & External Services

| Service | Purpose | Auth method | Token location | Expiry/rotation |
|---------|---------|-------------|----------------|----------------|
| GitHub (medlars/verdictui) | Repo + CI | gh CLI | system keychain | n/a |
| *(none at runtime — local-first by design)* | | | | |

## Inbound — Who Calls This Project

| Caller | How | Endpoint/interface | Auth |
|--------|-----|--------------------|------|
| AI agents (Claude Code, Cursor) | MCP (Wave 7) | verdictui MCP server tools | local stdio |
| Developer CLIs | CLI (Wave 6) | `verdictui render/act/verify/baseline` | none (local) |
| Host apps under test | SPM dependency | `VerdictUIProbe` + `VerdictUIKernel` | n/a |

## Cross-Project Dependencies

| Project | Direction | What is shared | Failure impact |
|---------|-----------|----------------|----------------|
| shared-libs/pm-base | Imported (PM only) | PmBase, governance stages | PM won't run |
| shared-libs/release-tools | Imported (PM only) | swift_runner (build/test with zombie-lock handling) | PM build/test stages fail |
| SagaMail, PanoMac | Consumers (Wave 10) | Dogfood targets for the probe package | none (they gate release readiness) |

## Authentication & Token Inventory

| Token/credential | Used by | Storage | Expiry | Refresh mechanism |
|-----------------|---------|---------|--------|------------------|
| *(none)* | | | | |

## Action Flows (feature → external)

| Feature | Steps | External calls | Auth required | Failure mode |
|---------|-------|----------------|---------------|-------------|
| Verify scenario (inner loop) | CLI/MCP → daemon → in-process oracle → Verdict JSON | none | none | structured error verdict |
| Cross-validate (Wave 8) | daemon → AXUIElement + CGEventPostToPid + capture | macOS Accessibility API | Accessibility permission | degrade to inner-loop-only verdict with warning |

## Architecture Gaps

- [ ] (none at scaffold — fill in as discovered)
