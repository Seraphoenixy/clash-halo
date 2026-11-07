#!/usr/bin/env python3
"""Writes the deliberately-empty and meaningless fixture bodies.

Separate from the hand-written fixtures so an empty file is obviously
intentional rather than an accident of editing.
"""

from pathlib import Path

HERE = Path(__file__).resolve().parent

(HERE / "empty.txt").write_text("", encoding="utf-8")
(HERE / "whitespace.txt").write_text("   \n\n\t\n", encoding="utf-8")
(HERE / "random.txt").write_text(
    "这不是订阅内容，只是一段普通文本。\n"
    "it contains no scheme, no yaml, no json.\n",
    encoding="utf-8",
)
print("ok")
