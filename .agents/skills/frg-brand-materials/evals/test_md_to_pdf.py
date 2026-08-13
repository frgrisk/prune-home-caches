"""Tests for the frg-brand-materials markdown -> branded PDF converter."""

import builtins
from pathlib import Path

import pytest

# scripts/ is placed on sys.path by evals/conftest.py
import md_to_pdf as mp

SAMPLE_MD = """# Sample Model — Implementation Guide

## 1. Model Summary

Type: `pd_regression`.

## 2. Variable Inventory

| Variable | Coefficient |
| -------- | ----------- |
| ltv | 0.45 |

> Training estimates used.
"""

# weasyprint is needed for the success-path tests; skip them (don't fail) when
# it is absent, so the suite still runs on a machine without it.
weasyprint = pytest.importorskip("weasyprint", reason="weasyprint not installed")


def test_brand_assets_present():
    """The stylesheet, logo, and fonts the converter relies on must exist."""
    assert mp.CSS_PATH.is_file()
    assert (mp.SKILL_DIR / mp.LOGO_REL).is_file()
    fonts = mp.SKILL_DIR / "assets" / "fonts"
    assert (fonts / "Libre_Baskerville" / "LibreBaskerville-Regular.ttf").is_file()
    assert (fonts / "IBM_Plex_Sans" / "IBMPlexSans-Regular.ttf").is_file()


def test_renders_nonempty_pdf(tmp_path):
    src = tmp_path / "guide.md"
    src.write_text(SAMPLE_MD, encoding="utf-8")
    out = tmp_path / "guide.pdf"

    rc = mp.main(["md_to_pdf.py", str(src), str(out), "--title", "Sample"])

    assert rc == 0
    assert out.is_file()
    data = out.read_bytes()
    assert data.startswith(b"%PDF"), "output is not a valid PDF"
    assert len(data) > 2000, "PDF is suspiciously small"


def test_creates_output_parent_dir(tmp_path):
    src = tmp_path / "guide.md"
    src.write_text(SAMPLE_MD, encoding="utf-8")
    out = tmp_path / "nested" / "sub" / "guide.pdf"

    rc = mp.main(["md_to_pdf.py", str(src), str(out)])

    assert rc == 0
    assert out.is_file()


def test_missing_input_exits_2(tmp_path, capsys):
    out = tmp_path / "guide.pdf"
    rc = mp.main(["md_to_pdf.py", str(tmp_path / "nope.md"), str(out)])
    assert rc == 2
    assert "not found" in capsys.readouterr().err
    assert not out.exists()


def test_missing_weasyprint_exits_3(tmp_path, capsys, monkeypatch):
    """A missing WeasyPrint yields exit 3 and a clear pip-install message."""
    src = tmp_path / "guide.md"
    src.write_text(SAMPLE_MD, encoding="utf-8")
    out = tmp_path / "guide.pdf"

    real_import = builtins.__import__

    def fake_import(name, *args, **kwargs):
        if name == "weasyprint" or name.startswith("weasyprint."):
            raise ImportError("simulated missing weasyprint")
        return real_import(name, *args, **kwargs)

    monkeypatch.setattr(builtins, "__import__", fake_import)

    rc = mp.main(["md_to_pdf.py", str(src), str(out)])

    assert rc == 3
    assert "pip install weasyprint" in capsys.readouterr().err
    assert not out.exists()
