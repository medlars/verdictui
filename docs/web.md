# Browser verification and actions

VerdictUI opens real websites in an owned, headless Chrome or Chromium process. It reads DOM layout into the shared semantic tree, applies the kernel rules, and can send browser input before observing the result. It does not use the built-in demo scenario catalog for these operations.

## CLI

The installed command exposes this shape, verified against `verdictui web --help`:

```text
verdictui web <operation> [<url>] [--profile <name>]
  [--node <returned-id-or-path>] [--action <verb>]
  [--text <nonsecret-text>] [--credential <reference>]
  [--key <key>] [--modifiers <comma-separated-modifiers>]
  [--expect-text <visible-outcome>] [--socket <path>] [--pretty]
```

| Operation | Required input | Result |
| --- | --- | --- |
| `list` | None | Sessions owned by this daemon, with profile, PID and sanitized URL |
| `open` | URL | Opens the profile, or navigates its existing owned browser |
| `render` | An open profile | Semantic tree with node IDs, paths and readable control names |
| `verify` | An open profile, or URL | Verdict for the page; a supplied URL first opens/navigates the profile |
| `act` | Action and its inputs below | Observed verdict, tree and before/after delta |
| `close` | An open profile | Closes the browser and releases ownership; profile data persists |

`--profile` defaults to `default`. The CLI starts its daemon when necessary, so separate commands can continue the same browser session. Use the same project/socket context for each command. `--socket` selects an explicit daemon socket. `--pretty` changes JSON formatting. `--help` and `--version` are also available.

For example, replace the URL with your application's address:

```bash
verdictui web open https://your-app.example/login --profile work
verdictui web render --profile work
verdictui web act --profile work --action credential \
  --node '<password-node-returned-by-render>' --credential WORK_LOGIN
verdictui web act --profile work --action submit \
  --node '<password-node-returned-by-render>' --expect-text 'Welcome'
verdictui web close --profile work
```

Use returned node IDs or structural paths; names such as “Password” help identify the correct node but are not selectors. Re-render after navigation or target replacement. Supported URLs are `http`, `https` and `file`, without embedded username/password fields.

## Actions and outcome assertions

| Action | Inputs | Behavior |
| --- | --- | --- |
| `click` | `--node` | Scrolls into view, checks current hit geometry, then posts trusted browser mouse input |
| `type` | `--node`, `--text` | Replaces an editable field's contents; literal typing into password fields is refused |
| `credential` | `--node`, `--credential` | Resolves a credential reference privately and replaces the editable field's contents |
| `key` | `--key`, optional `--node` and `--modifiers` | Optionally focuses a node, then posts a key chord |
| `submit` | `--node` | Clicks a button, presses Enter in a field, or uses a visible button within a form/container |

Keys include printable ASCII characters, `Enter`, `Tab`, `Escape`, `Backspace`, `Delete`, `ArrowLeft`, `ArrowUp`, `ArrowRight`, `ArrowDown`, `Home`, `End`, `PageUp`, `PageDown` and `Space`. Modifiers are `meta`, `control`, `alt` and `shift`, comma-separated.

Pass `--expect-text` to assert a visible, nonsecret application outcome. It must contain non-whitespace text and be at most 4,096 UTF-8 bytes. Input values are redacted, so assert outcomes such as a success heading rather than a field's contents. The driver waits for document/font readiness, quiet observed network requests and stable layout, and continues bounded observation for an unmet expectation. Never-ending activity can produce unavailable instead of a fabricated settled result.

An action with no expectation includes a `web-outcome-unasserted` warning: posted input and an observed tree do not establish task success. An unmet expectation produces a cited `web-expectation` error and a FAIL verdict. Empty or generic-only pages fail the kernel's vacuity guard.

