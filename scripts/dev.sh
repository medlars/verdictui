#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

echo "=== VerdictUI Dev ==="

echo "Building (kernel + probe + tests)..."
swift build --build-tests

echo "Testing..."
swift test

echo ""
echo "PM: python3.14 scripts/verdictui-pm.py --quick"
