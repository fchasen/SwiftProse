#!/usr/bin/env python3
import glob
import json
import os
import sys

root = sys.argv[1]
only = sys.argv[2] if len(sys.argv) > 2 else None

crashes, xfails = [], []
for path in sorted(glob.glob(os.path.join(root, "**", "*.json"), recursive=True)):
    d = json.load(open(path))
    if only and not d.get("name", "").startswith(only):
        continue
    if d.get("crashes"):
        crashes.append((d["name"], d.get("intent", ""), d["crashes"]))
    elif d.get("xfail"):
        xfails.append((d["name"], d.get("intent", ""), d["xfail"]))

print(f"# Open findings ({len(crashes)} crashes, {len(xfails)} xfails)\n")
if crashes:
    print("## Crashes\n")
    for name, intent, why in crashes:
        print(f"### {name}\n\n{intent}\n\n> {why}\n")
if xfails:
    print("## Expected-to-fail\n")
    section = None
    for name, intent, why in xfails:
        cat = name.split("/")[0]
        if cat != section:
            section = cat
            print(f"### {cat}\n")
        print(f"- **{name}** — {intent}  \n  _fails on:_ `{why}`")
    print()