The returned tree preserves CSS-visible content below the current viewport so an
agent can discover a control and ask VerdictUI to scroll to it. An expected text
match refers to that rendered document content; it does not assert that the text
is inside the current viewport. Hidden frames and recognized empty CSS `clip`/`clip-path` regions cannot satisfy
the expectation. Clicks require fresh geometry and hit testing after scrolling.

Browser layout checks use measured document and scroll regions. The iframe owner
is checked in its parent layout, while the embedded document is checked in its own
coordinate context. Fixed elements use their actual containing context. Wrapped
inline text and HTML elements are checked using their measured fragments, and CSS clipping is kept
separate from ordinary visible text extending outside a line box. Findings cite
the original returned tree; lint projections do not replace the evidence or the
coordinates used to perform actions.

Wrapped HTML inline boxes use native `Element.getClientRects()` in an isolated
browser world, including borders, padding and replaced content. The engine
resolves exact backend node identities, checks agreement with the snapshot, and
bounds collection to 4,096 inline elements, 100,000 fragments and a ten-second
capture budget. Missing, changed or excessive measurements produce unavailable.

Passive compound SVG graphics are checked as a composition; their owner still
participates in layout checks. Text, links, labelled or interactive descendants
keep their independent checks. Presentation-only clipping or overlap, and
uncertain internal SVG clipping, produce cited `web-paint-unverified` warnings.
These warnings establish neither a functional defect nor harmlessness: geometry
does not prove that composed paint leaves content visible. Normal-flow text
from the same measured inline formatting context can also have intersecting
font rectangles on different lines without colliding glyphs; those cases carry
the same explicit paint warning. Positioned, bordered, padded and interactive
boxes do not receive that qualification. Same-line and separate-context
collisions, and meaningful content clipping, remain errors. A later confirmed
collision takes priority over an earlier uncertain fragment. The full original
tree is retained.

**PASS means no confirmed errors in the checks performed. It does not certify
paint or occlusion.** When `web-paint-unverified` is present, the CLI prints an
explicit notice on stderr, and the desktop result, check and history badge call
out the unresolved paint review. Machine consumers must inspect findings as
well as status. JSON output and the three-valued exit contract remain unchanged.

Overlap inspection retains original nodes and refines candidate collisions with
measured text and inline border fragments. A shared limit of 2,000,000 work units bounds node visits,
raw fragments, fragment events, candidate comparisons and finding insertions
across paint scopes. Exhaustion returns
unavailable with `web overlap inspection exceeded its bounded work budget`; it
does not return a partial or passing verdict.

CLI exit codes are `0` for an answered PASS/success, `1` for an answered FAIL, and `2` when verification could not be performed. Browser absence, process loss, invalid targets, profile contention and protocol failures are unavailable errors, not passing verdicts. Error messages do not echo expected text or resolved credentials.

## MCP

The actual `tools/list` catalog exposes:

| Tool | Inputs |
| --- | --- |
| `web_list` | None |
| `web_open` | Required `url`; optional `profile` |
| `web_render` | Optional `profile` |
| `web_verify` | Optional `profile`, `expect_text` |
| `web_act` | Required `action`; `node`, `text`, `credential`, `key`, `modifiers` as appropriate; optional `profile`, `expect_text` |
| `web_close` | Optional `profile` |

Arguments use JSON strings. `profile` defaults to `default`. The CLI option `--expect-text` corresponds to MCP `expect_text`. MCP `web_verify` verifies the open page; navigate using `web_open` first. MCP render returns a compact tree whose `text` preserves safe accessible names, including ARIA names, associated labels and placeholder fallbacks. A FAIL verdict is an answered tool call with `isError: false`; an unavailable operation has `isError: true`.

One MCP server process owns its sessions. EOF and normal signal shutdown close them. It does not borrow another MCP process's or daemon's running profile.

## Profiles and configuration

Profiles default to `~/Library/Application Support/VerdictUI/web-profiles`. Each name identifies a separate Chrome user-data directory, including its cookies and browser storage. Closing a named session preserves that data. Reopening a profile after a detected browser crash starts a fresh owned browser process; dead sessions are evicted from the list.

