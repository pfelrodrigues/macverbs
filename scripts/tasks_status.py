#!/usr/bin/env python3
"""List docs/tasks status; --next prints first pending non-manual id."""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TASKS = ROOT / "docs" / "tasks"


def parse_meta(text: str) -> dict[str, str]:
    m = re.search(r"^---\s*(.*?)\s*---", text, re.S | re.M)
    meta: dict[str, str] = {}
    if not m:
        return meta
    for line in m.group(1).splitlines():
        if ":" not in line:
            continue
        k, v = line.split(":", 1)
        meta[k.strip()] = v.strip().strip('"').strip("'")
    return meta


def title_of(text: str, meta: dict[str, str]) -> str:
    if meta.get("title"):
        return meta["title"]
    for line in text.splitlines():
        if line.startswith("# "):
            return line[2:].strip()
    return "?"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--next", action="store_true")
    args = ap.parse_args()
    rows: list[tuple[str, str, str, bool]] = []
    for p in sorted(TASKS.glob("T*.md")):
        text = p.read_text(encoding="utf-8")
        meta = parse_meta(text)
        tid = meta.get("id", p.stem)
        status = meta.get("status", "unknown")
        manual = meta.get("manual", "false").lower() == "true"
        rows.append((tid, status, title_of(text, meta), manual))
    if args.next:
        for tid, status, _title, manual in rows:
            if status == "pending" and not manual:
                print(tid)
                return 0
        return 0
    w = max((len(r[0]) for r in rows), default=3)
    for tid, status, title, manual in rows:
        flag = " [manual]" if manual else ""
        print(f"{tid:<{w}}  {status:<12}  {title}{flag}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
