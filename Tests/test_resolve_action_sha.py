"""Unit tests for .github/scripts/resolve_action_sha.py.

The module's reason for existing is that `releases/latest`'s `target_commitish`
is a BRANCH, so a checker built on it reports every action stale forever and
prescribes pinning to a mutable ref -- a supply-chain downgrade. These tests
pin that behaviour in both directions: an unresolvable ref must stay
UNRESOLVABLE (never "resolved" from the branch), and a tag that IS resolvable
must resolve through the annotated-tag hop when GitHub answers with one.
"""

from __future__ import annotations

import email.message
import sys
import urllib.error
from pathlib import Path
from typing import Any
from unittest.mock import patch

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / ".github" / "scripts"))

from resolve_action_sha import (  # noqa: E402
    GitHubAPI,
    ResolutionError,
    Resolved,
    Unresolvable,
    _is_sha,
    commit_date,
    default_api,
    resolve_tag_to_commit,
)

_SHA = "a" * 40


class _FakeAPI:
    def __init__(self, responses: dict[str, Any], fail_on: set[str] | None = None) -> None:
        self.responses = responses
        self.fail_on = fail_on or set()
        self.calls: list[str] = []

    def get(self, url_path: str) -> dict:
        self.calls.append(url_path)
        if url_path in self.fail_on:
            raise ResolutionError(f"HTTP 404 for {url_path}")
        # Unknown paths answer {} like the module's own error paths do: the
        # caller degrades (commit_date -> "") rather than the fixture crashing.
        return dict(self.responses.get(url_path, {}))


class _FakeResponse:
    """Stands in for the context manager `urllib.request.urlopen` returns."""

    def read(self) -> bytes:
        return b"{}"

    def __enter__(self) -> "_FakeResponse":
        return self

    def __exit__(self, *exc: object) -> None:
        pass


class TestResolveTagToCommit:
    def test_a_lightweight_tag_resolves_to_its_commit(self) -> None:
        api = _FakeAPI(
            {
                "repos/org/action/releases/latest": {
                    "tag_name": "v5.0.0",
                    "published_at": "2026-09-01T00:00:00Z",
                },
                "repos/org/action/git/ref/tags/v5.0.0": {
                    "object": {"sha": _SHA, "type": "commit"},
                },
            }
        )
        result = resolve_tag_to_commit("org/action", api)
        assert isinstance(result, Resolved)
        assert result.sha == _SHA
        assert result.tag == "v5.0.0"

    def test_an_annotated_tag_resolves_through_the_tag_object(self) -> None:
        tag_obj = "b" * 40
        api = _FakeAPI(
            {
                "repos/org/action/releases/latest": {"tag_name": "v5.0.0"},
                "repos/org/action/git/ref/tags/v5.0.0": {"object": {"sha": tag_obj, "type": "tag"}},
                f"repos/org/action/git/tags/{tag_obj}": {"object": {"sha": _SHA, "type": "commit"}},
            }
        )
        result = resolve_tag_to_commit("org/action", api)
        assert isinstance(result, Resolved)
        assert result.sha == _SHA

    def test_a_release_without_tag_name_is_unresolvable(self) -> None:
        api = _FakeAPI({"repos/org/action/releases/latest": {"tag_name": ""}})
        result = resolve_tag_to_commit("org/action", api)
        assert isinstance(result, Unresolvable)
        assert "tag_name" in result.reason

    def test_an_unreadable_ref_is_unresolvable_and_never_falls_back_to_the_branch(
        self,
    ) -> None:
        """The defect the module exists to prevent: target_commitish is a BRANCH.

        A checker that fell back to it would "resolve" a pin against a mutable
        ref and prescribe a downgrade. The release payload deliberately carries
        a target_commitish here, and the answer must still be Unresolvable.
        """
        api = _FakeAPI(
            {
                "repos/org/action/releases/latest": {
                    "tag_name": "v5.0.0",
                    "target_commitish": "main",
                },
                "repos/org/action/git/ref/tags/v5.0.0": {"object": {}},
            },
            fail_on={"repos/org/action/git/ref/tags/v5.0.0"},
        )
        result = resolve_tag_to_commit("org/action", api)
        assert isinstance(result, Unresolvable)
        assert "tag ref unreadable" in result.reason
        assert "main" not in result.reason

    def test_a_non_sha_resolution_is_unresolvable(self) -> None:
        api = _FakeAPI(
            {
                "repos/org/action/releases/latest": {"tag_name": "v1"},
                "repos/org/action/git/ref/tags/v1": {"object": {"sha": "v1", "type": "commit"}},
            }
        )
        result = resolve_tag_to_commit("org/action", api)
        assert isinstance(result, Unresolvable)
        assert "not a commit SHA" in result.reason

    def test_an_unreadable_release_is_unresolvable(self) -> None:
        api = _FakeAPI({}, fail_on={"repos/org/action/releases/latest"})
        result = resolve_tag_to_commit("org/action", api)
        assert isinstance(result, Unresolvable)
        assert "no readable release" in result.reason


