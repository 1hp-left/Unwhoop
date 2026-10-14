"""Render the original Unwhoop U/pulse mark as an opaque iOS app icon."""
import json
from pathlib import Path
from PIL import Image, ImageDraw

root = Path(__file__).resolve().parents[1]
assets = root / "Unwhoop/Resources/Assets.xcassets"
icon = assets / "AppIcon.appiconset"
icon.mkdir(parents=True, exist_ok=True)
(assets / "Contents.json").write_text(json.dumps({"info": {"version": 1, "author": "xcode"}}))
scale = 3
image = Image.new("RGB", (1024 * scale, 1024 * scale), (14, 18, 23))
draw = ImageDraw.Draw(image)
def line(points, color, width):
    points = [(int(x * scale), int(y * scale)) for x, y in points]
    draw.line(points, fill=color, width=int(width * scale), joint="curve")
    radius = width * scale / 2
    for x, y in points:
        draw.ellipse((x-radius, y-radius, x+radius, y+radius), fill=color)

import math
u = [(280, 260), (280, 535)]
u += [(512 + 232 * math.cos(math.pi - t * math.pi / 120),
       535 + 232 * math.sin(math.pi - t * math.pi / 120)) for t in range(121)]
u += [(744, 260)]
line(u, (244, 248, 251), 94)
line([(355, 465), (425, 465), (475, 380), (525, 540), (580, 435), (650, 435)], (64, 163, 245), 48)
image.resize((1024, 1024), Image.Resampling.LANCZOS).save(icon / "AppIcon.png")
(icon / "Contents.json").write_text(json.dumps({
    "images": [{"filename": "AppIcon.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"}],
    "info": {"version": 1, "author": "xcode"}
}, indent=2))
