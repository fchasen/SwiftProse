#!/usr/bin/env python3
"""Fetch the corpus described by corpus.json, pinning every entry to a commit.

Called by make-corpus.sh. Kept in Python because the manifest is JSON and
the CommonMark examples file is generated from spec.json.
"""
import argparse
import json
import os
import subprocess
import sys
import urllib.request


def gh_api(path):
    """GitHub API through `gh` when it is available (5000 req/hr authed),
    falling back to an anonymous request (60 req/hr)."""
    try:
        out = subprocess.run(
            ["gh", "api", path], capture_output=True, text=True, check=True
        )
        return json.loads(out.stdout)
    except (FileNotFoundError, subprocess.CalledProcessError):
        with urllib.request.urlopen(f"https://api.github.com/{path}") as r:
            return json.load(r)


def fetch(url):
    with urllib.request.urlopen(url) as r:
        return r.read()


def resolve_commit(repo, path, ref):
    if ref and ref != "HEAD":
        return ref
    data = gh_api(f"repos/{repo}/commits?path={path}&per_page=1")
    return data[0]["sha"]


def commonmark_examples(version="0.31.2", limit=400):
    """One markdown file made of the spec's own examples, section headings
    included — dense, adversarial, and not written by us."""
    spec = json.loads(fetch(f"https://spec.commonmark.org/{version}/spec.json"))
    out = [f"# CommonMark {version} examples\n"]
    section = None
    for i, ex in enumerate(spec[:limit]):
        if ex["section"] != section:
            section = ex["section"]
            out.append(f"\n## {section}\n")
        out.append(f"\n### Example {ex['example']}\n")
        # The spec writes tabs as →; put the real character back.
        out.append(ex["markdown"].replace("→", "\t"))
    return "".join(out)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--corpus", required=True)
    ap.add_argument("--manifest", required=True)
    ap.add_argument("--check", action="store_true")
    args = ap.parse_args()

    manifest = json.load(open(args.manifest))
    entries = manifest["entries"]
    changed = False
    total = 0
    failed = []

    for entry in entries:
        dest = os.path.join(args.corpus, entry["file"])
        source = entry["source"]

        if args.check:
            if not os.path.exists(dest):
                print(f"MISSING {entry['file']}")
                continue
            actual = os.path.getsize(dest)
            if entry.get("bytes") not in (None, actual):
                print(f"SIZE    {entry['file']}: manifest {entry['bytes']} != on disk {actual}")
            total += actual
            continue

        if source == "hand-written":
            if not os.path.exists(dest):
                print(f"MISSING {entry['file']} (hand-written, not fetchable)")
            else:
                total += os.path.getsize(dest)
            continue

        if source == "generated:commonmark":
            body = commonmark_examples().encode("utf-8")
        elif source.startswith("github:"):
            repo, path = source[len("github:"):].split("//", 1)
            try:
                commit = resolve_commit(repo, path, entry.get("commit"))
                body = fetch(f"https://raw.githubusercontent.com/{repo}/{commit}/{path}")
            except Exception as error:
                # A moved or renamed path. Report it and keep going — one
                # dead upstream must not stop the rest of the corpus.
                failed.append(f"{entry['file']}: {source} ({error})")
                continue
            if commit != entry.get("commit"):
                entry["commit"] = commit
                changed = True
        else:
            print(f"unknown source scheme: {source}", file=sys.stderr)
            continue

        if entry.get("maxBytes") and len(body) > entry["maxBytes"]:
            # Truncate on a blank line so the tail is still valid markdown.
            cut = body.rfind(b"\n\n", 0, entry["maxBytes"])
            body = body[: cut if cut > 0 else entry["maxBytes"]] + b"\n"

        os.makedirs(os.path.dirname(dest), exist_ok=True)
        with open(dest, "wb") as f:
            f.write(body)
        if entry.get("bytes") != len(body):
            entry["bytes"] = len(body)
            changed = True
        total += len(body)
        print(f"wrote {entry['file']} ({len(body)} bytes)")

    if changed and not args.check:
        with open(args.manifest, "w") as f:
            json.dump(manifest, f, indent=2, ensure_ascii=False)
            f.write("\n")
        print("updated corpus.json")
    for f in failed:
        print(f"FAILED  {f}")
    print(f"corpus total: {total} bytes across {len(entries) - len(failed)} entries")
    if failed:
        sys.exit(1)


if __name__ == "__main__":
    main()