Kernel-held locks prevent simultaneous ownership, including two sessions in the same process. A second owner fails rather than attaching to an unrelated browser. Profile names must be nonempty single path components and cannot be `.`, `..` or contain NUL. Temporary profiles used by `verdictui check` and the desktop workbench are separate from these named sessions.

| Environment variable | Meaning |
| --- | --- |
| `VERDICTUI_WEB_BROWSER` | Explicit executable path; invalid overrides fail instead of falling back |
| `VERDICTUI_WEB_PROFILE_ROOT` | Absolute nonempty profile root; used when an API caller has not supplied an explicit root |
| `VERDICTUI_WEB_CRED_<NAME>` | Named credential fallback or an `op://` pointer; names are uppercased for lookup |
| `VERDICTUI_WEB_OP` | Override the 1Password CLI executable; an empty value disables its lookup for controlled fixtures |

Without a browser override, discovery checks the standard macOS Chrome and Chromium installations. Environment configuration is captured by the owning daemon/MCP process; restart that process to apply changed environment settings. Use `verdictui daemon stop` for orderly daemon cleanup. SIGKILL cannot execute cleanup; a surviving browser's reserved profile must not be treated as an attachable replacement session.

## Credential references and output handling

Never put a password in `--text`, an MCP text argument, a URL, a command example or an expectation. Use an alias such as `WORK_LOGIN` or an explicit `op://vault/item/field` reference:

1. An explicit `op://` reference, including one configured behind an alias, uses `op read` and fails closed if it cannot be resolved.
2. A plain alias first requests the matching 1Password item's `password` field.
3. If that item cannot be resolved, the alias falls back to `VERDICTUI_WEB_CRED_<NAME>` in the process environment, then the shared `~/Projects/.env.shared` file. The file is parsed as data and is never sourced as shell code.

Only references enter the 1Password command arguments. Resolved values remain in driver memory and the browser's input channel. Browser stdout/stderr are discarded. Credential environment entries are removed from the browser child's environment. Returned input values and editable value descendants are masked; known typed values reflected in text, labels and metadata are redacted. URL username/password, query and fragment fields are removed from returned URL data. This does not promise automatic classification of every unrelated sensitive string already present on a page.

## Scope and limits

The measured path covers local clean/broken pages, trusted login and task completion, wrong-password outcomes, persisted identities, isolated concurrent profiles, same-origin frames, cross-origin renderer frames, delayed requests, accessible field names and browser-crash recovery.

This is a Chromium CDP driver with semantic/layout verification. It is not universal Playwright feature parity or a replacement for browser chrome, Safari/Firefox, OS dialogs, biometric authentication, downloads, uploads, screenshots, arbitrary JavaScript evaluation or the separate native macOS driver. Unavailable evidence stays unavailable. Rules applied to DOM geometry are not a full browser accessibility certification or a pixel comparison.

For project checks, only `web` and `live` declarations accept `expectText`. A `scenario` declaration requires `scenario`; an `appkit` declaration requires `runner` and `subject`. Fields belonging to another kind are rejected instead of being silently ignored. Cancelled checks report cancellation and wait for their owned command groups to stop before shutdown.

Positioned content uses measured DOM containing-block ancestry. An intermediate
static overflow container cannot invent clipping for content anchored outside
it; genuine containing-block clips remain enforced, including individual CSS
transforms. Controls are overlap subjects by their measured bounds even when
their label glyphs do not touch. Editable descendants remain redacted and are
excluded from the inline measurement inventory.

If a remote iframe appears between the parent snapshot and frame inventory,
VerdictUI discards that inconsistent capture and retries at most three times
under one capture deadline. Settling confirmations restart after recovery. A
persistent inconsistency, resource failure or cancellation stays unavailable;
the frame is never silently omitted from a passing result.
