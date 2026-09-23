# Native input fixture

`Fixture.swift` is a disposable app with two modes, `appkit` and `swiftui`.
It creates an accessory app with a transparent, non-animating window. It never
activates itself. Actual event handlers update a JSON state file and a
`native-status` accessibility label:

```text
text=Hello;clicks=2;dragEvents=1;keyChords=1
```

The input canvas is named `Native input canvas`. Its physical handlers receive
text, Control+Z, click, drag, and mouse-move events. It does not implement AXPress,
so `press` exercises the Quartz fallback. SwiftUI mode also contains a genuine
SwiftUI button named `SwiftUI increment`, operated through its AXPress action.

Run both modes, including real input receipt, unchanged foreground app and
cursor, and a window visibility check:

```bash
VERDICTUI_NATIVE_INTEGRATION=1 swift test --jobs 2 \
  -Xswiftc -warnings-as-errors --filter NativeInputIntegrationTests
```

This is an explicit live lane. Without the environment variable these two tests
are skipped. When opted in, missing event permission or an unreadable fixture
fails the test. The driver unit tests always run and inject permission denial.

The test compiles the fixture with `xcrun swiftc -parse-as-library` into a
temporary `.app` with `LSUIElement=true`, then launches it with:

```bash
open -gj -n -a /path/to/LiveAppFixture.app --args /path/to/state.json appkit
```

State fields are `pid`, `mode`, `text`, `clicks`, `dragEvents`, `keyChords`,
`mouseMoves`, `x`, `y`, `windowID`, `alpha`, and `lastMouse`. Coordinates name the
canvas centre in global display points. The diagnostic `lastMouse` records only
the fixture's own mouse delivery. Terminate only the PID in this fixture's state
file after use; the fixture also exits automatically after 60 seconds.
