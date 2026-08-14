# Show HN draft

> Draft for the 1.0.0 launch. Not posted. Numbers here must match
> `docs/benchmarks.md` — if that file is re-measured, re-measure this.

## Title

Show HN: VerdictUI – SwiftUI verification without screenshots

(Alternates, all under HN's 80-char limit:
"Show HN: Verify SwiftUI layouts in 48ms without a screenshot" /
"Show HN: A verdict engine for SwiftUI, so agents stop screenshotting")

## Body

I got tired of watching coding agents verify SwiftUI work by screenshotting,
sleeping, clicking, and screenshotting again. It's slow, it's flaky, it needs
Accessibility permission, and it's blind between frames. XCUITest's idle-wait is
broken enough that teams patch it out, and SwiftUI has no `pumpAndSettle`.

VerdictUI makes SwiftUI testify about itself instead. Views instrumented through
public API — a transparent `Layout`-protocol probe, `PreferenceKey` frame
streams, or a `@Verifiable` macro — emit a semantic tree during the layout pass
itself. A platform-pure kernel turns that into a verdict with cited evidence:

    $ verdictui verify demo-undersized-tap-target
    {"status":"FAIL","findings":[{"rule":"tap-target","nodeID":"dismiss-button",
     "message":"'dismiss-button' is 18 x 18 pt, below the 28 x 28 pt minimum hit size",
     "suggestion":"grow the control or add .frame(minWidth: 28, minHeight: 28)"}]}

385 bytes. The equivalent screenshot costs an agent 1,365–2,117 vision tokens
and yields a picture it still has to interpret. That 13–20x token gap is the
real argument; the speed (48 ms in-process, 11 ms warm over MCP) is a bonus.

There's an MCP server, so an agent asks for a verdict instead of a screenshot —
seven tools including `act`, which applies an interaction and returns the
settled semantic delta rather than a new screenshot.

The part I'd defend hardest is what it does NOT do. It renders windowlessly and
never launches a process, so it cannot tell you the app started, cannot see a
permission dialog, and has no opinion about your kerning. XCUITest keeps those
jobs. The benchmark page has the loss column, and the flake-rate cells for the
screenshot and XCUITest columns are deliberately empty — there's no XCUITest
target in the repo, so any number I printed would be invented.

Some things I measured that surprised me, all in `no.md`:

- A 1px border regression moves only 2.45% of the frame, and an invisible
  near-black change touches the *same* 196 pixels. So the pixel diff gates on
  channel magnitude; the differing-pixel-count threshold every image-diff tool
  ships would swallow the real regression.
- The pixel cache gates at 3x, not the 10x I planned, because the semantic tree
  IS the cache key. Getting to 10x meant keying on something weaker, i.e.
  trading the only property that makes a stale hit impossible for a benchmark
  number.
- Writing the exit-gate test for the macro falsified the feature's headline
  claim: a `@Verifiable` view rendered through a scenario produced a tree with
  no probed node at all — the exact false-green the tool exists to prevent,
  sitting inside its own flagship feature and documented as working in three doc
  comments.
- And the release dogfood found that `@Verifiable` didn't compile on any
  `public` view — every view a library exports — because 777 tests were all
  written against internal fixtures.

MIT, Swift 6, macOS 13+. Open-core: everything that runs on one developer's
machine is open permanently; only a future team layer (shared baselines, history
across machines) is reserved.

https://github.com/medlars/verdictui

## Notes for posting

- Post Tue–Thu, 9–11am ET.
- Lead the comments with the "what it does not do" section; the honest loss
  column is the most credible thing here and HN rewards it.
- Expect "why not snapshot testing?" — answer: a snapshot test tells you
  something changed, a verdict tells you *what is wrong and where*, and a
  snapshot diff cannot be acted on by an agent without a vision round trip.
- Expect "why not XCUITest?" — answer with the 286 ms measurement: that is the
  median just to launch Calculator and wait for it to be responsive, before a
  single assertion, and a real app is seconds. Then concede the outer loop
  genuinely belongs to XCUITest.
- Do NOT claim flake numbers for the other approaches. We did not measure them.
