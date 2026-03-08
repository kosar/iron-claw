#!/usr/bin/env python3
"""
Extract text from a PDF file. Output is UTF-8 to stdout.
Usage: extract_text.py <path-to-pdf> [--max-chars N]
Path must be under workspace (e.g. /home/openclaw/.openclaw/workspace).
Runs the PDF-to-images garbage collector once at start (no-op if disk free >= 20%).
"""
import subprocess
import sys
from pathlib import Path

WORKSPACE_PREFIX = "/home/openclaw/.openclaw/workspace"
DEFAULT_MAX_CHARS = 100_000


def run_gc_if_low_disk() -> None:
    """Run gc_pdf_images.py so low-disk cleanup can happen on any skill use."""
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


def is_under_workspace(path: Path) -> bool:
    try:
        resolved = path.resolve()
        return str(resolved).startswith(WORKSPACE_PREFIX)
    except OSError:
        return False


def main() -> int:
    args = sys.argv[1:]
    if not args:
        print("Usage: extract_text.py <path-to-pdf> [--max-chars N]", file=sys.stderr)
        return 1

    path = Path(args[0])
    max_chars = DEFAULT_MAX_CHARS
    i = 1
    while i < len(args):
        if args[i] == "--max-chars" and i + 1 < len(args):
            try:
                max_chars = int(args[i + 1])
            except ValueError:
                print("Invalid --max-chars", file=sys.stderr)
                return 1
            i += 2
        else:
            i += 1

    if not path.exists():
        print("File not found", file=sys.stderr)
        return 1
    if not is_under_workspace(path):
        print("Path must be under workspace", file=sys.stderr)
        return 1

    run_gc_if_low_disk()

    try:
        from pypdf import PdfReader
    except ImportError:
        print("pypdf not installed", file=sys.stderr)
        return 1

    try:
        reader = PdfReader(str(path))
        if reader.is_encrypted:
            print("Encrypted", file=sys.stderr)
            return 1
    except Exception as e:
        err = str(e).split("\n")[0] if e else "Not a valid PDF"
        print(err[:80], file=sys.stderr)
        return 1

    total = 0
    for page in reader.pages:
        try:
            text = page.extract_text() or ""
        except Exception:
            text = ""
        if total + len(text) > max_chars:
            sys.stdout.buffer.write(text[: max_chars - total].encode("utf-8"))
            sys.stdout.buffer.write(
                f"\n\n[Truncated at {max_chars} characters.]\n".encode("utf-8")
            )
            break
        sys.stdout.buffer.write(text.encode("utf-8"))
        total += len(text)

    return 0


if __name__ == "__main__":
    sys.exit(main())
rint(err[:80], file=sys.stderr)
        return 1

    total = 0
    for page in reader.pages:
        try:
            text = page.extract_text() or ""
        except Exception:
            text = ""
        if total + len(text) > max_chars:
            sys.stdout.buffer.write(text[: max_chars - total].encode("utf-8"))
            sys.stdout.buffer.write(
                f"\n\n[Truncated at {max_chars} characters.]\n".encode("utf-8")
            )
            break
        sys.stdout.buffer.write(text.encode("utf-8"))
        total += len(text)

    return 0


if __name__ == "__main__":
    sys.exit(main())
