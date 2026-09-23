#!/usr/bin/env python3.14
"""Render the bundled workbench with an external, in-memory test bridge.

This script never invokes the verification engine or uses a user's application.
Missing dependencies or browser runtimes fail the gate; they never count as passes.
"""

from __future__ import annotations

import argparse
import io
import json
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

BROWSERS = ("chromium", "webkit")
DEFAULT_ROOT = Path(__file__).resolve().parent.parent
FIXTURE_STATE = {
    "type": "state",
    "projects": [
        {"path": "/tmp/fixture-product", "name": "Fixture product"},
        {"path": "/tmp/other-product", "name": "Other product"},
    ],
    "selectedProject": "/tmp/fixture-product",
    "checks": [
        {"name": "Settings layout", "kind": "scenario", "scenario": "settings"},
        {
            "name": "Account page",
            "kind": "web",
            "url": "https://example.test/account",
            "expectText": "Account settings",
        },
    ],
    "history": [],
    "version": "test harness",
}
MOCK_BRIDGE = (
    "window.testMessages=[];"
    "window.webkit={messageHandlers:{verdictui:{postMessage:m=>window.testMessages.push(m)}}};"
)


class SmokeFailure(AssertionError):
    """A named browser assertion failed; later dependent actions cannot run."""


@dataclass
class SmokeRun:
    """Counts measured assertions, failures, and complete browser flows separately."""

    passed: list[str] = field(default_factory=list)
    failures: list[dict[str, str]] = field(default_factory=list)
    completed_browsers: list[str] = field(default_factory=list)

    def assertion(self, name: str, condition: bool) -> None:
        if not condition:
            self.failures.append({"name": name, "message": "assertion failed"})
            raise SmokeFailure(name)
        self.passed.append(name)

    def unavailable(self, name: str, message: str) -> None:
        self.failures.append({"name": name, "message": message})

    def summary(self) -> dict[str, Any]:
        complete = set(self.completed_browsers) == set(BROWSERS)
        measured = all(
            any(name.startswith(browser + " ") for name in self.passed) for browser in BROWSERS
        )
        success = complete and measured and not self.failures
        return {
            "status": "PASS" if success else "FAIL",
            "passed": len(self.passed),
            "failed": len(self.failures),
            "completedBrowsers": self.completed_browsers,
            "expectedBrowsers": list(BROWSERS),
            "checks": self.passed,
            "failures": self.failures,
        }


