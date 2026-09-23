# Live macOS verification and input

Use `verdictui live inspect --pid <pid>` to discover the real Accessibility
hierarchy. Copy an observed structural path into an action request. The same
operations are available as `live_inspect`, `live_verify` and `live_act` over MCP.
No SwiftUI scenario registry is required for this path.

```sh
verdictui live inspect --pid 12345 --surface window:0 --pretty
verdictui live verify --pid 12345 --expect-text 'Settings' --pretty
# Replace the sample path with one returned by inspect:
verdictui live act --pid 12345 --path 0/1 --action click --expect-text 'Saved'
```

`--pid` observes an existing process; `--app /path/to/Fixture.app` launches an
owned fixture and closes it afterward. Choose exactly one. A surface selects a
window, menu or dialog supported by the existing AX adapter. Use a discovered
surface/path; indices and missing elements are validated before input.

Supported actions include AX press/set-value, click, type, key chords, drag and
hover. `--value` supplies text, a key chord such as `command+a`, or a drag
destination `x,y`. Typing can invoke application behavior, so use a purpose-built
test account or fixture for workflows that modify data.

The driver reads before-state, delivers input to the target process and exact
window, then reads after-state until three observations agree and any expected
text is present, or the deadline expires. `--timeout` is greater than zero and
at most 60 seconds. The result contains the observed change, findings and tree.
No expectation means the result includes `live-outcome-unasserted`; it does not
claim the intended business operation succeeded.

Exit 0 is a passing measured verdict, 1 is a measured defect or unmet assertion,
and 2 means input or observation was unavailable. Permission availability is
measured by the operation; an advisory permission flag is not treated as proof
of denial. A denied action never turns into a passing verdict.

The input path does not deliberately activate the app or move the desktop
pointer. Acceptance tests use transparent, real AppKit and SwiftUI fixture
windows and independently assert that their controls changed while foreground
application and pointer position stayed unchanged. Applications may themselves
activate another window or show an OS dialog in response to an action. These
tests are evidence for the exercised paths, not universal macOS automation
coverage.
