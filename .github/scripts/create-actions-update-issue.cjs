#!/usr/bin/env node
/**
 * Open (or refresh) the "pinned GitHub Actions have updates" issue.
 *
 * The workflow that calls this runs weekly and only reaches this step when the
 * check found at least one stale pin, so the script is on a cron path where a
 * naive version files a NEW issue every Monday until someone notices. It is
 * therefore idempotent by design: one open issue carries the label below, and
 * subsequent runs edit that issue rather than adding to a pile.
 *
 * Fails loudly. A silent failure here is worse than none, because the workflow
 * then reports success while the maintainer is never told a pin went stale --
 * the same fail-open shape the repo's own gates exist to rule out.
 */

"use strict";

const fs = require("fs");

const API = "https://api.github.com";
const LABEL = "dependencies";
const TITLE = "Pinned GitHub Actions have newer releases";

/** Read a required env var, or exit non-zero naming which one is missing. */
function required(name) {
  const value = process.env[name];
  if (!value) {
    console.error(`error: ${name} is not set — this script is only callable from its workflow`);
    process.exit(1);
  }
  return value;
}

const token = required("GITHUB_TOKEN");
const repo = required("REPO");
const updatesFile = process.env.UPDATES_FILE || "/tmp/updates.json";

/**
 * Call the GitHub REST API.
 *
 * Retries only the failures that are worth retrying — a transient 5xx or a
 * secondary rate limit. A 4xx is a bug in this script or a permissions gap and
 * must surface immediately rather than after three identical attempts.
 */
async function api(method, path, body) {
  const url = `${API}${path}`;
  let lastError;

  for (let attempt = 1; attempt <= 3; attempt += 1) {
    let response;
    try {
      response = await fetch(url, {
        method,
        headers: {
          Authorization: `Bearer ${token}`,
          Accept: "application/vnd.github+json",
          "X-GitHub-Api-Version": "2022-11-28",
          "Content-Type": "application/json",
          "User-Agent": "verdictui-actions-updater",
        },
        body: body === undefined ? undefined : JSON.stringify(body),
      });
    } catch (error) {
      // Network-level failure: no response at all, so retrying is meaningful.
      lastError = error;
      await sleep(attempt * 2000);
      continue;
    }

    if (response.ok) {
      return response.json();
    }

    const detail = await response.text();
    if (response.status < 500 && response.status !== 403 && response.status !== 429) {
      throw new Error(`${method} ${path} failed: ${response.status} ${detail}`);
    }
    lastError = new Error(`${method} ${path} failed: ${response.status} ${detail}`);
    await sleep(attempt * 2000);
  }

  throw lastError;
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

/** One markdown row per stale pin, tolerant of fields the checker may omit. */
function renderRow(update) {
  const current = String(update.current_sha || "").slice(0, 8) || "unknown";
  const latest = String(update.latest_sha || "").slice(0, 8) || "unknown";
  const tag = update.latest_tag || "n/a";
  const where = `${update.file || "unknown"}:${update.line ?? "?"}`;
  return `| \`${update.action || "unknown"}\` | ${where} | \`${current}\` | \`${latest}\` | ${tag} |`;
}

function renderBody(updates) {
  const rows = updates.map(renderRow).join("\n");
  return [
    `${updates.length} pinned action(s) have newer releases.`,
    "",
    "Actions are pinned to a full commit SHA on purpose — a tag is mutable and a",
    "compromised upstream can move it. Updating means replacing the SHA and the",
    "trailing version comment together, so the comment never describes a different",
    "commit than the one being run.",
    "",
    "| Action | Location | Pinned | Latest | Tag |",
    "| --- | --- | --- | --- | --- |",
    rows,
    "",
    "---",
    "_Refreshed automatically by `.github/workflows/check-pinned-actions.yml`._",
    "_This issue is updated in place rather than reopened weekly; close it once the",
    "pins are current and a later run will file a fresh one if they drift again._",
  ].join("\n");
}

async function main() {
  if (!fs.existsSync(updatesFile)) {
    console.error(`error: ${updatesFile} does not exist — the check step did not produce its output`);
    process.exit(1);
  }

  let updates;
  try {
    updates = JSON.parse(fs.readFileSync(updatesFile, "utf8"));
  } catch (error) {
    console.error(`error: ${updatesFile} is not valid JSON: ${error.message}`);
    process.exit(1);
  }

  if (!Array.isArray(updates)) {
    console.error(`error: expected an array in ${updatesFile}, got ${typeof updates}`);
    process.exit(1);
  }

  // Reaching this step at all means the workflow believed there were updates,
  // so an empty array is a contract violation upstream, not a quiet no-op.
  if (updates.length === 0) {
    console.error("error: the workflow reported updates_found=true but the list is empty");
    process.exit(1);
  }

  const body = renderBody(updates);
  const query = `/search/issues?q=${encodeURIComponent(
    `repo:${repo} is:issue is:open in:title "${TITLE}"`
  )}`;
  const existing = await api("GET", query);
  const match = (existing.items || []).find((issue) => issue.title === TITLE);

  if (match) {
    await api("PATCH", `/repos/${repo}/issues/${match.number}`, { body });
    console.log(`Updated issue #${match.number} with ${updates.length} stale pin(s)`);
    return;
  }

  const created = await api("POST", `/repos/${repo}/issues`, {
    title: TITLE,
    body,
    labels: [LABEL],
  });
  console.log(`Opened issue #${created.number} with ${updates.length} stale pin(s)`);
}

main().catch((error) => {
  console.error(`error: ${error.message}`);
  process.exit(1);
});
