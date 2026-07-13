"""Generate ntfsmac's macOS app icon: clean drive+connect glyph on the app's own brand-blue
gradient (Colors.swift's ntfsBlue dark/light hexes), matching the drive/arrow motif already used
throughout ui/prototype.html and StatusIcon.swift's SF Symbol choice.

Bakes the squircle mask into the bitmap itself rather than relying on macOS to apply one: that
was true pre-Big-Sur, but macOS 11+ does NOT auto-mask a plain full-bleed square anymore — it
pastes an unmasked square icon onto its own default white rounded-square backplate instead,
which is exactly the "white curved background, inner square not fitting" bug this fixes.
Corner radius ratio (~0.1811 of canvas size) matches Apple's Big Sur+ app icon template.
"""
import subprocess
import sys
from pathlib import Path

from PIL import Image, ImageDraw

SIZE = 1024
CORNER_RADIUS = round(SIZE * 0.1811)
RESOURCES_DIR = Path(__file__).resolve().parent

# --- background: diagonal gradient between the two brand blues (Colors.swift) ---
top = (45, 156, 255)      # #2D9CFF — ntfsBlue dark
bottom = (0, 122, 255)    # #007AFF — ntfsBlue light
grad = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
gd = ImageDraw.Draw(grad)
for y in range(SIZE):
    t = y / (SIZE - 1)
    r = round(top[0] + (bottom[0] - top[0]) * t)
    g = round(top[1] + (bottom[1] - top[1]) * t)
    b = round(top[2] + (bottom[2] - top[2]) * t)
    gd.line([(0, y), (SIZE, y)], fill=(r, g, b, 255))

# Clip the gradient to a squircle: draw a rounded-rect alpha mask over the full-bleed square,
# then composite so only the masked (curved) region keeps the gradient — corners become
# transparent instead of sharp 90° square corners.
mask = Image.new("L", (SIZE, SIZE), 0)
ImageDraw.Draw(mask).rounded_rectangle([0, 0, SIZE - 1, SIZE - 1], radius=CORNER_RADIUS, fill=255)
grad.putalpha(mask)

draw = ImageDraw.Draw(grad)

# --- glyph: external-drive body + activity dot + connect arrow, all white, centered ---
white = (255, 255, 255, 255)
white_dim = (255, 255, 255, 235)

cx, cy = SIZE / 2, SIZE / 2 + 90  # downward bias to leave room for the arrow above

# drive body: rounded rect
body_w, body_h = 700, 370
body_left = cx - body_w / 2
body_top = cy - body_h / 2
body_right = cx + body_w / 2
body_bottom = cy + body_h / 2
stroke_w = 42
draw.rounded_rectangle(
    [body_left, body_top, body_right, body_bottom],
    radius=78, outline=white, width=stroke_w
)

# activity dot (right side of the drive body, matches the comp's circle motif)
dot_r = 58
dot_cx = body_right - 165
dot_cy = cy
draw.ellipse(
    [dot_cx - dot_r, dot_cy - dot_r, dot_cx + dot_r, dot_cy + dot_r],
    fill=white
)

# single slot line (left side), kept minimal per "clean and simple"
line_y = cy
draw.line(
    [(body_left + 75, line_y), (dot_cx - dot_r - 65, line_y)],
    fill=white_dim, width=28
)

# connect/mount arrow above the drive (matches the up-arrow motif used for the mounted-state
# glyph throughout ui/prototype.html and the idle-state dashed variant)
arrow_cx = cx
arrow_top = body_top - 235
arrow_bottom = body_top - 50
draw.line([(arrow_cx, arrow_top), (arrow_cx, arrow_bottom)], fill=white, width=stroke_w)
head = 88
draw.line(
    [(arrow_cx - head, arrow_top + head), (arrow_cx, arrow_top), (arrow_cx + head, arrow_top + head)],
    fill=white, width=stroke_w, joint="curve"
)

source_png = RESOURCES_DIR / "AppIcon-source.png"
grad.save(source_png)
print(f"wrote {source_png}")

# --- regenerate the .iconset + .icns from the new source, same as the manual iconutil step
# this used to require by hand ---
iconset_dir = RESOURCES_DIR / "AppIcon.iconset"
if iconset_dir.exists():
    for f in iconset_dir.iterdir():
        f.unlink()
else:
    iconset_dir.mkdir()

for px, name in [
    (16, "icon_16x16"), (32, "icon_16x16@2x"),
    (32, "icon_32x32"), (64, "icon_32x32@2x"),
    (128, "icon_128x128"), (256, "icon_128x128@2x"),
    (256, "icon_256x256"), (512, "icon_256x256@2x"),
    (512, "icon_512x512"), (1024, "icon_512x512@2x"),
]:
    grad.resize((px, px), Image.LANCZOS).save(iconset_dir / f"{name}.png")

icns_path = RESOURCES_DIR / "AppIcon.icns"
result = subprocess.run(
    ["iconutil", "-c", "icns", str(iconset_dir), "-o", str(icns_path)],
    capture_output=True, text=True
)
if result.returncode != 0:
    print(f"iconutil failed: {result.stderr}", file=sys.stderr)
    sys.exit(1)

for f in iconset_dir.iterdir():
    f.unlink()
iconset_dir.rmdir()

print(f"wrote {icns_path}")
