# GitHub Support request — GC unreferenced objects (CTS-77D76C19)

**Status:** **FILED 2026-08-15 — GitHub Support ticket
[#4668678](https://support.github.com/ticket/personal/0/4668678), confirmed
open.** Verified by re-navigating to *My Tickets* and finding the row, not by
trusting the submission banner (DIR-034). The text below is what was sent, kept
verbatim as the record of the claim.

**The "needs 2FA, owner-only" blocker recorded here for four sessions was
false.** It was never measured. Navigating to `support.github.com/contact-next`
landed on *Select an account* **already authenticated** as `medlars` — no
sign-in wall, and no 2FA prompt at any step through submission. There is
separately no support REST API (`gh api /support/tickets` → 404), so the web
form genuinely was the only route; it was simply reachable the whole time. A
recorded blocker is a claim with a timestamp (DIR-036), and this one cost four
sessions.

**Filed under:** *Repositories* → *Repository access issues*.

> **Do not use the obvious category.** *Repositories* → **Deletes** expands into
> a repository **purge** workflow whose required radio reads *"Please confirm
> your action. Once the repository is purged, it cannot be restored."* That is
> the opposite of this request — we want the repository kept and only the
> unreferenced objects removed — and submitting there could destroy it. The
> sent body therefore states explicitly: *"I am NOT asking for the repository to
> be deleted or purged."*

**Supporting fields, measured 2026-08-15**, ready for a follow-up reply if
Support asks (their docs request these):

| Field | Value |
|---|---|
| Affected pull requests | **2** — #9 and #5, both closed and merged (heads `33f7276`, `7c62e5c`); neither relates to the leak commits, but their `refs/pull/*` are GitHub-held refs Support must dereference |
| Orphaned LFS objects | **None** — no `.gitattributes`, no tracked LFS objects |
| Owner / repository | `medlars/verdictui` |

**Do not close CTS-77D76C19 on the reply.** A vendor saying "resolved" is a
claim, not evidence (DIR-034). Re-run the probe in *Verification* below and
require 404 before flipping the repository public.

**Blocker status — re-measured 2026-08-15, immediately before filing:** still
**LIVE**. Both pre-purge commits return HTTP 200 with the nine-file listing.
Containment intact: `private=true`, `forks=0`, `branches=main` only, `tags=0`,
`releases=0`, and `contents/.playwright-mcp?ref=main` → 404 — so the objects are
reachable from **no live ref** and are genuine GC candidates.
`measured: 2026-08-15` ·
`falsify: gh api "repos/medlars/verdictui/contents/.playwright-mcp?ref=4782a7177e1fd0624bea20904c79a237d1a758b0"`

---

## Subject

Request permanent removal of unreferenced objects containing personal data — medlars/verdictui

## Body

Hello,

I am the owner of the private repository `medlars/verdictui`. I need unreferenced
Git objects permanently removed (garbage-collected) because they still serve
personal data by direct SHA.

**What happened.** On 2026-08-14 a `git add -A` swept nine Playwright
accessibility snapshots into two commits, which were pushed during a roughly
25-minute window while the repository was public. The files capture a web
dashboard session and contain my home address, phone number, email address, and
a payment-account identifier.

**What I have already done, and verified:**

- Set the repository to private immediately on detection.
- Added the capture directory to `.gitignore`.
- Rewrote history with `git-filter-repo --path .playwright-mcp --invert-paths`
  and force-pushed `main` clean.
- Ran a second pass with `git-filter-repo --replace-text` after finding one
  remaining match in my own prose in a committed document.
- Deleted the `v1.0.0` tag and its release, because a tag is a live ref that
  kept the old commits reachable.

**Verified current state (re-measured 2026-08-15, immediately before writing):**
`branches` returns `main` only, `forks_count` is 0, `tags` is 0, there are 0
releases, and `contents/.playwright-mcp?ref=main` returns 404. No reachable
history matches any of the personal data strings.

That enumeration is the precondition for this request rather than a formality.
Objects reachable from ANY live ref are never garbage-collected, so a GC request
against them is a no-op that closes the ticket while the data stays fetchable —
measured elsewhere in this fleet, where data believed to be orphaned was
reachable from 28 live branches. Here the objects are reachable from no live ref,
which is what makes them genuine GC candidates.

**Why I still need your help.** A force-push moves a ref; it does not delete
objects. Both pre-purge commits remain fetchable by direct SHA:

- `4782a7177e1fd0624bea20904c79a237d1a758b0`
- `27de0b5f258db27e07103a557a909af4a246918f`

Reproduced today, 2026-08-15:

```
gh api "repos/medlars/verdictui/contents/.playwright-mcp?ref=4782a7177e1fd0624bea20904c79a237d1a758b0"
```

returns HTTP 200 with a listing of all nine files rather than 404. The same is
true for the second commit, and blob `12a918388197733800f668d2173a600b4f0a9ef3`
is served directly.

Anyone who recorded a SHA during the public window can still retrieve the data.
Please permanently remove these unreferenced objects so both commits return 404.

Thank you,
Eiman Rahimi

---

## Verification (run this yourself; do not trust the reply)

```bash
gh api "repos/medlars/verdictui/contents/.playwright-mcp?ref=4782a7177e1fd0624bea20904c79a237d1a758b0"
gh api "repos/medlars/verdictui/contents/.playwright-mcp?ref=27de0b5f258db27e07103a557a909af4a246918f"
```

PASS = **both return 404 Not Found.** Quote the URL — an unquoted `?` makes zsh
fail with a glob error that looks like a 404 and is not one.

Only after both return 404:

1. Flip the repository public.
2. Tag a fresh version — `v1.0.1`, never `v1.0.0`, whose SHA is burned.
3. Cut a release and restore `Formula/verdictui.rb` in `medlars/homebrew-tap`
   with a **re-measured** sha256.

---

## Follow-up request — 2026-08-17: `refs/pull/14/head` pins a second fragment

The first request (ticket **#4668678**) succeeded: both original leak commits
now return **404**, verified with a probe proven live in both directions
(a positive control against `HEAD` returns the real sha and file listing, so
the 404 is a real absence and not a broken apparatus).

A follow-up is needed for a **different** commit, found by scanning reachable
history for the identifier **strings** rather than the filenames — the same
two-shapes lesson as before (`no.md` #54): the tool-written FILES and the
human-written PROSE describing them are separate leaks, and removing one does
nothing about the other.

**What remains:** commit `89198bc40beea1d78bd3436e545e5f03cf398049`,
file `docs/wave-status.md`, contains a payment-card last-four written out in prose. The email beside it was already correctly redacted.

**Remediation already done on our side (2026-08-17):**

- History rewritten with `git filter-repo --replace-text`, replacing the exact
  phrase with a redaction marker (a replacement, not a deletion — the marker is
  present in the rewritten commit, which proves the file survived intact).
- `main` force-pushed: `a0433db` → `f325b99`
- `feat/appkit-merged` force-pushed: `a011999` → `f5befcf`
- Verified from a **fresh clone of the live remote**: all branch refs return
  **0** matches for the payment-card phrase. 278 commits preserved on `main`.

**Why we cannot finish it ourselves:** the commit is pinned alive by
`refs/pull/14/head` (PR #14, MERGED). That is a GitHub-held ref — a force-push
cannot move it. Measured against the live remote after our push:

| ref | the payment-card phrase matches |
|---|---|
| `refs/heads/main` | 0 |
| `refs/heads/feat/appkit-merged` | 0 |
| `refs/pull/5/head`, `refs/pull/9/head` | 0 |
| **`refs/pull/14/head`** | **1** |

And it is still served:
`gh api "repos/medlars/verdictui/contents/docs/wave-status.md?ref=89198bc4…"`
returns 200 with content containing the string (size 153746).

**The ask:** please dereference/expire `refs/pull/14/head` for PR #14 and run
GC so commit `89198bc40beea1d78bd3436e545e5f03cf398049` is no longer fetchable.
As before: **we are NOT asking for the repository to be deleted or purged.**

**Verification we will run before considering this closed** (per DIR-034 — the
vendor's reply is a claim, not evidence):

```
gh api "repos/medlars/verdictui/contents/docs/wave-status.md?ref=89198bc40beea1d78bd3436e545e5f03cf398049"
```

must return **404**. Note the quoting: an unquoted `?` makes zsh fail with a
glob error whose exit 1 reads exactly like a 404 and is not one.

**The repository stays PRIVATE until that probe returns 404.**
