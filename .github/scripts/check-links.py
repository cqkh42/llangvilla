#!/usr/bin/env python3
"""Check the relative links in the repo's Markdown files: the file must exist and a
#section anchor must match a heading in it (GitHub's anchor rules). External links
(http, https, mailto) are not fetched.

    .github/scripts/check-links.py       # exit 1 and list the broken links, if any
"""
import re
import subprocess
import sys
from pathlib import Path

root = Path(__file__).resolve().parents[2]
files = [root / f for f in subprocess.run(
    ["git", "-C", str(root), "ls-files", "*.md"], capture_output=True, text=True, check=True
).stdout.split()]
# Untracked new docs count too (a link check before the first commit).
files += [p for p in root.rglob("*.md") if ".git" not in p.parts and p not in files
          and not any(part.startswith(".") and part not in (".github",) for part in p.relative_to(root).parts)]

LINK = re.compile(r"(?<!!)\[[^\]]*\]\(([^)\s]+)\)")
FENCE = re.compile(r"^(```|~~~)")


def anchors(md: Path) -> set[str]:
    """GitHub's heading anchors: lower-case, punctuation dropped, spaces to hyphens,
    repeats numbered -1, -2, ..."""
    seen: dict[str, int] = {}
    out = set()
    in_fence = False
    for line in md.read_text().splitlines():
        if FENCE.match(line):
            in_fence = not in_fence
        if in_fence or not line.startswith("#"):
            continue
        m = re.match(r"#+\s+(.*?)\s*#*$", line)
        if not m:
            continue
        text = re.sub(r"`|\*\*|\*|_(?=\w)|(?<=\w)_", "", m.group(1))
        text = re.sub(r"\[([^\]]*)\]\([^)]*\)", r"\1", text)
        slug = re.sub(r"[^\w\- ]", "", text.lower()).replace(" ", "-")
        n = seen.get(slug, 0)
        seen[slug] = n + 1
        out.add(slug if n == 0 else f"{slug}-{n}")
    return out


broken = []
for md in sorted(set(files)):
    in_fence = False
    for no, line in enumerate(md.read_text().splitlines(), 1):
        if FENCE.match(line):
            in_fence = not in_fence
        if in_fence:
            continue
        for target in LINK.findall(line):
            if re.match(r"[a-z]+:", target):      # http:, https:, mailto:
                continue
            path, _, anchor = target.partition("#")
            dest = (md.parent / path).resolve() if path else md
            where = f"{md.relative_to(root)}:{no}"
            if not dest.exists():
                broken.append(f"{where}: {target} (no such file)")
            elif anchor and dest.suffix == ".md" and anchor not in anchors(dest):
                broken.append(f"{where}: {target} (no heading for #{anchor} in {dest.relative_to(root)})")

if broken:
    print("Broken links:\n  " + "\n  ".join(broken))
    sys.exit(1)
print(f"Links OK ({len(set(files))} Markdown files).")
