#!/usr/bin/env python3
"""
Render each PDF page to an image (PNG or JPEG). Writes under --output-dir
(must be under workspace). Runs GC first if free disk < 20%.
Usage: pdf_to_images.py <path-to-pdf> --output-dir <dir> [--format png|jpeg] [--dpi 150] [--max-pages N]
Prints each output file path to stdout, one per line.
"""
import argparse
import sys
from pathlib import Path

WORKSPACE_PREFIX = "/home/openclaw/.openclaw/workspace"


def is_under_workspace(path: Path) -> bool:
    try:
        resolved = path.resolve()
        return str(resolved).startswith(WORKSPACE_PREFIX)
    except OSError:
        return False


def run_gc_first() -> None:
    """Run GC if free disk < 20% (invoke gc_pdf_images.py)."""
    import subprocess
    script_dir = Path(__file__).resolve().parent
    gc_script = script_dir / "gc_pdf_images.py"
    if gc_script.exists():
        try:
            subprocess.run(
                [sys.executable, str(gc_script), "--threshold", "20"],
                cwd=str(script_dir),
                capture_output=True,
                timeout=60,
            )
        except (subprocess.SubprocessError, OSError):
            pass


def main() -> int:
    parser = argparse.ArgumentParser(description="Render PDF pages to images")
    parser.add_argument("path_to_pdf", type=Path, help="Path to PDF (must be under workspace)")
    parser.add_argument("--output-dir", type=Path, required=True, help="Output directory (under workspace)")
    parser.add_argument("--format", choices=("png", "jpeg"), default="png", help="Image format (default png)")
    parser.add_argument("--dpi", type=int, default=150, help="DPI for rendering (default 150)")
    parser.add_argument("--max-pages", type=int, default=0, help="Max pages to render (0 = all)")
    args = parser.parse_args()

    if not args.path_to_pdf.exists():
        print("File not found", file=sys.stderr)
        return 1
    if not is_under_workspace(args.path_to_pdf):
        print("PDF path must be under workspace", file=sys.stderr)
        return 1
    if not is_under_workspace(args.output_dir):
        print("Output dir must be under workspace", file=sys.stderr)
        return 1

    # Run GC before writing new images
    run_gc_first()

    try:
        import pymupdf
    except ImportError:
        print("pymupdf not installed", file=sys.stderr)
        return 1

    try:
        doc = pymupdf.open(args.path_to_pdf)
    except Exception as e:
        print(str(e).split("\n")[0][:80], file=sys.stderr)
        return 1

    args.output_dir.mkdir(parents=True, exist_ok=True)
    ext = "png" if args.format == "png" else "jpg"
    max_pages = args.max_pages or len(doc)
    paths = []

    try:
        for i in range(min(len(doc), max_pages)):
            page = doc[i]
            pix = page.get_pixmap(dpi=args.dpi)
            out_name = f"page_{i + 1:03d}.{ext}"
            out_path = args.output_dir / out_name
            pix.save(str(out_path))
            paths.append(out_path)
    finally:
        doc.close()

    for p in paths:
        print(str(p))
    return 0


if __name__ == "__main__":
    sys.exit(main())
