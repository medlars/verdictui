#!/usr/bin/env python3.14
"""Project-owned runner for the actual bundled Workbench workflow."""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
from workbench_coverage import main  # noqa: E402

raise SystemExit(main())