def report(run: SmokeRun, artifact_dir: Path) -> int:
    summary = run.summary()
    artifact_dir.mkdir(parents=True, exist_ok=True)
    (artifact_dir / "verification.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(json.dumps(summary, indent=2))
    print(
        f"WORKBENCH SMOKE {summary['status']}: "
        f"{summary['passed']} passed, {summary['failed']} failed, "
        f"{len(run.completed_browsers)}/{len(BROWSERS)} browser flows complete"
    )
    return 0 if summary["status"] == "PASS" else 1


def receive(page: Any, message: dict[str, Any]) -> None:
    page.evaluate("(m)=>window.verdictui.receive(m)", message)


def animation_count(page: Any) -> int:
    return page.evaluate(
        'document.getAnimations().filter(a=>a.playState==="running" && a.effect.getTiming().iterations===Infinity).length'
    )


def bounds(page: Any) -> dict[str, Any]:
    return page.evaluate(
        """()=>({viewport:innerWidth,document:document.documentElement.scrollWidth,
        rects:Object.fromEntries(['.sidebar','.workspace-header','.verification-stage',
        '.lens-body','.verification-copy','.evidence-panel'].map(s=>{
        const r=document.querySelector(s).getBoundingClientRect();
        return[s,{x:r.x,y:r.y,width:r.width,height:r.height,right:r.right,bottom:r.bottom}]}))})"""
    )


def exercise(
    browser_name: str, browser: Any, root: Path, artifact_dir: Path, run: SmokeRun
) -> None:
    from PIL import Image, ImageChops

    check = run.assertion
    url = (root / "Sources/VerdictUIWorkbench/Resources/index.html").as_uri()
    page = browser.new_page(viewport={"width": 1000, "height": 700}, device_scale_factor=2)
    errors = []
    network_attempts = []

    def reject_network(route: Any) -> None:
        network_attempts.append(route.request.url)
        route.abort()

    page.route("https://**", reject_network)
    page.route("http://**", reject_network)
    page.on("pageerror", lambda error: errors.append(str(error)))
    page.goto(url)
    check(
        browser_name + " missing bridge unavailable",
        "unavailable" in page.locator("#notice").inner_text(),
    )
    check(browser_name + " missing bridge disables run", page.locator("#run-checks").is_disabled())
    page.screenshot(path=str(artifact_dir / (browser_name + "-disconnected.png")))
    page.add_init_script(MOCK_BRIDGE)
    page.reload()
    receive(page, FIXTURE_STATE)
    check(browser_name + " ready bridge", page.evaluate("testMessages[0].action") == "ready")
    check(
        browser_name + " selected path",
        page.locator("#project-path").inner_text() == "/tmp/fixture-product",
    )
    nav_sizes = page.locator(".nav-item").evaluate_all(
        "(els)=>els.map(e=>e.getBoundingClientRect().height)"
    )
    check(browser_name + " navigation sibling heights match", len(set(nav_sizes)) == 1)
    page.locator("[data-view=checks]").click()
    field_sizes = page.locator("#check-0-name,#check-0-kind").evaluate_all(
        "(els)=>els.map(e=>({width:e.getBoundingClientRect().width,height:e.getBoundingClientRect().height}))"
    )
    check(browser_name + " editor sibling fields align", field_sizes[0] == field_sizes[1])
    (artifact_dir / (browser_name + "-sibling-rects.json")).write_text(
        json.dumps({"navigationHeights": nav_sizes, "fields": field_sizes}, indent=2)
    )
    page.locator("[data-view=overview]").click()
    page.locator("#choose-project").click()
    check(
        browser_name + " project chooser bridge",
        page.evaluate("testMessages.at(-1).action") == "chooseProject",
    )
    page.locator(".project-button", has_text="Other product").click()
    check(
        browser_name + " project selection bridge",
        page.evaluate("testMessages.at(-1).project") == "/tmp/other-product",
    )
    page.locator("#run-checks").click()
    check(browser_name + " run bridge", page.evaluate("testMessages.at(-1).action") == "run")
    check(browser_name + " no pretend motion while starting", animation_count(page) == 0)
    receive(
        page,
        {
            "type": "progress",
            "index": 0,
            "total": 2,
            "name": "Settings layout",
            "status": "running",
        },
    )
    check(browser_name + " actual work animates", animation_count(page) >= 3)
    check(
        browser_name + " running index not counted",
        page.locator("#progress-count").inner_text() == "0 / 2 completed",
    )
    first = Image.open(io.BytesIO(page.locator(".lens-scene").screenshot())).convert("RGB")
    page.wait_for_timeout(180)
    second = Image.open(io.BytesIO(page.locator(".lens-scene").screenshot())).convert("RGB")
    check(
        browser_name + " rendered animation advances",
        ImageChops.difference(first, second).getbbox() is not None,
    )
    page.screenshot(path=str(artifact_dir / (browser_name + "-running-1000.png")))
    measured = bounds(page)
    check(browser_name + " desktop no overflow", measured["document"] == 1000)
    (artifact_dir / (browser_name + "-rects-1000.json")).write_text(json.dumps(measured, indent=2))
    receive(
        page,
        {"type": "progress", "index": 0, "total": 2, "name": "Settings layout", "status": "pass"},
    )
    receive(
        page,
        {"type": "progress", "index": 0, "total": 2, "name": "Settings layout", "status": "pass"},
    )
    check(
        browser_name + " duplicate completion counted once",
        page.locator("#progress-count").inner_text() == "1 / 2 completed",
    )
    receive(page, {"type": "progress", "index": 2, "total": 2, "name": "Invalid", "status": "pass"})
    check(
        browser_name + " invalid progress cannot inflate count",
        page.locator("#progress-count").inner_text() == "1 / 2 completed",
    )
    page.emulate_media(reduced_motion="reduce")
    check(browser_name + " reduced motion stops every loop", animation_count(page) == 0)
    page.emulate_media(reduced_motion="no-preference")
    page.locator("#cancel-run").click()
    check(
        browser_name + " cancellation bridge",
        page.evaluate("testMessages.at(-1).action") == "cancel",
    )
    check(
        browser_name + " cancelling awaits engine",
        page.locator("#verification-stage").get_attribute("data-status") == "running",
    )
    report = {
        "status": "fail",
        "checks": [
            {"name": "Settings layout", "status": "pass", "verdict": {"findings": []}},
            {
                "name": "Account page",
                "status": "fail",
                "verdict": {
                    "findings": [
                        {
                            "rule": "text-truncation",
                            "severity": "error",
                            "nodeID": "account/title",
                            "message": "The account title does not fit its available width.",
                        },
                        {
                            "rule": "target-size",
                            "severity": "warning",
                            "nodeID": "account/save",
                            "message": "The Save button has a small hit area.",
                        },
                    ]
                },
            },
        ],
    }
    receive(page, {"type": "result", "report": report})
    check(browser_name + " result stops animation", animation_count(page) == 0)
    check(browser_name + " evidence rendered", page.locator(".finding").count() == 2)
    check(
        browser_name + " verdict fail visible",
        page.locator("#verification-stage").get_attribute("data-status") == "fail",
    )
    page.screenshot(path=str(artifact_dir / (browser_name + "-findings-1000.png")))
    page.set_viewport_size({"width": 360, "height": 780})
    check(browser_name + " mobile no overflow", bounds(page)["document"] == 360)
    page.screenshot(path=str(artifact_dir / (browser_name + "-findings-360.png")), full_page=True)
    (artifact_dir / (browser_name + "-rects-360.json")).write_text(
        json.dumps(bounds(page), indent=2)
    )
    page.locator("[data-view=checks]").click()
    page.locator("#add-check").click()
    page.locator("#check-2-name").fill("Native app")
    page.locator("#check-2-kind").select_option("live")
    page.locator("#check-2-pid").fill("42")
    page.locator("#check-2-surface").fill("window:0")
    page.locator("#check-2-expectText").fill("Saved")
    check(browser_name + " dirty disables run", page.locator("#run-checks").is_disabled())
    page.locator("#save-checks").click()
    saved = page.evaluate("testMessages.at(-1)")
    check(
        browser_name + " saved web expectation is preserved",
        saved["checks"][1].get("expectText") == "Account settings",
    )
    check(
        browser_name + " save bridge fields",
        saved["action"] == "saveChecks"
        and saved["checks"][-1]
        == {
            "name": "Native app",
            "kind": "live",
            "pid": 42,
            "surface": "window:0",
            "expectText": "Saved",
        },
    )
    check(
        browser_name + " waits for save acknowledgement", page.locator("#save-checks").is_disabled()
    )
    receive(page, {**FIXTURE_STATE, "checks": saved["checks"]})
    check(
        browser_name + " acknowledged save clean",
        page.locator("#save-status").inner_text() == "No unsaved changes",
    )
    page.locator("#check-2-kind").select_option("appkit")
    page.locator("#check-2-runner").fill("/tmp/fixture-runner")
    page.locator("#check-2-subject").fill("settings-controller")
    page.locator("#save-checks").click()
    appkit = page.evaluate("testMessages.at(-1)")
    check(
        browser_name + " appkit fields saved",
        appkit["checks"][-1]
        == {
            "name": "Native app",
            "kind": "appkit",
            "runner": "/tmp/fixture-runner",
            "subject": "settings-controller",
        },
    )
    receive(page, {**FIXTURE_STATE, "checks": saved["checks"]})
    page.screenshot(path=str(artifact_dir / (browser_name + "-checks-360.png")), full_page=True)
    check(
        browser_name + " check editor mobile no overflow",
        page.evaluate("document.documentElement.scrollWidth") == 360,
    )
    page.set_viewport_size({"width": 1000, "height": 700})
    page.locator("#check-0-name").fill("Native app")
    page.locator("#save-checks").click()
    check(
        browser_name + " duplicate names rejected",
        page.locator("#notice").inner_text() == "Each check needs its own name.",
    )
    page.locator("#check-0-name").fill("Repaired name")
    page.locator("#save-checks").click()
    check(
        browser_name + " duplicate validity clears after correction",
        page.evaluate("testMessages.at(-1).checks[0].name") == "Repaired name",
    )
    paint_report = {
        "status": "pass",
        "checks": [
            {
                "name": "Painted page",
                "status": "pass",
                "verdict": {
                    "findings": [
                        {
                            "rule": "web-paint-unverified",
                            "severity": "warning",
                            "nodeID": "web/overlay",
                            "message": "Semantic layout was measured; painted occlusion remains unverified.",
                        }
                    ]
                },
            }
        ],
    }
    receive(page, {"type": "result", "report": paint_report})
    page.locator("[data-view=overview]").click()
    check(
        browser_name + " paint review is prominent",
        "Paint unverified" in page.locator("#status-label").inner_text(),
    )
    check(
        browser_name + " paint review not a clean pass",
        page.locator("#verification-stage").get_attribute("data-status") == "unavailable",
    )
    check(
        browser_name + " paint check qualified",
        "paint unverified" in page.locator(".check-chip").inner_text(),
    )
    check(
        browser_name + " paint evidence retained",
        "web/overlay" in page.locator(".finding").inner_text(),
    )
    for width in (1000, 360):
        page.set_viewport_size({"width": width, "height": 700})
        check(
            browser_name + f" paint review no overflow at {width}px",
            bounds(page)["document"] == width,
        )
        page.screenshot(
            path=str(artifact_dir / f"{browser_name}-paint-review-{width}.png"), full_page=True
        )
    receive(
        page,
        {
            **FIXTURE_STATE,
            "history": [
                {
                    "timestamp": "2026-09-23T12:00:00Z",
                    "project": FIXTURE_STATE["selectedProject"],
                    "status": "fail",
                    "report": report,
                },
                *[
                    {
                        "timestamp": "2026-09-23T12:00:00Z",
                        "project": FIXTURE_STATE["selectedProject"],
                        "status": status,
                        "report": {
                            "status": status,
                            "checks": [
                                {
                                    "name": "Saved check",
                                    "status": status,
                                    "verdict": {"findings": []} if status == "pass" else None,
                                }
                            ],
                        },
                    }
                    for status in ("pass", "unavailable")
                ],
                {
                    "timestamp": "2026-09-23T12:00:00Z",
                    "project": FIXTURE_STATE["selectedProject"],
                    "report": paint_report,
                },
            ],
        },
    )
    page.locator("[data-view=history]").click()
    check(browser_name + " history real reports visible", page.locator(".history-row").count() == 4)
    check(
        browser_name + " history paint review qualified",
        page.locator(".history-row .severity").last.inner_text() == "paint review",
    )
    for width in (1000, 360):
        page.set_viewport_size({"width": width, "height": 700})
        history_rects = page.locator(".history-row").evaluate_all(
            """rows=>rows.map(row=>Object.fromEntries(
            ['.severity','.history-summary','button'].map(selector=>{
                const element=row.querySelector(selector), rect=element.getBoundingClientRect();
                return [selector,{x:rect.x,width:rect.width,text:element.textContent}];
            })))"""
        )
        check(
            browser_name + f" history status columns align at {width}px",
            len(history_rects) == 4
            and all(
                len({round(row[selector][metric], 2) for row in history_rects}) == 1
                for selector, metric in (
                    (".severity", "width"),
                    (".history-summary", "x"),
                    ("button", "x"),
                )
            ),
        )
        check(
            browser_name + f" history no overflow at {width}px",
            page.evaluate("document.documentElement.scrollWidth") == width,
        )
        (artifact_dir / f"{browser_name}-history-{width}-rects.json").write_text(
            json.dumps(history_rects, indent=2) + "\n"
        )
        page.screenshot(path=str(artifact_dir / f"{browser_name}-history-{width}.png"))
    page.set_viewport_size({"width": 1000, "height": 700})
    page.locator(".history-row button").first.click()
    check(browser_name + " history opens report", page.locator(".finding").count() == 2)
    malicious = '<img src=x onerror="window.injected=true">'
    receive(
        page,
        {
            "type": "result",
            "report": {
                "status": "fail",
                "checks": [
                    {
                        "name": malicious,
                        "status": "fail",
                        "verdict": {
                            "findings": [
                                {
                                    "rule": malicious,
                                    "severity": "error",
                                    "nodeID": malicious,
                                    "message": malicious,
                                }
                            ]
                        },
                    }
                ],
            },
        },
    )
    check(
        browser_name + " untrusted data is plain text",
        page.locator("#findings img").count() == 0 and page.evaluate("window.injected===undefined"),
    )
    receive(page, {"type": "result", "report": {"status": "pass", "checks": []}})
    check(
        browser_name + " empty report never passes",
        page.locator("#verification-stage").get_attribute("data-status") == "unavailable",
    )
    receive(page, {"type": "error", "message": "Fixture denied input"})
    check(
        browser_name + " explicit error shown",
        "denied input" in page.locator("#notice").inner_text(),
    )
    page.locator("[data-view=checks]").focus()
    page.keyboard.press("Enter")
    check(browser_name + " keyboard navigation works", page.locator("#view-checks").is_visible())
    for invalid_kind in ["__proto__", "constructor", "toString"]:
        receive(
            page, {**FIXTURE_STATE, "checks": [{"name": "Malformed kind", "kind": invalid_kind}]}
        )
        check(
            browser_name + " safely renders kind " + invalid_kind,
            page.locator("#check-0-kind").input_value() == "scenario",
        )
    check(browser_name + " no external network requests", not network_attempts)
    check(browser_name + " no page exceptions", not errors)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("repository", nargs="?", type=Path, default=DEFAULT_ROOT)
    parser.add_argument("--artifact-dir", type=Path, default=DEFAULT_ROOT / "logs/workbench-smoke")
    args = parser.parse_args(argv)
    root = args.repository.resolve()
    artifact_dir = args.artifact_dir.resolve()
    artifact_dir.mkdir(parents=True, exist_ok=True)
    run = SmokeRun()
    resource = root / "Sources/VerdictUIWorkbench/Resources/index.html"
    if not resource.is_file():
        run.unavailable("workbench resources", "index.html is absent in the requested repository")
        return report(run, artifact_dir)
    try:
        from PIL import Image  # noqa: F401 — require pixel comparison dependency before launching
        from playwright.sync_api import sync_playwright
    except ImportError as error:
        run.unavailable("browser dependencies", str(error))
        return report(run, artifact_dir)
    try:
        with sync_playwright() as playwright:
            for name in BROWSERS:
                browser = None
                try:
                    browser = getattr(playwright, name).launch(headless=True)
                    exercise(name, browser, root, artifact_dir, run)
                    run.completed_browsers.append(name)
                except SmokeFailure:
                    # The assertion already recorded its name and failure exactly once.
                    continue
                except Exception as error:
                    # Boundary: browser startup/transport errors must become a failed
                    # structured gate, rather than an unhandled traceback or a skip.
                    run.unavailable(name + " browser flow", f"{type(error).__name__}: {error}")
                finally:
                    if browser is not None:
                        try:
                            browser.close()
                        except Exception as error:
                            run.unavailable(name + " browser cleanup", str(error))
    except Exception as error:
        run.unavailable("browser runner", f"{type(error).__name__}: {error}")
    return report(run, artifact_dir)


if __name__ == "__main__":
    raise SystemExit(main())
