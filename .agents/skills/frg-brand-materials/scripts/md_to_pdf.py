#!/usr/bin/env python3
"""Render a markdown file to a branded FRG PDF (markdown -> HTML -> WeasyPrint).

Reusable across skills: the brand stylesheet, fonts, and logo all live in this
skill (frg-brand-materials), and url()s resolve relative to this script's own
location, so it works regardless of the caller's working directory.

Usage:
    md_to_pdf.py <input.md> <output.pdf> [--title "Document Title"]

Exit codes:
    0  success
    2  bad arguments / input file missing or unreadable
    3  a required Python dependency (markdown / weasyprint) is not installed
    4  rendering failed
"""
import argparse
import sys
from pathlib import Path

# Skill root = parent of this scripts/ directory. Brand assets hang off it.
SKILL_DIR = Path(__file__).resolve().parent.parent
CSS_PATH = SKILL_DIR / "assets" / "print" / "frg-print.css"
LOGO_REL = "assets/logos/frg-logotype-black.png"  # relative to base_url (SKILL_DIR)


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description="Render markdown to a branded FRG PDF.")
    parser.add_argument("input", help="Path to the input markdown (.md) file")
    parser.add_argument("output", help="Path to write the PDF")
    parser.add_argument("--title", default="", help="Document title (PDF metadata)")
    # argv mirrors sys.argv (program name first) when provided, so tests can
    # call main(["md_to_pdf.py", in, out]).
    args = parser.parse_args(argv[1:] if argv is not None else None)

    in_path = Path(args.input)
    if not in_path.is_file():
        print(f"error: input markdown not found: {in_path}", file=sys.stderr)
        return 2

    try:
        markdown_text = in_path.read_text(encoding="utf-8")
    except OSError as exc:
        print(f"error: cannot read {in_path}: {exc}", file=sys.stderr)
        return 2

    try:
        import markdown  # noqa: WPS433 (deferred so missing dep is a clean message)
    except ImportError:
        print(
            "error: the 'markdown' package is required. Install it with:\n"
            "    pip install markdown",
            file=sys.stderr,
        )
        return 3

    try:
        from weasyprint import CSS, HTML  # noqa: WPS433
    except ImportError:
        print(
            "error: WeasyPrint is required to render the branded PDF. Install it with:\n"
            "    pip install weasyprint",
            file=sys.stderr,
        )
        return 3

    if not CSS_PATH.is_file():
        print(f"error: brand stylesheet missing: {CSS_PATH}", file=sys.stderr)
        return 4

    body_html = markdown.markdown(
        markdown_text,
        extensions=["tables", "fenced_code", "sane_lists"],
    )

    # The running-header <img> src is resolved against base_url (SKILL_DIR);
    # the CSS @font-face / margin-box url()s resolve against the CSS file.
    title = args.title or in_path.stem
    document = (
        "<!DOCTYPE html>\n"
        '<html lang="en"><head><meta charset="utf-8">'
        f"<title>{_escape(title)}</title></head>\n"
        "<body>\n"
        f'<div class="brand-header"><img src="{LOGO_REL}" alt="FRG"></div>\n'
        f"{body_html}\n"
        "</body></html>\n"
    )

    out_path = Path(args.output)
    try:
        out_path.parent.mkdir(parents=True, exist_ok=True)
        HTML(string=document, base_url=str(SKILL_DIR)).write_pdf(
            str(out_path),
            stylesheets=[CSS(filename=str(CSS_PATH))],
        )
    except Exception as exc:  # noqa: BLE001 (surface any render error cleanly)
        print(f"error: PDF rendering failed: {exc}", file=sys.stderr)
        return 4

    print(f"wrote {out_path}")
    return 0


def _escape(text: str) -> str:
    return (
        text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
    )


if __name__ == "__main__":
    sys.exit(main())
