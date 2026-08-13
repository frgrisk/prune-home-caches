"""Pytest configuration for frg-brand-materials evals.

Puts the skill's scripts/ directory on sys.path so the unit tests can import
the scripts directly (``import md_to_pdf``).
"""

import sys
from pathlib import Path

SCRIPTS_DIR = Path(__file__).parent.parent / "scripts"
if str(SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPTS_DIR))
