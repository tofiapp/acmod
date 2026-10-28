"""Renders the display pages recorded by test_display.lua (tests/output/display/*.txt: the draw commands of the fake
canvas) into PNG previews next to them, plus one contact sheet tests/output/display_previews.png.

    python3 -I tests/ledcontrol/tools/render_display.py

The game draws with Bahnschrift SemiBold SemiCondensed (DirectWrite); here a condensed DejaVu Sans Bold stands in,
scaled horizontally to the width the test's font metric gave the text, so the boxes and the fitting are what the
app computed, the glyph shapes are not. Needs Pillow (pip install pillow); without it the PNGs are skipped.
"""
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parents[3]
OUT = ROOT / "tests" / "output" / "display"
SHEET = ROOT / "tests" / "output" / "display_previews.png"
FONTS = ["/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf", "C:/Windows/Fonts/bahnschrift.ttf",
         "/Library/Fonts/Arial Bold.ttf"]


def load_font(size):
    from PIL import ImageFont
    for f in FONTS:
        try:
            return ImageFont.truetype(f, max(1, int(round(size))))
        except OSError:
            continue
    return ImageFont.load_default()


def colour(r, g, b, a):
    return (int(float(r) * 255 + 0.5), int(float(g) * 255 + 0.5), int(float(b) * 255 + 0.5), int(float(a) * 255 + 0.5))


def render(path):
    from PIL import Image, ImageDraw
    lines = path.read_text(encoding="utf-8").splitlines()
    w, h = (int(v) for v in lines[0].split()[1:3])
    img = Image.new("RGBA", (w, h), (0, 0, 0, 255))
    draw = ImageDraw.Draw(img)
    for row in lines[1:]:
        if row.startswith("rect "):
            parts = row.split()
            x1, y1, x2, y2, r, g, b, a = parts[1:9]
            rounding = float(parts[9]) if len(parts) > 9 else 0
            box = [float(x1), float(y1), max(float(x1), float(x2) - 1), max(float(y1), float(y2) - 1)]
            if rounding > 0.5:
                draw.rounded_rectangle(box, radius=rounding, fill=colour(r, g, b, a))
            else:
                draw.rectangle(box, fill=colour(r, g, b, a))
        elif row.startswith("text "):
            head, _, text = row.partition("|")
            x1, y1, x2, y2, r, g, b, a, size, ha, va = head.split()[1:12]
            x1, y1, x2, y2, size = float(x1), float(y1), float(x2), float(y2), float(size)
            font = load_font(size)
            box = draw.textbbox((0, 0), text, font=font)
            tw, th = box[2] - box[0], box[3] - box[1]
            # the width the app fitted with (mock metric 0.52 x size per character): squeeze the stand-in font to it
            target = sum(1 for _ in text) * size * 0.52
            layer = Image.new("RGBA", (max(1, tw), max(1, th)), (0, 0, 0, 0))
            ImageDraw.Draw(layer).text((-box[0], -box[1]), text, font=font, fill=colour(r, g, b, a))
            if tw > 0 and target > 0:
                layer = layer.resize((max(1, int(target)), max(1, th)))
                tw = layer.size[0]
            ha, va = int(ha), int(va)
            x = x1 if ha < 0 else (x2 - tw if ha > 0 else (x1 + x2 - tw) / 2)
            y = y1 if va < 0 else (y2 - th if va > 0 else (y1 + y2 - th) / 2)
            # clipped to the box, as ui.dwriteDrawTextClipped does
            px, py = int(round(x)), int(round(y))
            cx1, cy1 = max(0, int(x1) - px), max(0, int(y1) - py)
            cx2, cy2 = min(layer.size[0], int(x2) - px), min(layer.size[1], int(y2) - py)
            if cx2 > cx1 and cy2 > cy1:
                part = layer.crop((cx1, cy1, cx2, cy2))
                img.alpha_composite(part, (px + cx1, py + cy1))
    out = path.with_suffix(".png")
    img.save(out)
    return out, img


def main():
    files = sorted(OUT.glob("*.txt"))
    if not files:
        print("display previews: nothing recorded (run test_display.lua first)")
        return 0
    try:
        from PIL import Image, ImageDraw
    except ImportError:
        print("display previews: Pillow missing (pip install pillow), PNGs skipped")
        return 0
    made = []
    for f in files:
        made.append(render(f))
    # contact sheet: one row per size, pages first
    rows = {}
    for out, img in made:
        size = out.stem.rsplit("_", 1)[-1]
        rows.setdefault(size, []).append((out.stem.rsplit("_", 1)[0], img))
    scale = 0.5
    pad = 8
    sheet_w = max(sum(int(i.size[0] * scale) + pad for _, i in r) for r in rows.values()) + pad
    sheet_h = sum(max(int(i.size[1] * scale) for _, i in r) + pad + 14 for r in rows.values()) + pad
    sheet = Image.new("RGB", (sheet_w, sheet_h), (40, 40, 44))
    d = ImageDraw.Draw(sheet)
    y = pad
    for size, r in rows.items():
        x = pad
        hmax = 0
        for name, img in r:
            t = img.resize((int(img.size[0] * scale), int(img.size[1] * scale)))
            sheet.paste(t, (x, y + 14))
            d.text((x, y), f"{name} {size}", fill=(200, 200, 200))
            x += t.size[0] + pad
            hmax = max(hmax, t.size[1])
        y += hmax + pad + 14
    sheet.save(SHEET)
    print(f"display previews: {len(made)} PNGs in {OUT.relative_to(ROOT)}, contact sheet {SHEET.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
