#!/usr/bin/env python3
"""
Check every scheme's contrast, docs/CHROME.md section 3.

A scheme is a theme file under lib/themes with `colour NAME VALUE` lines and
roles that name them. This reads each one that defines colours, resolves its
roles, and measures each role that draws on a surface against `panel` and
`raised` by WCAG's contrast ratio:

    text, dim, link                          text: 4.5 to 1, WCAG AA
    accent, focus, warn, ok, fault           signal: 3 to 1, WCAG's
                                             non-text contrast

A pair under its floor is a finding, and the exit is non-zero, so the build's
`lint` step runs it as a gate. A scheme that fails does not ship.

Usage:
    tools/contrast.py [--show] [FILE ...]
"""

import os
import sys

TEXT = ["text", "dim", "link"]
SIGNAL = ["accent", "focus", "warn", "ok", "fault"]
SURFACES = ["panel", "raised"]
FLOOR = {"text": 4.5, "signal": 3.0}

HERE = os.path.dirname(os.path.abspath(__file__))
THEMES = os.path.join(HERE, "..", "lib", "themes")


def luminance(hexrgb):
    out = []
    for i in (0, 2, 4):
        c = int(hexrgb[i:i + 2], 16) / 255
        out.append(c / 12.92 if c <= 0.03928 else ((c + 0.055) / 1.055) ** 2.4)
    return 0.2126 * out[0] + 0.7152 * out[1] + 0.0722 * out[2]


def ratio(a, b):
    hi, lo = sorted([luminance(a), luminance(b)], reverse=True)
    return (hi + 0.05) / (lo + 0.05)


def is_hex(v):
    return len(v) == 6 and all(c in "0123456789abcdefABCDEF" for c in v)


def read_scheme(path):
    """The roles of a scheme file, each resolved to six hex digits, or None
    for a file that defines no colours: a role override, not a scheme."""
    colours, roles = {}, {}
    for raw in open(path):
        words = raw.split("#")[0].split()
        if len(words) >= 3 and words[0] == "colour":
            v = colours.get(words[2], words[2])
            if is_hex(v):
                colours[words[1]] = v
        elif len(words) >= 2 and words[0] not in ("desk", "use"):
            v = colours.get(words[1], words[1])
            if is_hex(v):
                roles[words[0]] = v
    if not colours:
        return None
    return roles


def check(path, show):
    roles = read_scheme(path)
    if roles is None:
        return 0
    name = os.path.basename(path)
    bad = 0
    for kind, names in (("text", TEXT), ("signal", SIGNAL)):
        for fg in names:
            for bg in SURFACES:
                if fg not in roles or bg not in roles:
                    print(f"{name}: {fg} or {bg} is not named")
                    bad += 1
                    continue
                r = ratio(roles[fg], roles[bg])
                low = r < FLOOR[kind]
                if low or show:
                    mark = "FAIL" if low else "ok"
                    print(f"{name}: {fg:<7} on {bg:<7} {r:5.2f}  {kind} floor {FLOOR[kind]}  {mark}")
                bad += low
    return bad


def main(argv):
    show = "--show" in argv
    files = [a for a in argv if not a.startswith("--")]
    if not files:
        files = sorted(os.path.join(THEMES, f) for f in os.listdir(THEMES))
    bad = sum(check(f, show) for f in files)
    if bad:
        print(f"{bad} pair(s) under the floor")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
