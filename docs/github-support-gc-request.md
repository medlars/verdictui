# GitHub Support request — GC unreferenced objects (CTS-77D76C19)

**Status:** DRAFTED, NOT SENT. Filing needs an interactive sign-in at
support.github.com with 2FA, which is the owner-only carve-out to
Playwright-First. Everything below is ready to paste.

**File at:** https://support.github.com/request → *Account or profile* →
*Private information removal* (or the closest available category).

**Do not close CTS-77D76C19 on the reply.** A vendor saying "resolved" is a
claim, not evidence (DIR-034). Re-run the probe in *Verification* below and
require 404 before flipping the repository public.

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
