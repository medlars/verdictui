# 2026-012 — Transports frame bytes and never dispatch, and blocking I/O stays off the render actor

**Date**: 2026-08-12
**Status**: Accepted
**Wave**: 7 (MCP surface + warm daemon transports)

## Context

`VerdictDaemon.handle` and `MCPServer.tools` shipped in Wave 6/7 as method
surfaces with no transport: nothing bound a socket, nothing read stdin, and
`verdictui` declared no `daemon` or `mcp` subcommand. Fourteen tests covered
them, and the runbook, changelog and contract all described a live wire
protocol — including a literal `nc -U` example against a path nothing created
(`no.md` #34).

Building the transports forced two structural decisions that are easy to get
wrong in the same way twice, and easy to "simplify" back into wrongness later.

The first is where dispatch lives. The product now has THREE surfaces that
answer `verify`: the CLI, a unix socket, and MCP over stdio. Each is a plausible
place to switch on a method name.

The second is which actor runs the transport. `VerdictDaemon.handle` is
`@MainActor` because rendering SwiftUI is, and the obvious reading is that the
loop calling it should be too.

## Decision

**1. A transport frames bytes and dispatches nothing.** `DaemonTransport` and
`MCPTransport` parse a frame, hand it to `VerdictDaemon.handle`, and encode what
comes back. Neither contains a `switch` over method names that produces an
answer. `MCPServer.daemonMethod(for:)` is a TABLE mapping tool name to daemon
method, not a second implementation — and
`MCPServerTests.testEveryAdvertisedToolResolvesToADaemonMethod` walks the catalog
to prove nothing is advertised that nothing serves.

**2. Blocking I/O runs off the main actor; only `handle` hops onto it.**
`serve()` is deliberately NOT `@MainActor`. `accept` and `read` block, and the
main actor is where the render each request needs must happen.

## Alternatives considered

**Let each transport answer for itself.** Rejected: three surfaces with their own
dispatch is how they drift into three answers, and nothing compares them. The
divergence would appear as "the CLI says PASS but the MCP tool says FAIL" long
after the change that caused it, with each surface's tests green because each
asserts its own copy. This is the two-implementations shape recorded fleet-wide
(lessons 284, 345) and locally in `no.md` #25, where the scenario macro carried a
second copy of the walk and stayed broken while the view macro was fixed.

**Keep `serve()` on the main actor for consistency with `handle`.** Rejected on
MEASUREMENT, not taste: it deadlocks. A blocking `accept` holds the actor for the
whole wait, so the daemon cannot render the scenario a request asked for, and an
in-process client can never be scheduled to connect. Measured at over ten minutes
with no output before the run was killed — and the log still printed a TRUE
`Executed 12 tests, with 0 failures`, because the suites that HAD finished
reported normally.

**A TCP listener instead of a unix socket.** Rejected in ADR 2026-011 and
unchanged here: a unix socket inherits filesystem permissions, so the OS answers
the authorization question rather than an auth layer this project would have to
write and get right.

## Consequences

- Adding a verb means adding it to `VerdictDaemon.handle` ONCE; all three
  surfaces gain it together, and a verb missing from a transport's table is a
  test failure rather than a runtime "unknown method".
- Connections are served one at a time. This is honest rather than limiting:
  `handle` is `@MainActor`, so concurrent requests would serialize on that actor
  regardless — parallel accept would only hide one client's slow render behind
  another's.
- The transports cannot be verified by the library suite. `stage_transport_smoke`
  drives the BUILT BINARY as a subprocess, because a library test structurally
  cannot see a process that refuses to start (`no.md` #32).
- `DaemonTransportConcurrencyTests` fails rather than hangs if anyone moves the
  syscalls back onto the main actor. A hang and a failure are not the same
  signal — a hung suite gets killed and read as "infrastructure was slow".

## Rollback

Revert commit `96825d5`. The method surfaces (`VerdictDaemon.handle`,
`MCPServer.tools`) predate it and are untouched by the revert, so the engine and
CLI keep working; only `verdictui daemon` / `verdictui mcp` and
`stage_transport_smoke` disappear. Restore the three docs to their
"NOT RUNNABLE YET" wording in the same commit — a runbook command that cannot run
is worse than a missing one.
