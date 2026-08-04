#!/usr/bin/env python3.14
"""Contract validation for VerdictUI. Run: python3.14 contracts/validate-contracts.py

Wave 1 pins the Verdict JSON schema here (the CLI/MCP wire format); until then
this validates that the schema file, once present, parses.
"""

import json
import sys
from pathlib import Path

CONTRACTS = Path(__file__).resolve().parent


def main() -> int:
    schema = CONTRACTS / "verdict-schema.json"
    if not schema.exists():
        print("SKIP: No contracts pinned yet — verdict-schema.json lands in Wave 1")
        return 0
    try:
        json.loads(schema.read_text())
    except (OSError, json.JSONDecodeError) as exc:
        print(f"FAIL: verdict-schema.json unreadable: {exc}")
        return 1
    print("PASS: verdict-schema.json parses")
    return 0


if __name__ == "__main__":
    sys.exit(main())