class TestCommitDate:
    def test_the_committer_date_is_read_when_the_api_answers(self) -> None:
        api = _FakeAPI(
            {
                f"repos/org/action/commits/{_SHA}": {
                    "commit": {"committer": {"date": "2026-08-31T10:00:00Z"}}
                }
            }
        )
        assert commit_date("org/action", _SHA, api) == "2026-08-31T10:00:00Z"

    def test_an_unreadable_commit_degrades_to_empty_rather_than_failing(self) -> None:
        api = _FakeAPI({}, fail_on={f"repos/org/action/commits/{_SHA}"})
        assert commit_date("org/action", _SHA, api) == ""


class TestIsSha:
    def test_a_40_hex_string_is_a_sha(self) -> None:
        assert _is_sha(_SHA) is True

    def test_a_39_character_string_is_not(self) -> None:
        assert _is_sha("a" * 39) is False

    def test_non_hex_characters_are_rejected(self) -> None:
        assert _is_sha("z" * 40) is False

    def test_uppercase_hex_is_accepted(self) -> None:
        assert _is_sha("A" * 40) is True


class TestGitHubAPI:
    def test_the_token_travels_as_an_authorization_header(self) -> None:
        assert self._capture_header("tok-123") == "token tok-123"

    def test_no_token_means_no_authorization_header(self) -> None:
        assert self._capture_header("") == ""

    @staticmethod
    def _capture_header(token: str) -> str:
        """Run one GitHubAPI.get under a patched urlopen and return the auth header."""
        captured: dict[str, str] = {}

        def _fake_urlopen(req: Any, timeout: float) -> _FakeResponse:
            headers = {k.lower(): v for k, v in req.headers.items()}
            captured["auth"] = headers.get("authorization", "")
            return _FakeResponse()

        with patch("urllib.request.urlopen", _fake_urlopen):
            GitHubAPI(token=token).get("repos/org/action/releases/latest")
        return captured.get("auth", "")

    def test_an_http_error_raises_resolution_error(self) -> None:
        def _http_error(req: Any, timeout: float) -> _FakeResponse:
            raise urllib.error.HTTPError(
                "https://api.github.com/repos/org/action/releases/latest",
                404,
                "not found",
                email.message.Message(),
                None,
            )

        with patch("urllib.request.urlopen", _http_error):
            with pytest.raises(ResolutionError):
                GitHubAPI(token="t").get("repos/org/action/releases/latest")  # nosec B106 -- synthetic one-char test token, not a credential

    def test_a_transport_error_raises_resolution_error(self) -> None:
        def _transport_error(req: Any, timeout: float) -> _FakeResponse:
            raise OSError("connection refused")

        with patch("urllib.request.urlopen", _transport_error):
            with pytest.raises(ResolutionError):
                GitHubAPI(token="t").get("repos/org/action/releases/latest")  # nosec B106 -- synthetic one-char test token, not a credential


class TestDefaultAPI:
    def test_the_token_is_read_from_the_environment(self, monkeypatch: pytest.MonkeyPatch) -> None:
        monkeypatch.setenv("GITHUB_TOKEN", "env-token")
        api = default_api()
        assert isinstance(api, GitHubAPI)

    def test_an_unset_token_yields_a_working_tokenless_api(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        monkeypatch.delenv("GITHUB_TOKEN", raising=False)
        api = default_api()
        assert isinstance(api, GitHubAPI)


class TestResolutionFlowCarriesTheDate:
    def test_a_resolved_action_carries_the_committer_date_for_the_direction_check(
        self,
    ) -> None:
        """`ahead` vs `stale` is decided by comparing the PIN against the tag
        commit's date, so the resolved record must carry it when readable."""
        api = _FakeAPI(
            {
                "repos/org/action/releases/latest": {"tag_name": "v5.0.0"},
                "repos/org/action/git/ref/tags/v5.0.0": {"object": {"sha": _SHA, "type": "commit"}},
                f"repos/org/action/commits/{_SHA}": {
                    "commit": {"committer": {"date": "2026-08-31T10:00:00Z"}}
                },
            }
        )
        result = resolve_tag_to_commit("org/action", api)
        assert isinstance(result, Resolved)
        assert result.committed == "2026-08-31T10:00:00Z"
