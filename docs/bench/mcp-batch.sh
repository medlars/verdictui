#!/bin/bash
# Warm MCP round-trip benchmark: 1 initialize + N verify calls through the
# SHIPPED BINARY over stdio. Measures what an agent actually experiences.
#
# A library test cannot see this number (no.md #32/#34) — the transport, the
# framing and the JSON coding all sit between Harness.perform and the caller.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1
BIN=.build/release/verdictui
N=${1:-25}

[ -x "$BIN" ] || { echo "build first: swift build -c release --product verdictui" >&2; exit 2; }

OUT=$(mktemp)
START=$(python3.14 -c 'import time;print(time.time())')
{
  printf '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"bench","version":"1"}}}\n'
  for i in $(seq 1 "$N"); do
    printf '{"jsonrpc":"2.0","id":%d,"method":"tools/call","params":{"name":"verify","arguments":{"scenario":"demo-clean-settings"}}}\n' $((i + 10))
  done
} | "$BIN" mcp > "$OUT" 2>/dev/null
RC=${PIPESTATUS[1]}
END=$(python3.14 -c 'import time;print(time.time())')

REPLIES=$(wc -l < "$OUT" | tr -d ' ')
EXPECTED=$((N + 1))

# A benchmark must assert it RAN (no.md #49): a server that errored on every
# call would post the best numbers this script has ever seen.
if [ "$RC" -ne 0 ] || [ "$REPLIES" -ne "$EXPECTED" ]; then
  echo "FAILED: exit=$RC replies=$REPLIES expected=$EXPECTED" >&2
  rm -f "$OUT"; exit 1
fi
if grep -q '"error"' "$OUT"; then
  echo "FAILED: an error reply is fast for the wrong reason" >&2
  rm -f "$OUT"; exit 1
fi

python3.14 -c "
total = ($END - $START) * 1000
print(f'MCP-BATCH replies={$REPLIES} total={total:.1f}ms per_call={total/$EXPECTED:.2f}ms')
"
rm -f "$OUT"
