#!/usr/bin/env python3
"""Checks App/Resources/Localizable.xcstrings for keys that lack a Dari (fa-AF) translation.

Xcode adds literal UI strings to the catalog automatically when building in the IDE. Strings that
reach the UI through plain `String` parameters (component titles, enum titles via `L(...)`,
assistant templates via `LF(...)`) aren't extracted, so this script also scans the source for them.

Usage (from the repository root, after a build so .stringsdata exists):
    python3 tools/l10n/check_catalog.py            # report
    python3 tools/l10n/check_catalog.py --add      # add missing keys (untranslated) to the catalog
"""
import glob, json, re, sys

CATALOG = "App/Resources/Localizable.xcstrings"
cat = json.load(open(CATALOG))
keys = set()
for f in glob.glob("build/DerivedData/**/*.stringsdata", recursive=True):
    if "AppShortcuts" in f:
        continue
    for entries in json.load(open(f)).get("tables", {}).values():
        keys |= {e["key"] for e in entries}
for f in glob.glob("Packages/LinumicCore/Sources/**/*.swift", recursive=True) + glob.glob("App/**/*.swift", recursive=True):
    s = open(f).read()
    keys |= set(re.findall(r'\bLF?\("((?:[^"\\]|\\.)*)"', s))
    keys |= set(re.findall(r'\b(?:title|text|empty|message|hint|plan|emptyText):\s*"((?:[^"\\]|\\.)+)"', s))
IGNORE = {"github_pat_…"}  # placeholders shown verbatim
spec_only = re.compile(r"%(?:\d+\$)?(?:lld|ld|d|@|f)")
keys = {k for k in keys if k not in IGNORE and "\\(" not in k and re.search(r"[A-Za-z]", spec_only.sub("", k))}

spec = re.compile(r"%(?:\d+\$)?(?:lld|ld|d|@|f)")
norm = lambda s: sorted(re.sub(r"\d+\$", "", x) for x in spec.findall(s))
missing, mismatched = [], []
for k in sorted(keys):
    loc = cat["strings"].get(k, {}).get("localizations", {}).get("fa-AF", {}).get("stringUnit", {}).get("value")
    if loc is None:
        missing.append(k)
    elif norm(k) != norm(loc):
        mismatched.append(k)
if "--add" in sys.argv:
    for k in missing:
        cat["strings"].setdefault(k, {})
    json.dump(cat, open(CATALOG, "w"), ensure_ascii=False, indent=2, sort_keys=True)
print(f"{len(keys)} keys checked, {len(missing)} without Dari, {len(mismatched)} with mismatched format specifiers")
for k in missing: print("  MISSING:", k)
for k in mismatched: print("  FORMAT: ", k)
sys.exit(1 if missing or mismatched else 0)
