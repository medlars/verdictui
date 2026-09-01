"""Resolve a GitHub Action's latest release tag to the COMMIT SHA it points at.

A release's `target_commitish` is the BRANCH it was cut from ("main", "master"),
not the tag's commit. Comparing it against a 40-hex pin can never be equal, so a
checker built on it reports every action as stale forever and tells the reader to
pin to a mutable ref — which is a supply-chain downgrade, not an update.

Resolution goes through the git refs API, and an unresolvable action is a THIRD
state: "could not observe" and "observed and it is stale" demand opposite
responses, so they must never share a return value.

`releases/latest` is deliberately the source, and must stay that way. It honours
GitHub's `make_latest` flag, which is the only signal that orders releases
correctly. Sorting by `published_at` instead looks more rigorous and is far
worse: measured 2026-08-31, actions/checkout published v6.1.0, v5.1.0, v4.4.0 and
v3.7.0 AFTER v7.0.1 on the same day as maintenance backports, so a
newest-by-date checker would have recommended v7.0.1 -> v3.7.0 — a four-major
DOWNGRADE presented as an update. Do not "improve" this into date ordering.

What `releases/latest` can do is name a MOVING major tag ("v1") whose commit lags
the newest patch. Then a pin sitting on the newer patch differs from the resolved
commit and reads as stale, pointing BACKWARDS. That is why the resolved commit
carries its date: a pin that is NEWER than the tag is a fourth state, `ahead`,
and must never be reported as an update. Measured on anthropics/claude-code-action,
whose `releases/latest` is the moving `v1`.
"""

from __future__ import annotations

import json
import os
import urllib.error
import urllib.request
from dataclasses import dataclass

_SHA_LEN = 40


class ResolutionError(Exception):
    """The API could not be read for this action."""


@dataclass(frozen=True)
class Resolved:
    action: str
    tag: str
    sha: str
    published: str
    committed: str = ""  # committer date of `sha`; "" when it could not be read


@dataclass(frozen=True)
class Unresolvable:
    action: str
    reason: str
    sha: None = None
    tag: str = ""
    published: str = ""


def _is_sha(value: str) -> bool:
    return len(value) == _SHA_LEN and all(c in "0123456789abcdef" for c in value.lower())


class GitHubAPI:
    def __init__(self, token: str, timeout: int = 10) -> None:
        self._token = token
        self._timeout = timeout

    def get(self, url_path: str) -> dict:
        req = urllib.request.Request(f"https://api.github.com/{url_path}")
        if self._token:
            req.add_header("Authorization", f"token {self._token}")
        req.add_header("Accept", "application/vnd.github.v3+json")
        try:
            with urllib.request.urlopen(req, timeout=self._timeout) as response:
                return json.loads(response.read().decode())
        except urllib.error.HTTPError as exc:
            raise ResolutionError(f"HTTP {exc.code} for {url_path}") from exc
        except Exception as exc:
            raise ResolutionError(f"{type(exc).__name__} for {url_path}") from exc


def resolve_tag_to_commit(action: str, api) -> Resolved | Unresolvable:
    """Return the commit SHA the action's latest release tag points at."""
    try:
        release = api.get(f"repos/{action}/releases/latest")
    except ResolutionError as exc:
        return Unresolvable(action, f"no readable release: {exc}")

    tag = release.get("tag_name", "")
    published = release.get("published_at", "")
    if not tag:
        return Unresolvable(action, "release carries no tag_name")

    try:
        ref = api.get(f"repos/{action}/git/ref/tags/{tag}")
    except ResolutionError as exc:
        # Deliberately NOT falling back to target_commitish — that is the defect.
        return Unresolvable(action, f"tag ref unreadable: {exc}")

    obj = ref.get("object", {})
    sha, obj_type = obj.get("sha", ""), obj.get("type", "")

    if obj_type == "tag":  # annotated tag wraps the commit
        try:
            sha = api.get(f"repos/{action}/git/tags/{sha}").get("object", {}).get("sha", "")
        except ResolutionError as exc:
            return Unresolvable(action, f"annotated tag unreadable: {exc}")

    if not _is_sha(sha):
        return Unresolvable(action, f"resolved to {sha!r}, which is not a commit SHA")

    return Resolved(
        action=action,
        tag=tag,
        sha=sha,
        published=published,
        committed=commit_date(action, sha, api),
    )


def commit_date(action: str, sha: str, api) -> str:
    """Committer date of one commit, or "" when it cannot be read.

    "" is deliberate rather than an exception: a missing date must degrade the
    direction check to the old behaviour, never fail the whole resolution.
    """
    try:
        commit = api.get(f"repos/{action}/commits/{sha}")
    except ResolutionError:
        return ""
    return commit.get("commit", {}).get("committer", {}).get("date", "")


def default_api() -> GitHubAPI:
    return GitHubAPI(os.environ.get("GITHUB_TOKEN", ""))
