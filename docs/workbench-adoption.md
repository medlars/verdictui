# Workbench declared coverage

`workbench-connected-workflow` observes the real bundled WKWebView, native bridge,
helper and compiled consumer. It covers project selection, editing and saving a
check, real consumer PASS and FAIL results, running state, cancellation, retained
history, host reload and geometry. Captures include the default 1160×800 view and
the compact viewport recorded by the driver. Motion evidence describes the actual
OS and WebKit preferences; reduced-motion evidence cannot certify normal animation.

It does not certify file-picker interaction, trusted OS input, window management,
notifications, every user project, or installed artifacts outside this build.

Prepare cold builds explicitly, then observe the current product:

```sh
bash scripts/build-workbench-acceptance.sh debug
python3.14 scripts/workbench_coverage.py observe
```

The `.verdictui/run-workbench.py` executable also implements the consumer
`list` / `render workbench-connected-workflow` consumer protocol. It emits only
the actual final DOM tree after all native phases and current build identities
validate. Unavailable prebuilds return exit 2; there is no demonstration fallback.
The default warm native deadline is 25 seconds. Automatic hooks retain their own
overall deadline and may report unavailable if the full workflow cannot finish.

Each observation starts a new ignored coverage attempt before prebuild validation.
Layout comes from the packaged engine’s existing web rules judging the actual DOM tree. Behavior comes
from the native phase report. Paint remains unavailable until a separate reviewer
inspects **every** captured image and supplies a JSON review with `verdict: pass`,
`reviewer`, timezone-aware `reviewed_at`, exact `scope`, `run_id`, `report_sha256`,
an `images` map of every image filename to SHA256, and `criteria` containing
`alignment`, `clipping`, `contrast`, `state-clarity`, `motion-preference`.

```sh
python3.14 scripts/workbench_coverage.py review /absolute/path/to/review.json
```

Admission rechecks the complete native artifact report, actual binaries, source,
declarations and latest attempt. A later attempt invalidates any prior review.
Artifacts stay private outside the source tree. This is local supplied evidence
integrity, not authenticated certification. An automatic hook's independent
layout-only observation may supersede a manually reviewed receipt; new paint
review is then required. A verified scope never implies complete fleet adoption.
