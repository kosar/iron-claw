#!/usr/bin/env python3
"""
Garbage collector for PDF-to-images output. When free disk space is below
threshold (default 20%), delete image files in the canonical pages dir
(oldest first) until free >= threshold or dir is empty.
Usage: gc_pdf_images.py [--threshold 20]
"""
import argparse
import shutil
import sys
from pathlib import Path

# Canonical dir: workspace/skills/pdf-reader/pages/ (resolve from this script)
SCRIPT_DIR = Path(__file__).resolve().parent
PAGES_DIR = SCRIPT_DIR.parent / "pages"
# Workspace root for disk_usage (skills -> workspace)
WORKSPACE_ROOT = SCRIPT_DIR.parent.parent.parent

IMAGE_SUFFIXES = {".png", ".jpg", ".jpeg"}


def run_gc(threshold: int) -> bool:
    """Run GC if free disk < threshold. Return True if any cleanup was done."""
    try:
        usage = shutil.disk_usage(str(WORKSPACE_ROOT))
    except OSError:
        return False
    free_pct = 100 * usage.free / usage.total if usage.total else 0
    if free_pct >= threshold:
        return False

    if not PAGES_DIR.exists():
        return False

    # Collect all image files with mtime (oldest first)
    files = []
    for f in PAGES_DIR.rglob("*"):
        if f.is_file() and f.suffix.lower() in IMAGE_SUFFIXES:
            try:
                files.append((f.stat().st_mtime, f))
            except OSError:
                pass
    files.sort(key=lambda x: x[0])

    freed = 0
    for _mtime, f in files:
        try:
            usage = shutil.disk_usage(str(WORKSPACE_ROOT))
            free_pct = 100 * usage.free / usage.total if usage.total else 0
            if free_pct >= threshold:
                break
        except OSError:
            break
        try:
            size = f.stat().st_size
            f.unlink()
            freed += size
        except OSError:
            pass

    if freed > 0:
        try:
            usage = shutil.disk_usage(str(WORKSPACE_ROOT))
            free_pct = 100 * usage.free / usage.total if usage.total else 0
            print(f"Freed {freed} bytes; free disk now {free_pct:.1f}%", file=sys.stderr)
        except OSError:
            print(f"Freed {freed} bytes", file=sys.stderr)
        return True
    return False


def main() -> int:
    parser = argparse.ArgumentParser(description="GC for PDF-extracted images")
    parser.add_argument("--threshold", type=int, default=20, help="Free disk %% below which to clean (default 20)")
    args = parser.parse_args()
    if args.threshold < 0 or args.threshold > 100:
        print("Threshold must be 0-100", file=sys.stderr)
        return 1
    run_gc(args.threshold)
    return 0


if __name__ == "__main__":
    sys.exit(main())
