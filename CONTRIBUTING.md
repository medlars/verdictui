# Contributing to VerdictUI

VerdictUI is a verification engine. That makes its own test discipline the
product's argument: a verification tool whose tests pass for the wrong reason
is self-refuting. Most of what follows exists because a green signal here was
once measured to be meaningless.

## Getting set up

```bash
bash scripts/dev.sh                          # setup + build + test
swift test -Xswiftc -warnings-as-errors      # the suite as CI runs it
python3.14 scripts/verdictui-pm.py --quick   # project health (Grade A expected)
```

Requires a Swift 6 toolchain on macOS 13+ and Python 3.14 for the project
manager. The kernel is platform-pure and compiles without SwiftUI.

## The five rules that are not negotiable

### 1. The kernel stays platform-pure

`Sources/VerdictUIKernel` must never import SwiftUI, AppKit, or CoreGraphics.
The verdict engine has to run headless anywhere, which is why `Rect` is
hand-rolled rather than a `CGRect` alias. `stage_architecture` in the PM fails
the build if this is violated.

### 2. Public API only in the probe

`Sources/VerdictUIProbe` uses supported SwiftUI extension points and nothing
else. Private API (`_viewDebugData`, AttributeGraph interception) is powerful
and breaks across OS releases; if it ever ships it goes behind an explicit
optional adapter target, never on the core path. See `no.md` #1.

### 3. Evidence, not booleans

A `Verdict` cites node ids and rule names. A bare boolean in the public API is
a bug. If a rule cannot say *which node* and *by how much*, it is not finished.

### 4. Every guard gets a mutation row

`scripts/mutation-check.py` breaks each guard in turn and asserts that some
test notices. A guard with no row is an untested claim. Two things about rows
that have each cost a session here:

- **The mutation must still COMPILE.** Under `-warnings-as-errors`, deleting a
  statement often orphans a binding, and the compiler's exit 1 is
  indistinguishable from a failing assertion's at the harness boundary — so a
  row that builds nothing scores as a proven guard. Prefer discarding a result
  (`_ = f(x)`) over deleting a statement (`no.md` #25/#31).
- **Ask whether the WITNESS RAN**, not whether the row scored NOTICED. Grep the
  runner's `Executed N tests` line before believing any verdict.

Run a sweep on an **exclusive foreground tree** — a concurrent write or even a
concurrent PM run corrupts the verdict silently, in the direction that reads as
"this guard is untested" (`no.md` #14/#21/#39).

### 5. Contract changes move together

Any shape change to `Verdict` or `SemanticNode` bumps `SchemaVersion.current`,
`contracts/verdict-schema.json`, and the regenerated fixtures **in one commit**.
Agents parse this wire format; breaking it silently breaks every consumer.
`contracts/validate-contracts.py` fails the drift.

## Testing, and what a green suite does not prove

Test-alongside is enforced: a new source file needs a test file touched in the
same change. Beyond that, four blind spots are documented here because each was
found the expensive way:

- **A library suite cannot see the artifact.** The CLI was 8/8 green against a
  binary that could not execute a single command, because the defect was in how
  the process *starts* (`no.md` #32). Run the shipped binary. `swift test` will
  also rebuild a binary you stubbed for a negative control, which makes the
  control silently void — build once, then invoke the bundle directly.
- **A round-trip test cannot see a wire format.** Encoding and decoding with the
  same `Codable` tests the pair, never the published shape. Read raw JSON with a
  foreign parser against the documented keys (`no.md` #35).
- **A `--filter` green is evidence about the filter.** A filtered run reported
  8/8 twice while the full suite segfaulted at test 15 of 669; the process died
  *after* printing its summary. Run the full suite, and treat a present summary
  followed by a non-zero exit as a crash (`no.md` #44).
- **A macro render test executes the PREVIOUS expansion.** SwiftPM rebuilds the
  plugin but does not re-expand macros in a consuming target whose own sources
  are unchanged. After any hand-applied plugin change, `touch` every consuming
  test file before believing any run — red or green (`no.md` #23/#26).

## Thresholds are measured, never chosen

Every numeric gate in this repo came from a measurement, and the measurement is
recorded next to it. `maxDifferingFraction` defaults to 0 because a one-pixel
border regression moves only 2.45% of the frame. The pixel cache gates at 3x,
not the planned 10x, because the tree *is* the cache key and skipping the settle
would trade the channel's whole safety guarantee for a benchmark number.

If a threshold is wrong, re-measure and change it with the new measurement
recorded. Never move one to make a failure stop.

## `no.md` — read before re-litigating

`no.md` is a numbered log of things this project deliberately did **not** do,
each with the measurement that settled it. Several entries record a plausible
approach that was built and then reverted on evidence. Before proposing a change
that looks obviously right, check whether it is already there — and if you
believe an entry is wrong, say which measurement you are overturning.

New decisions of that kind get appended with the same shape: what was rejected,
what was measured, and the general rule that outlives the instance.

## Submitting a change

1. Branch from `main`.
2. Make the change with tests alongside and a mutation row for any new guard.
3. Run the full suite and the PM:
   ```bash
   swift test -Xswiftc -warnings-as-errors
   python3.14 scripts/verdictui-pm.py --quick
   ```
   Both must be green, and the PM grade must not regress.
4. Update `CHANGELOG.md` and `docs/FILE_REGISTRY.md` for new files.
5. Open a PR describing what you measured, not what you expect.

Architectural choices belong in `.decisions/` as an ADR. Use `/adr` if you have
the fleet tooling, or copy the shape of an existing record.

## Reporting bugs

Open a GitHub issue with the scenario, the verdict JSON, and the command you
ran. A verdict citing node ids is far more useful than a description of what
the screen looked like — that is rather the point of the tool.

## Licence

MIT. By contributing you agree your contributions are licensed under it.
