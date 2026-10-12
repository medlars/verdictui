#!/usr/bin/env bash
# Vendored from medlars/projects-shared (PR #2276). Do not edit without syncing upstream.
set -euo pipefail

STALE_SECONDS=240
HOSTED='["ubuntu-latest"]'
MINI='["self-hosted","macOS","ARM64","mini"]'

emit() {
  echo "runs-on=$1" >> "${GITHUB_OUTPUT}"
  echo "route=$2" >> "${GITHUB_OUTPUT}"
}

now="$(date +%s)"
mini_at="${MINI_ONLINE_AT:-}"

if [[ -z "$mini_at" || ! "$mini_at" =~ ^[0-9]+$ ]]; then
  emit "$HOSTED" "hosted (MINI_ONLINE_AT unset)"
  exit 0
fi

age=$((now - mini_at))
if (( age > STALE_SECONDS )); then
  emit "$HOSTED" "hosted (MINI_ONLINE_AT stale ${age}s > ${STALE_SECONDS}s)"
  exit 0
fi

# Heartbeat fresh: only a successful 200 with zero matching online runners → hosted.
# A forbidden/failed probe without MINI_RUNNER_GUARD_TOKEN → trust heartbeat → mini.
repo="${GITHUB_REPOSITORY:?}"
api="${GITHUB_API_URL:-https://api.github.com}"
probe_token="${MINI_RUNNER_GUARD_TOKEN:-${GH_TOKEN:-}}"

if [[ -z "$probe_token" ]]; then
  emit "$MINI" "mini (heartbeat fresh, no token for runner probe)"
  exit 0
fi

body_file="$(mktemp)"
trap 'rm -f "$body_file"' EXIT
http_code="000"
if ! http_code="$(curl -sS -o "$body_file" -w '%{http_code}' \
  -H "Authorization: Bearer ${probe_token}" \
  -H "Accept: application/vnd.github+json" \
  "${api}/repos/${repo}/actions/runners?per_page=100")"; then
  http_code="000"
fi

if [[ "$http_code" != "200" ]]; then
  if [[ -z "${MINI_RUNNER_GUARD_TOKEN:-}" ]]; then
    emit "$MINI" "mini (heartbeat fresh, runner probe HTTP ${http_code}, no MINI_RUNNER_GUARD_TOKEN)"
  else
    emit "$MINI" "mini (heartbeat fresh, runner probe HTTP ${http_code})"
  fi
  exit 0
fi

online_count="$(
  export BODY_FILE="$body_file"
  python3 <<'PY'
import json, os

required = {"self-hosted", "macOS", "ARM64", "mini"}
with open(os.environ["BODY_FILE"], encoding="utf-8") as f:
    data = json.load(f)
hits = 0
notes: list[str] = []
for r in data.get("runners", []):
    if r.get("status") != "online":
        continue
    labels = {lb.get("name", "") for lb in r.get("labels", [])}
    name = r.get("name", "?")
    if required <= labels:
        hits += 1
    notes.append(f"{name}:{'+'.join(sorted(labels))}")
print(hits)
if hits == 0 and notes:
    print("online_runner_labels=" + "; ".join(notes[:8]), file=__import__("sys").stderr)
PY
)"

if [[ "$online_count" =~ ^[0-9]+$ ]] && (( online_count > 0 )); then
  emit "$MINI" "mini (heartbeat fresh, ${online_count} labeled runner(s) online)"
else
  emit "$HOSTED" "hosted (heartbeat fresh, probe 200, no online runner with self-hosted+macOS+ARM64+mini)"
fi
