#!/usr/bin/env python3
"""Validate the hand-maintained patch stack's structure.

Usage: ./scripts/patchcheck.py patches/linux-esp32

Two failure modes this catches, both of which otherwise surface only as a
broken kernel build minutes later:

  1. hunk header line counts that disagree with their body, which makes
     patch(1) abort mid-file ("malformed patch at line N");
  2. a line beginning with '++' instead of '+', which leaks a literal '+'
     into the generated source.

Structural validity is necessary but not sufficient: also confirm the stack
still applies, in order, to a pristine kernel tree.
"""

import glob
import os
import re
import sys

if len(sys.argv) != 2:
    sys.exit("usage: patchcheck.py <patch-dir>")

BAD = 0
for path in sorted(glob.glob(os.path.join(sys.argv[1], "*.patch"))):
    lines = open(path).read().split("\n")
    name = os.path.basename(path)
    for n, line in enumerate(lines, 1):
        if line.startswith("++") and not line.startswith("+++"):
            print(f"{name}:{n}: stray '++' add-marker: {line[:60]}")
            BAD += 1
    i = 0
    while i < len(lines):
        m = re.match(
            r"^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@", lines[i]
        )
        if not m:
            i += 1
            continue
        j = i + 1
        plus = minus = ctx = 0
        while j < len(lines):
            b = lines[j]
            if b.startswith(("--- ", "+++ ", "diff ", "From ")):
                break
            if b.startswith("+"):
                plus += 1
            elif b.startswith("-"):
                minus += 1
            elif b.startswith(" "):
                ctx += 1
            elif b == "":
                nxt = lines[j + 1] if j + 1 < len(lines) else ""
                if nxt.startswith(("+", " ")):
                    ctx += 1
                else:
                    break
            else:
                break
            j += 1

        old = int(m.group(2) or 1)

        new = int(m.group(4) or 1)
        if minus + ctx != old or plus + ctx != new:

            print(
                f"{name}:{i+1}: hunk count mismatch: header -{old} +{new}, "
                f"body -{minus + ctx} +{plus + ctx}"
            )
            BAD += 1
        i = j

print("PATCHCHECK:", "FAIL" if BAD else "all hunks consistent")
sys.exit(1 if BAD else 0)
