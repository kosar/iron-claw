---
name: pdf-reader
description: >
  Read PDFs in workspace: extract text for normal PDFs, or convert pages to images
  and use vision for scanned/image-heavy PDFs. Use when the user asks to read a PDF,
  summarize a document, convert a PDF to images, or answer questions about a PDF.
metadata:
  openclaw:
    emoji: "📄"
    requires:
      bins: ["python3"]
---

# PDF Reader — text extraction and PDF to images

Read PDF files in the workspace in two ways: **extract text** (for normal PDFs) or **convert pages to images** (for scanned/image PDFs), then optionally use image-vision to "read" each page.

## When to use

- "Read this PDF" / "Summarize this document"
- "Convert this PDF to images" / "What does this PDF say?"
- When the user has provided or saved a PDF path in workspace

## Pipeline A — Text extraction (prefer when you need quick text)

1. **Ensure PDF path is under workspace** (e.g. `/home/openclaw/.openclaw/workspace/...`). If the user shared a file, use the path the gateway provides.
2. **Run the extraction script:**
   ```
   python3 /home/openclaw/.openclaw/workspace/skills/pdf-reader/scripts/extract_text.py <path-to-pdf>
   ```
   Optional: `--max-chars 80000` to cap output length.
3. **Use stdout as document text:** Summarize, answer questions, or quote. If stdout is empty or the script fails, consider Pipeline B.

## Pipeline B — PDF to images (for scanned/image PDFs or when text is empty)

1. **Ensure PDF path is under workspace.** Use the **canonical output dir** for extracted images: `workspace/skills/pdf-reader/pages/` (or a subdir under it per run, e.g. `pages/<pdf-basename>/`). This dir is the only place the garbage collector cleans.
2. **Run the PDF-to-images script:**
   ```
   python3 /home/openclaw/.openclaw/workspace/skills/pdf-reader/scripts/pdf_to_images.py <path-to-pdf> --output-dir /home/openclaw/.openclaw/workspace/skills/pdf-reader/pages/<run-id> [--format png|jpeg] [--dpi 150] [--max-pages 50]
   ```
   The script runs the garbage collector first if free disk < 20%, then writes one image per page and prints each path on stdout (one per line).
3. **Use the printed image paths.** To "read" the content, run the **image-vision** skill's `describe-image.sh` on each path (or first N pages), e.g. "What text is visible in this image?" or "Describe this page." Then summarize or answer the user from those descriptions. (On pibot, image-vision is already available.)
4. **Optional:** If the user only wanted "convert PDF to images", confirm and list the paths (or send the first page as a photo if appropriate).

## Garbage collector (disk space)

When free disk space drops **below 20%**, the skill automatically frees space by deleting extracted PDF-to-image files (JPEG/PNG) from the canonical dir so the disk is never exhausted by repeated extractions. No agent action required; `pdf_to_images.py` runs GC at start. Optionally run standalone to trigger cleanup without doing a conversion:

```
python3 /home/openclaw/.openclaw/workspace/skills/pdf-reader/scripts/gc_pdf_images.py
```

## Rules

- Paths must be in workspace; do not use `/tmp` for output (Rule 6b).
- Do not mention script names, "extraction", or "rendering" in the user-facing reply.
