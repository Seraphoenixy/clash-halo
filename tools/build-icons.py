"""Rebuilds Clash Halo's platform icons from Clash Verge Rev's cat mark.

Source artwork: D:\\project\\clash-verge-rev, file
src-tauri/icons/clash-verge.icon/Assets/ClashVergeCat.svg (GPL-3.0).
This project is GPL-3.0-or-later (see 方案.md), so the mark is reused as-is and
only recoloured; the attribution below must stay in any redistribution.

Approach: the SVG path is parsed and filled with Pillow. No SVG renderer is
installed on the build machine, and pulling one in just to rasterise a single
path would add a dependency for one file. Filling the path directly also lets
every output size be rasterised at its own resolution (16 px tray through 512 px
preview) instead of downscaling a 256 px master, which is what keeps small icons
legible.

Run: py -3 tools/build-icons.py
"""

from __future__ import annotations

import io
import os
import re
import struct

from PIL import Image, ImageDraw

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

SOURCE_SVG = os.path.join(
    os.path.dirname(ROOT), "clash-verge-rev",
    "src-tauri", "icons", "clash-verge.icon", "Assets", "ClashVergeCat.svg",
)

# Clash Halo palette (see apps/flutter/lib/src/theme.dart).
PRIMARY = (0x6B, 0x4F, 0xBB)        # HaloColors.primary, brand violet

GRID = 300.0
SS = 4                               # supersampling factor


# --------------------------------------------------------------------------
# Minimal SVG path support: M, C, Z (that is all the source file uses).
# --------------------------------------------------------------------------

TOKEN = re.compile(r"[MmCcZz]|-?\d*\.?\d+(?:e-?\d+)?")


def parse_path(d: str):
    """Parse the source path into a list of sub-paths (lists of points)."""
    tokens = TOKEN.findall(d)
    i = 0
    subpaths = []
    current = []
    pos = (0.0, 0.0)

    def num():
        nonlocal i
        v = float(tokens[i])
        i += 1
        return v

    cmd = None
    while i < len(tokens):
        t = tokens[i]
        if t.isalpha():
            cmd = t
            i += 1
            if cmd in "Zz":
                if current:
                    subpaths.append(current)
                    current = []
                continue
        if cmd in "Mm":
            x, y = num(), num()
            if current:
                subpaths.append(current)
            current = [(x, y)]
            pos = (x, y)
            cmd = "L" if cmd == "M" else "l"   # subsequent pairs are lineto
        elif cmd in "Cc":
            x1, y1, x2, y2, x, y = (num() for _ in range(6))
            if cmd == "c":
                x1 += pos[0]; y1 += pos[1]
                x2 += pos[0]; y2 += pos[1]
                x += pos[0]; y += pos[1]
            # Sample the cubic into segments.
            for s in range(1, 25):
                u = s / 24.0
                a = 1 - u
                px = (a**3 * pos[0] + 3 * a**2 * u * x1
                      + 3 * a * u**2 * x2 + u**3 * x)
                py = (a**3 * pos[1] + 3 * a**2 * u * y1
                      + 3 * a * u**2 * y2 + u**3 * y)
                current.append((px, py))
            pos = (x, y)
        elif cmd in "Ll":
            x, y = num(), num()
            if cmd == "l":
                x += pos[0]; y += pos[1]
            current.append((x, y))
            pos = (x, y)
        else:
            i += 1
    if current:
        subpaths.append(current)
    return subpaths


def load_source_paths():
    with open(SOURCE_SVG, encoding="utf-8") as fh:
        svg = fh.read()
    match = re.search(r'<path d="([^"]+)"', svg)
    if not match:
        raise SystemExit(f"no <path> in {SOURCE_SVG}")
    return parse_path(match.group(1))


def render_paths(size: int, paths, *, background: bool = True,
                 fill=(255, 255, 255, 255), hole_fill=(0x2B, 0x2B, 0x2B, 255),
                 disc=(0x6B, 0x4F, 0xBB, 255)) -> Image.Image:
    """Rasterise the cat mark at size x size.

    The source file is one compound SVG path: the head outline followed by three
    counter-shapes (two eyes, one nose). Pillow's `polygon` has no fill rule, so
    filling the sub-paths one after another paints the holes over instead of
    cutting them out; the largest sub-path is filled as the face and the
    counter-shapes are painted separately.

    The holes are painted with |hole_fill| rather than left transparent. In the
    source the mark is white on a blue disc, so the eyes appear blue; here the
    face is white on violet, and letting the violet disc show through loses
    contrast at small sizes.
    """
    big = size * SS
    img = Image.new("RGBA", (big, big), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)
    f = big / GRID

    if background:
        # Flat brand colour, nothing else. An earlier draft put a cyan ring and a
        # darker rim inside the disc; at real sizes the ring competed with the
        # face and read as a second, unrelated logo.
        draw.ellipse([0, 0, big - 1, big - 1], fill=disc)

    if not paths:
        raise SystemExit("source path parsed to nothing")

    # Largest bounding box first: that is the face; the rest are the holes.
    ordered = sorted(
        paths,
        key=lambda p: (max(x for x, _ in p) - min(x for x, _ in p))
                      * (max(y for _, y in p) - min(y for _, y in p)),
        reverse=True,
    )
    face_mask = Image.new("L", (big, big), 0)
    ImageDraw.Draw(face_mask).polygon(
        [(x * f, y * f) for x, y in ordered[0]], fill=255)

    face = Image.new("RGBA", (big, big), fill)
    img.alpha_composite(
        Image.composite(face, Image.new("RGBA", (big, big), (0, 0, 0, 0)), face_mask))

    if hole_fill is not None:
        holes_mask = Image.new("L", (big, big), 0)
        holes = ImageDraw.Draw(holes_mask)
        for hole in ordered[1:]:
            pts = [(x * f, y * f) for x, y in hole]
            if len(pts) >= 3:
                holes.polygon(pts, fill=255)
        hole_layer = Image.new("RGBA", (big, big), hole_fill)
        img.alpha_composite(
            Image.composite(hole_layer, Image.new("RGBA", (big, big), (0, 0, 0, 0)), holes_mask))

    return img.resize((size, size), Image.LANCZOS)


