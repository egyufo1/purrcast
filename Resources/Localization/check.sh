#!/bin/zsh
# Checks every translation: missing or unused keys, and placeholder (%@ / %1$@) mismatches.
set -euo pipefail
cd "$(dirname "$0")"
for f in *.lproj/*.strings; do plutil -lint -s "$f"; done
python3 - <<'PY'
import glob, os, plistlib, re, subprocess, sys

used = subprocess.run(["python3", "extract_keys.py"], capture_output=True, text=True, check=True).stdout.splitlines()
used = [k.replace("\\n", "\n") for k in used]
placeholders = lambda s: len(re.findall(r"%(?:\d+\$)?@", s))

def load(path):
    out = subprocess.run(["plutil", "-convert", "xml1", "-o", "-", path], capture_output=True, check=True).stdout
    return plistlib.loads(out)

problems = 0
languages = sorted(d[:-6] for d in glob.glob("*.lproj"))
for lang in languages:
    if lang.startswith("en"):
        continue                                  # English: the keys themselves
    strings = load(f"{lang}.lproj/Localizable.strings")
    info = load(f"{lang}.lproj/InfoPlist.strings") if os.path.exists(f"{lang}.lproj/InfoPlist.strings") else {}
    issues = [f"missing: {k!r}" for k in used if k not in strings]
    issues += [f"unused: {k!r}" for k in strings if k not in used]
    issues += [f"placeholders: {k!r}" for k in used if k in strings and placeholders(strings[k]) != placeholders(k)]
    issues += [f"empty: {k!r}" for k, v in strings.items() if not v.strip()]
    if "NSLocalNetworkUsageDescription" not in info:
        issues.append("InfoPlist.strings: NSLocalNetworkUsageDescription missing")
    for issue in issues:
        print(f"{lang}: {issue}")
    problems += len(issues)
print(f"{len(languages)} languages, {len(used)} keys, {problems} problems")
sys.exit(1 if problems else 0)
PY
