#!/bin/bash
# Flake measurement in BOTH directions. A flake rate taken only on the passing
# path proves half of what it claims: a rule failing for a DRIFTING reason shows
# a stable exit code and unstable evidence, so evidence is checked separately.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1
BIN=.build/release/verdictui
N=${1:-100}
[ -x "$BIN" ] || { echo "build first: swift build -c release --product verdictui" >&2; exit 2; }

run_direction() {
  local scenario=$1 expect=$2 pass=0 fail=0 other=0 rc
  for _ in $(seq 1 "$N"); do
    "$BIN" verify "$scenario" > /dev/null 2>&1; rc=$?
    case $rc in 0) pass=$((pass+1));; 1) fail=$((fail+1));; *) other=$((other+1));; esac
  done
  echo "FLAKE $scenario pass=$pass fail=$fail error=$other (expected all $expect)"
  if [ "$other" -ne 0 ]; then echo "  ERROR exits present" >&2; return 1; fi
  if [ "$expect" = pass ] && [ "$pass" -ne "$N" ]; then return 1; fi
  if [ "$expect" = fail ] && [ "$fail" -ne "$N" ]; then return 1; fi
  return 0
}

# Evidence stability on the failing path — outside any pipeline, so the counter
# survives (a `case` inside a pipe runs in a subshell and its increments vanish).
evidence_stability() {
  local tmp; tmp=$(mktemp)
  for _ in $(seq 1 "$N"); do
    "$BIN" verify demo-undersized-tap-target 2>/dev/null \
      | python3.14 -c "import sys,json;d=json.load(sys.stdin);f=d['findings'][0];print(f['nodeID'],f['rule'])" >> "$tmp" 2>/dev/null
  done
  local distinct; distinct=$(sort "$tmp" | uniq -c | tr -s ' ')
  echo "EVIDENCE distinct=$(sort "$tmp" | uniq | wc -l | tr -d ' ') :$distinct"
  rm -f "$tmp"
}

rc=0
run_direction demo-clean-settings pass || rc=1
run_direction demo-undersized-tap-target fail || rc=1
evidence_stability
exit $rc
