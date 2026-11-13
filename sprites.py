"""Outils pour les sprites : planche-contact numérotée, redimensionnement uniforme, détourage.

    python sprites.py sheet  <dossier> <sortie.png>
    python sprites.py resize <dossier_source> <dossier_dest> [--size 128] [--margin 4]
    python sprites.py cutout <image.png> <sortie.png> [--size 128] [--margin 4] [--tolerance 40]
"""

import argparse
import math
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


def cutout(src, dst, size, margin, tolerance):
    """Image opaque sur fond uni (ex. dessin 512x512 sur fond blanc) -> sprite transparent.

    Le fond est la couleur du coin haut gauche ; il est retiré par remplissage depuis les
    bords de l'image, donc les zones claires entourées par le contour (yeux, dents) restent.
    La réduction se fait par un facteur entier (512 -> 128 : divisé par 4) pour garder
    les pixels réguliers, puis le sprite est centré comme ceux de `resize`.
    """
    img = Image.open(src).convert("RGBA")
    rgb = img.convert("RGB")
    marker = (1, 254, 3)  # couleur témoin, absente du dessin
    assert marker not in {c for _, c in rgb.getcolors(1 << 24)}, "couleur témoin présente dans l'image"
    w, h = rgb.size
    border = [(x, y) for x in range(w) for y in (0, h - 1)] + [(x, y) for y in range(h) for x in (0, w - 1)]
    for xy in border:
        if rgb.getpixel(xy) != marker:
            ImageDraw.floodfill(rgb, xy, marker, thresh=tolerance)
    mask = Image.new("L", (w, h), 255)
    mask.putdata([0 if px == marker else 255 for px in rgb.getdata()])
    img.putalpha(mask)

    bbox = mask.getbbox()
    img = img.crop(bbox)
    factor = max(1, math.ceil(max(img.width, img.height) / (size - 2 * margin)))
    small = (max(1, round(img.width / factor)), max(1, round(img.height / factor)))
    # RGBa : alpha prémultiplié, pour que le fond retiré ne déteigne pas sur les bords.
    sprite = img.convert("RGBa").resize(small, Image.BOX).convert("RGBA")
    canvas = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    canvas.alpha_composite(sprite, ((size - sprite.width) // 2, (size - sprite.height) // 2))
    canvas.save(dst)
    print(f"{Path(src).name}: fond retiré, contenu {img.width}x{img.height} / {factor} -> {sprite.width}x{sprite.height}")


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
    c = sub.add_parser("cutout")
    c.add_argument("src")
    c.add_argument("dst")
    c.add_argument("--size", type=int, default=128)
    c.add_argument("--margin", type=int, default=4)
    c.add_argument("--tolerance", type=int, default=40, help="écart toléré avec la couleur du fond")
    a = p.parse_args()
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    if a.cmd == "sheet":
        sheet(a.src, a.out, raw=a.raw)
    elif a.cmd == "cutout":
        cutout(a.src, a.dst, a.size, a.margin, a.tolerance)
    else:
        resize(a.src, a.dst, a.size, a.margin)


if __name__ == "__main__":
    main()
