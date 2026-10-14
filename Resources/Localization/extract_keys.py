#!/usr/bin/env python3
"""Prints every localization key used in Sources/ (one per line), with \\(...) interpolations as %@."""
import pathlib, re, sys

CALLS = r'(?:(?<![A-Za-z.])(?:loc|Text|Button|Label|Toggle|CommandMenu|Picker|Menu|Window|GroupBox)\(|\.help\(|help: )'
root = pathlib.Path(__file__).resolve().parents[2] / "Sources"

def literal_at(src, i):
    """Parses the Swift string literal starting at src[i] == '"'; returns (key, end)."""
    out, i = [], i + 1
    while src[i] != '"':
        if src.startswith('\\(', i):          # interpolation: skip balanced parentheses
            depth, i = 1, i + 2
            while depth:
                if src[i] == '"':             # nested literal inside the interpolation
                    _, i = literal_at(src, i)
                    continue
                depth += {'(': 1, ')': -1}.get(src[i], 0)
                i += 1
            out.append('%@')
        elif src[i] == '\\':
            out.append(src[i:i + 2]); i += 2
        else:
            out.append(src[i]); i += 1
    return ''.join(out), i + 1

keys = []
for f in sorted(root.rglob("*.swift")):
    src = f.read_text()
    for m in re.finditer(CALLS + r'"', src):
        key, _ = literal_at(src, m.end() - 1)
        if key not in keys:
            keys.append(key)
print("\n".join(keys))