def write_ico(path: str, images) -> None:
    """Multi-size .ico, one PNG payload per size.

    A single 256 px layer squashed to 16 px is exactly the blurry taskbar icon
    this project used to ship; Windows picks the closest match when the sizes are
    all present.
    """
    images = sorted(images, key=lambda im: im.width)
    blobs = []
    for im in images:
        buf = io.BytesIO()
        im.save(buf, format="PNG")
        blobs.append(buf.getvalue())

    header = struct.pack("<HHH", 0, 1, len(images))
    directory = b""
    offset = 6 + 16 * len(images)
    for im, blob in zip(images, blobs):
        w = 0 if im.width >= 256 else im.width
        h = 0 if im.height >= 256 else im.height
        directory += struct.pack("<BBBBHHII", w, h, 0, 0, 1, 32, len(blob), offset)
        offset += len(blob)
    with open(path, "wb") as fh:
        fh.write(header + directory + b"".join(blobs))


def main() -> None:
    if not os.path.exists(SOURCE_SVG):
        raise SystemExit(
            f"找不到源图标：{SOURCE_SVG}\n"
            "该文件来自 clash-verge-rev（GPL-3.0），需要先检出到同级目录。"
        )
    paths = load_source_paths()

    win = os.path.join(ROOT, "apps", "flutter", "windows", "runner", "resources")
    sizes = (16, 20, 24, 32, 40, 48, 64, 128, 256)
    write_ico(os.path.join(win, "app_icon.ico"), [render_paths(s, paths) for s in sizes])
    print(f"app_icon.ico: {len(sizes)} sizes ({', '.join(map(str, sizes))})")

    # Tray reference files, one per state. The host carries the same images
    # baked in (trayicon_gen.go); these exist so they can be inspected as files.
    tray_states = {
        "tray-icon.ico": (0x6B, 0x4F, 0xBB, 255),      # idle, brand violet
        "tray-icon-active.ico": (0x3E, 0x9A, 0x3E, 255),  # proxying, green
        "tray-icon-tun.ico": (0x0F, 0x6C, 0xBD, 255),  # TUN, blue
    }
    for name, colour in tray_states.items():
        write_ico(os.path.join(win, name),
                  [render_paths(s, paths, disc=colour) for s in (16, 24, 32, 48, 64, 256)])
    print("tray icons: 3 states x 6 sizes")

    for size in (44, 150, 310):
        render_paths(size, paths).save(os.path.join(win, f"halo-logo-{size}.png"))
    print("store logos: 44/150/310")

    android = os.path.join(ROOT, "apps", "flutter", "android", "app", "src", "main", "res")
    for bucket, size in (("mdpi", 48), ("hdpi", 72), ("xhdpi", 96),
                         ("xxhdpi", 144), ("xxxhdpi", 192)):
        render_paths(size, paths).save(os.path.join(android, f"mipmap-{bucket}", "ic_launcher.png"))
    print("android launchers: 5 densities")

    # Bake the tray icon into the host binary: the host ships as a single exe and
    # must not depend on an image file being present next to it.
    import importlib.util
    spec = importlib.util.spec_from_file_location(
        "tray_icon_gen", os.path.join(ROOT, "tools", "tray_icon_gen.py"))
    tray_gen = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(tray_gen)
    tray_gen.build(render_paths, paths,
                   os.path.join(ROOT, "native", "windows", "cmd", "halo-host",
                                "trayicon_gen.go"))

    # Flutter-side asset for the sidebar logo.
    import importlib.util as _ilu
    _spec = _ilu.spec_from_file_location(
        "brand_asset_gen", os.path.join(ROOT, "tools", "brand_asset_gen.py"))
    _gen = _ilu.module_from_spec(_spec)
    _spec.loader.exec_module(_gen)
    _gen.write(render_paths, paths,
               os.path.join(ROOT, "apps", "flutter", "assets", "brand"))

    docs = os.path.join(ROOT, "docs", "images")
    os.makedirs(docs, exist_ok=True)
    render_paths(512, paths).save(os.path.join(docs, "brand-cat.png"))
    render_paths(32, paths).resize((256, 256), Image.NEAREST).save(
        os.path.join(docs, "brand-cat-small.png"))
    print("docs previews")


if __name__ == "__main__":
    main()
