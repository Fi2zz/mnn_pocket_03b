#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Build a print-ready PDF for the model investigation report.

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
MD = os.path.join(ROOT, "DeepSeek-V4-Pro-Qwen3.5-9B-heretic-调查报告.md")
BUILD = os.path.join(ROOT, "_report_build_model")
HTML = os.path.join(BUILD, "report.html")
RAW_PDF = os.path.join(BUILD, "report.raw.pdf")
OUT_PDF = os.path.join(ROOT, "DeepSeek-V4-Pro-Qwen3.5-9B-heretic-调查报告.pdf")
CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

TITLE = "DeepSeek-V4-Pro-Qwen3.5-9B-UNCENSORED-heretic 模型调查报告"
FOOTER = "DeepSeek-V4-Pro-Qwen3.5-9B-UNCENSORED-heretic 模型调查报告"

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
h1, h2, h3, h4 { font-weight: 650; line-height: 1.3; page-break-after: avoid; text-align: left; }
h1 { font-size: 21pt; margin: 18px 0 10px; letter-spacing: .2px; }
h1 + blockquote { margin-top: 6px; }
h2 {
  font-size: 15pt; margin: 22px 0 10px; padding-bottom: 5px;
  border-bottom: 1.2px solid #d8dee6; color: #0b3d6e;
}
h3 { font-size: 12.3pt; margin: 17px 0 7px; color: #123a5e; }
h4 { font-size: 10.8pt; margin: 13px 0 6px; color: #243b53; }
p { margin: 6px 0; orphans: 3; widows: 3; }
ul, ol { margin: 6px 0 6px 0; padding-left: 22px; }
li { margin: 2.5px 0; text-align: left; }
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
  white-space: pre-wrap; word-break: break-word; page-break-inside: avoid;
  text-align: left;
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
th { background: #eef2f6; font-weight: 650; color: #243b53; white-space: nowrap; word-break: keep-all; overflow-wrap: normal; }
tbody tr:nth-child(even) td { background: #fafbfc; }
td { font-variant-numeric: tabular-nums; }
table.wide { font-size: 7.25pt; }
table.wide th, table.wide td { padding: 2.2px 2.4px; }
.pagebreak { page-break-before: always; }

/* Cover */
.cover {
  height: 252mm; padding-top: 20mm;
  page-break-after: always; border-top: 9px solid #0b3d6e;
}
.cover-kicker {
  font-size: 8.6pt; letter-spacing: 2.2px; color: #7c3aed;
  font-weight: 700; text-transform: uppercase;
}
.cover-title {
  font-size: 30pt; line-height: 1.24; margin: 12mm 0 4mm;
  color: #0b3d6e; letter-spacing: -.4px; font-weight: 700;
}
.cover-title span { color: #7c3aed; font-size: 25pt; }
.cover-sub {
  font-size: 12.2pt; color: #475569; margin: 0 0 8mm; line-height: 1.55;
}
.cover-rule {
  width: 64mm; height: 4px; margin: 2mm 0 10mm;
  background: linear-gradient(90deg, #0b62c4 0%, #7c3aed 100%);
}
.cover-facts {
  width: 100%; border-collapse: collapse; margin: 0 0 6mm;
  font-size: 9.1pt; page-break-inside: avoid;
}
.cover-facts td {
  border: 0; border-bottom: 1px solid #e2e7ee;
  padding: 5px 6px; background: none; vertical-align: top;
}
.cover-facts td:first-child {
  width: 27mm; color: #64748b; font-weight: 650; white-space: nowrap;
}
.cover-note {
  margin-top: 12mm; font-size: 8.3pt; color: #64748b;
  line-height: 1.65; border-left: 3px solid #d8dee6; padding-left: 10px;
}
"""


def build_html(text: str) -> str:
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
<title>{TITLE}</title>
<style>{CSS}</style></head><body>{body}</body></html>"""


def headings_from_markdown(text: str):
    heads = []
    in_code = False
    for line in text.splitlines():
        if line.strip().startswith("```"):
            in_code = not in_code
            continue
        if in_code:
            continue
        m = re.match(r"^(#{1,3})\s+(.+?)\s*$", line)
        if not m:
            continue
        title = m.group(2)
        title = re.sub(r"\[(.*?)\]\(.*?\)", r"\1", title)
        title = re.sub(r"[*_`]", "", title).strip()
        if title and title != "目录":
            heads.append((len(m.group(1)), title))
    return heads


def main() -> int:
    text = io.open(MD, encoding="utf-8").read()
    html = build_html(text)
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
        "--virtual-time-budget=15000",
        "--run-all-compositor-stages-before-draw",
        f"--user-data-dir={os.path.join(BUILD, 'chrome-profile')}",
        f"--print-to-pdf={RAW_PDF}",
        "file://" + HTML,
    ]
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0 or not os.path.exists(RAW_PDF):
        print(r.stdout[-2500:])
        print(r.stderr[-2500:])
        return 1

    import fitz  # PyMuPDF
    doc = fitz.open(RAW_PDF)
    total = doc.page_count

    # Page numbers + footer. Skip the cover page.
    footer_font = fitz.Font(fontfile="/System/Library/Fonts/Supplemental/Arial Unicode.ttf")
    for i, page in enumerate(doc, 1):
        if i == 1:
            continue
        page.wrap_contents()
        label = f"{FOOTER}  ·  第 {i} / {total} 页"
        size = 7.6
        tw = footer_font.text_length(label, fontsize=size)
        writer = fitz.TextWriter(page.rect)
        writer.append(
            ((page.rect.width - tw) / 2, page.rect.height - 38),
            label, font=footer_font, fontsize=size,
        )
        writer.write_text(page, color=(0.42, 0.46, 0.51))

    # Metadata.
    doc.set_metadata({
        "title": TITLE,
        "author": "技术评估（基于 Hugging Face 公开资料与静态核查）",
        "subject": "模型谱系、架构、去审查方法、基准复核与部署风险",
        "keywords": "DeepSeek-V4-Pro, Qwen3.5-9B, heretic, ARA, abliteration, 模型调查, 端侧推理",
        "creator": "Markdown + headless Chrome + PyMuPDF",
    })

    # Outline: match markdown headings on rendered pages. Start after the
    # cover (page 1) and the visible table of contents (page 2) so the TOC
    # entries are not mistaken for section starts.
    heads = headings_from_markdown(text)
    toc = []
    search_from = 2
    for level, title in heads:
        probe = title[:10]
        found = None
        for pno in range(search_from, total):
            if doc[pno].search_for(probe):
                found = pno + 1
                break
        if found is None:
            for pno in range(2, total):
                if doc[pno].search_for(probe):
                    found = pno + 1
                    break
        if found:
            lvl = level if not toc else min(level, toc[-1][0] + 1)
            toc.append([lvl, title, found])
            search_from = max(2, found - 1)
    if toc:
        doc.set_toc(toc)

    # Add page numbers to the visible table of contents (page 2).
    toc_page = doc[1]
    for level, title, pno in toc:
        if level != 1:
            continue
        rects = toc_page.search_for(title)
        if not rects:
            continue
        r = rects[0]
        label = str(pno)
        size = 8.4
        tw = footer_font.text_length(label, fontsize=size)
        x = toc_page.rect.width - 40 - tw
        y = r.y1 - 1.5
        writer = fitz.TextWriter(toc_page.rect)
        writer.append((x, y), label, font=footer_font, fontsize=size)
        writer.write_text(toc_page, color=(0.36, 0.42, 0.49))

    # Shrink the embedded CJK font.
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
