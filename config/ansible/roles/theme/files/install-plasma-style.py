#!/usr/bin/env python3
"""Install Colloid's Plasma style without its stale colour stylesheets.

Usage: install-plasma-style.py STYLE_SRC DEST STAMP

Replaces DEST with a copy of STYLE_SRC, then strips the extra stylesheets from every
SVG and writes STAMP. Colloid's style icons (plasma/desktoptheme/icons: the tray's
volume, network, clipboard and so on) are left out, so the tray uses the icon
theme's (Papirus) instead: a style's own icons win over the icon theme.

Why: Plasma recolours a style's SVGs by replacing the contents of the one
<style id="current-color-scheme"> element with the colour scheme's colours (KSvg).
Many of Colloid's SVGs also carry Inkscape leftovers: more <style> elements (no id,
id="current-color-scheme-2", or a second id="current-color-scheme") that repeat
the .ColorScheme-* rules with Breeze Light's colours. They come later in the file,
so they win the CSS cascade, and the panel, dock and tray icons stay light whatever
the colour scheme. Those extra elements are dropped; the first real one, and styles
without .ColorScheme-* rules, stay.
"""
import gzip
import pathlib
import re
import shutil
import sys

STYLE = re.compile(r"<style\b[^>]*>.*?</style>", re.S)
REAL = re.compile(r'\bid="current-color-scheme"')


def strip(path: pathlib.Path) -> bool:
    raw = path.read_bytes()
    gzipped = raw[:2] == b"\x1f\x8b"
    text = (gzip.decompress(raw) if gzipped else raw).decode("utf-8")
    kept = False

    def keep(match: re.Match) -> str:
        # The first <style id="current-color-scheme"> stays (KSvg replaces only
        # that one); later ones with .ColorScheme-* rules go, whatever their id.
        nonlocal kept
        element = match.group(0)
        if ".ColorScheme-" not in element:
            return element
        if not kept and REAL.search(element[: element.index(">")]):
            kept = True
            return element
        return ""

    fixed = STYLE.sub(keep, text)
    if fixed == text:
        return False
    data = fixed.encode("utf-8")
    path.write_bytes(gzip.compress(data, mtime=0) if gzipped else data)
    return True


def main() -> None:
    style_src, dest, stamp = map(pathlib.Path, sys.argv[1:4])
    shutil.rmtree(dest, ignore_errors=True)
    shutil.copytree(style_src, dest)
    fixed = sum(strip(p) for p in sorted(dest.rglob("*.svg*")) if p.suffix in (".svg", ".svgz"))
    stamp.touch()
    print(f"Installed {dest}; removed stale colour stylesheets from {fixed} SVGs")


if __name__ == "__main__":
    main()
