#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Build a print-ready PDF from the Markdown report.

Pipeline: Markdown -> styled HTML -> headless Chrome -> PyMuPDF polish
(page numbers, metadata, PDF outline).
"""
import io
import os
import re
import subprocess
import sys

import markdown

ROOT = "/Users/fitz/REPO/mnn"
MD = os.path.join(ROOT, "MNN-Pocket-0.3B-深度解读报告.md")
BUILD = os.path.join(ROOT, "_report_build")
HTML = os.path.join(BUILD, "report.html")
RAW_PDF = os.path.join(BUILD, "report.raw.pdf")
OUT_PDF = os.path.join(ROOT, "MNN-Pocket-0.3B-深度解读报告.pdf")
CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

os.makedirs(BUILD, exist_ok=True)

CSS = r"""
@page { size: A4; margin: 15mm 14mm 17mm 14mm; }
* { box-sizing: border-box; }
html { -webkit-print-color-adjust: exact; print-color-adjust: exact; }
body {
  margin: 0; color: #1f2328;
  font-family: "Arial Unicode MS", "PingFang SC", "Hiragino Sans GB", "Heiti SC", "Microsoft YaHei", sans-serif;
  font-size: 10.1pt; line-height: 1.64; text-align: justify;
}
h1, h2, h3, h4 { font-weight: 650; line-height: 1.3; page-break-after: avoid; }
h1 { font-size: 21pt; margin: 0 0 10px; letter-spacing: .2px; }
h1 + blockquote { margin-top: 6px; }
h2 {
  font-size: 15pt; margin: 22px 0 10px; padding-bottom: 5px;
  border-bottom: 1.2px solid #d8dee6; color: #0b3d6e;
}
h3 { font-size: 12.3pt; margin: 17px 0 7px; color: #123a5e; }
h4 { font-size: 10.8pt; margin: 13px 0 6px; color: #243b53; }
p { margin: 6px 0; orphans: 3; widows: 3; }
ul, ol { margin: 6px 0 6px 0; padding-left: 22px; }
li { margin: 2.5px 0; }
a { color: #0b62c4; text-decoration: none; }
strong { font-weight: 650; }
hr { border: 0; border-top: 1px solid #e2e7ee; margin: 16px 0; }
blockquote {
  margin: 8px 0; padding: 7px 11px; color: #34404d;
  background: #f6f8fa; border-left: 3px solid #9fb6cc;
}
blockquote p { margin: 3px 0; }
code {
  font-family: "SFMono-Regular", Menlo, Consolas, "Liberation Mono", monospace;
  font-size: .88em; background: #f2f4f7; padding: 1px 4px; border-radius: 3px;
  color: #8a2c0d;
}
pre {
  background: #f6f8fa; border: 1px solid #e2e7ee; border-radius: 5px;
  padding: 9px 11px; margin: 9px 0; overflow: hidden;
  white-space: pre-wrap; word-break: break-word;
}
pre code { background: none; padding: 0; color: #1f2328; font-size: 8.5pt; }
table {
  width: 100%; border-collapse: collapse; margin: 10px 0;
  font-size: 8.3pt; line-height: 1.42; page-break-inside: avoid;
}
thead { display: table-header-group; }
tr { page-break-inside: avoid; }
th, td {
  border: 1px solid #d5dbe3; padding: 3.2px 4px;
  vertical-align: top; word-break: break-word;
}
th { background: #eef2f6; font-weight: 650; color: #243b53; }
tbody tr:nth-child(even) td { background: #fafbfc; }
td { font-variant-numeric: tabular-nums; }
table.wide { font-size: 7.25pt; }
table.wide th, table.wide td { padding: 2.2px 2.4px; }
.pagebreak { page-break-before: always; }
"""


def build_html() -> str:
    text = io.open(MD, encoding="utf-8").read()
    body = markdown.markdown(
        text,
        extensions=["extra", "tables", "fenced_code", "sane_lists", "attr_list", "toc"],
        output_format="html5",
    )
    # Mark tables with many columns so they can use a smaller font.
    def add_wide(m):
        block = m.group(0)
        if block.count("<th") >= 8:
            return block.replace("<table>", '<table class="wide">', 1)
        return block
    body = re.sub(r"<table>.*?</table>", add_wide, body, flags=re.S)

    return f"""<!DOCTYPE html>
<html lang="zh-CN"><head><meta charset="utf-8">
<title>MNN-Pocket-0.3B 深度解读与技术评估报告</title>
<style>{CSS}</style></head><body>{body}</body></html>"""


def main() -> int:
    html = build_html()
    io.open(HTML, "w", encoding="utf-8").write(html)

    if os.path.exists(RAW_PDF):
        os.remove(RAW_PDF)
    cmd = [
        CHROME,
        "--headless=new",
        "--disable-gpu",
        "--no-sandbox",
        "--no-pdf-header-footer",
        "--print-to-pdf-no-header",
        "--virtual-time-budget=10000",
        "--run-all-compositor-stages-before-draw",
        f"--user-data-dir={os.path.join(BUILD, 'chrome-profile')}",
        f"--print-to-pdf={RAW_PDF}",
        "file://" + HTML,
    ]
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0 or not os.path.exists(RAW_PDF):
        print(r.stdout[-2000:])
        print(r.stderr[-2000:])
        return 1

    import fitz  # PyMuPDF
    doc = fitz.open(RAW_PDF)
    total = doc.page_count

    # Page numbers + footer. wrap_contents() isolates Chrome's content
    # transformation matrix so the overlay uses page coordinates.
    footer_font = fitz.Font(fontfile="/System/Library/Fonts/Supplemental/Arial Unicode.ttf")
    for i, page in enumerate(doc, 1):
        page.wrap_contents()
        label = f"MNN-Pocket-0.3B 深度解读与技术评估报告  ·  第 {i} / {total} 页"
        size = 7.8
        tw = footer_font.text_length(label, fontsize=size)
        writer = fitz.TextWriter(page.rect)
        writer.append(
            ((page.rect.width - tw) / 2, page.rect.height - 38),
            label, font=footer_font, fontsize=size,
        )
        writer.write_text(page, color=(0.42, 0.46, 0.51))

    # Metadata.
    doc.set_metadata({
        "title": "MNN-Pocket-0.3B 深度解读与技术评估报告",
        "author": "技术评估（基于 MNN Team 公开资料）",
        "subject": "端侧大模型技术评估与开发者指南",
        "keywords": "MNN, MNN-Pocket, on-device LLM, QAT, MOPD, 端侧推理",
        "creator": "Markdown + headless Chrome + PyMuPDF",
    })

    # Outline: match headings by their leading text on rendered pages.
    heads = []
    for level, title in re.findall(r"<h([123])[^>]*>(.*?)</h\1>", html, flags=re.S):
        clean = re.sub(r"<[^>]+>", "", title)
        clean = re.sub(r"\s+", " ", clean).strip()
        if clean:
            heads.append((int(level), clean))
    toc = []
    search_from = 0
    for level, title in heads:
        probe = title[:28]
        found = None
        for pno in range(search_from, total):
            if doc[pno].search_for(probe):
                found = pno + 1
                break
        if found is None:
            for pno in range(0, total):
                if doc[pno].search_for(probe):
                    found = pno + 1
                    break
        if found:
            lvl = level if not toc else min(level, toc[-1][0] + 1)
            toc.append([lvl, title, found])
            search_from = max(0, found - 1)
    if toc:
        doc.set_toc(toc)

    # Shrink the embedded CJK font (Arial Unicode MS is ~23 MB unsubsetted).
    try:
        doc.subset_fonts(verbose=False)
    except Exception as exc:
        print("subset_fonts skipped:", exc)

    doc.save(OUT_PDF, garbage=4, deflate=True)
    doc.close()
    print(f"PDF written: {OUT_PDF}")
    print(f"pages: {total}, headings bookmarked: {len(toc)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
