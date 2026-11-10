"""Outils pour les sprites : planche-contact numérotée et redimensionnement uniforme.

    python sprites.py sheet  <dossier> <sortie.png>
    python sprites.py resize <dossier_source> <dossier_dest> [--size 128] [--margin 4]
"""

import argparse
import sys
from pathlib import Path

from PIL import Image, ImageDraw


def trimmed(path):
    """Ouvre l'image en RGBA et la recadre sur ses pixels non transparents."""
    img = Image.open(path).convert("RGBA")
    bbox = img.getchannel("A").getbbox()
    return img.crop(bbox) if bbox else img, img.size, bbox


def fit(img, box):
    """Agrandit/réduit au plus proche voisin pour tenir dans box x box sans déformer."""
    k = min(box / img.width, box / img.height)
    size = (max(1, round(img.width * k)), max(1, round(img.height * k)))
    return img.resize(size, Image.NEAREST)


def sheet(src, out, cell=150, cols=9, raw=False):
    files = sorted(Path(src).glob("*.png"))
    rows = -(-len(files) // cols)
    board = Image.new("RGBA", (cols * cell, rows * cell), (60, 60, 70, 255))
    draw = ImageDraw.Draw(board)
    for i, f in enumerate(files):
        img, size, bbox = trimmed(f)
        # raw : fichier tel quel, pour juger des tailles réelles
        thumb = Image.open(f).convert("RGBA") if raw else fit(img, cell - 24)
        x, y = (i % cols) * cell, (i // cols) * cell
        board.alpha_composite(thumb, (x + (cell - thumb.width) // 2, y + 18 + (cell - 18 - thumb.height) // 2))
        draw.text((x + 4, y + 2), str(i), fill=(255, 220, 0, 255))
        cw, ch = (bbox[2] - bbox[0], bbox[3] - bbox[1]) if bbox else size
        print(f"{i:2d}  {f.name:<34} canvas {size[0]}x{size[1]}  contenu {cw}x{ch}")
    board.save(out)


def resize(src, dst, size, margin):
    dst = Path(dst)
    dst.mkdir(parents=True, exist_ok=True)
    for f in sorted(Path(src).glob("*.png")):
        img, _, _ = trimmed(f)
        sprite = fit(img, size - 2 * margin)
        canvas = Image.new("RGBA", (size, size), (0, 0, 0, 0))
        canvas.alpha_composite(sprite, ((size - sprite.width) // 2, (size - sprite.height) // 2))
        canvas.save(dst / f.name)
        print(f"{f.name:<34} contenu {img.width}x{img.height} -> {sprite.width}x{sprite.height}")


def main():
    p = argparse.ArgumentParser()
    sub = p.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("sheet")
    s.add_argument("src")
    s.add_argument("out")
    s.add_argument("--raw", action="store_true")
    r = sub.add_parser("resize")
    r.add_argument("src")
    r.add_argument("dst")
    r.add_argument("--size", type=int, default=128)
    r.add_argument("--margin", type=int, default=4)
    a = p.parse_args()
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    if a.cmd == "sheet":
        sheet(a.src, a.out, raw=a.raw)
    else:
        resize(a.src, a.dst, a.size, a.margin)


if __name__ == "__main__":
    main()
