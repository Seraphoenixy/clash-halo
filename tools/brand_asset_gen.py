"""Generate the Flutter-side brand asset: a small PNG the sidebar logo can load.

The sidebar used to draw a violet rounded square with a Material bolt icon, which
matched neither the window icon nor the tray. Regenerating the cat here keeps all
three surfaces on one artwork; the PNG is committed so a plain `flutter test`
does not need Python.

Called from tools/build-icons.py.
"""

from __future__ import annotations

import os


def write(render_fn, paths, assets_dir: str) -> None:
    os.makedirs(assets_dir, exist_ok=True)
    # 96 px covers the 24 logical-pixel logo at 4x for high-DPI displays.
    target = os.path.join(assets_dir, "brand_cat.png")
    render_fn(96, paths).save(target, optimize=True)
    print(f"wrote {os.path.relpath(target)}")
