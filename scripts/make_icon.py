"""make_icon.py <out.appiconset> <hex> <letter> — a flat oracle icon: colour square, ring, initial.
Writes every macOS size plus the iOS 1024 and a Contents.json. Run: uv run --with pillow python scripts/make_icon.py …"""
import json, os, sys
from PIL import Image, ImageDraw, ImageFont
# make_icon.py <out.appiconset> <hex> <letter> [--from art.png]   (--from: resize a generated icon instead of drawing)
src = sys.argv[sys.argv.index('--from') + 1] if '--from' in sys.argv else None
out, hexc, letter = sys.argv[1], sys.argv[2].lstrip('#'), sys.argv[3][:2]
rgb = tuple(int(hexc[i:i+2], 16) for i in (0, 2, 4))
os.makedirs(out, exist_ok=True)
def draw(n):
    if src:
        return Image.open(src).convert('RGBA').resize((n, n), Image.LANCZOS)
    return _draw(n)
def _draw(n):
    im = Image.new('RGBA', (n, n), (0, 0, 0, 0)); d = ImageDraw.Draw(im)
    pad = int(n * 0.09); r = int(n * 0.22)
    d.rounded_rectangle([pad, pad, n - pad, n - pad], r, fill=(10, 10, 15, 255))
    w = max(2, n // 28)
    d.ellipse([n * .2, n * .2, n * .8, n * .8], outline=rgb + (255,), width=w)
    try: f = ImageFont.truetype('/System/Library/Fonts/SFNSRounded.ttf', int(n * .36))
    except Exception: f = ImageFont.truetype('/System/Library/Fonts/Helvetica.ttc', int(n * .36))
    d.text((n / 2, n / 2), letter, font=f, fill=rgb + (255,), anchor='mm')
    return im
images = []
for pt in (16, 32, 128, 256, 512):
    for sc in (1, 2):
        fn = f'mac_{pt}@{sc}x.png'; draw(pt * sc).save(os.path.join(out, fn))
        images.append({'idiom': 'mac', 'size': f'{pt}x{pt}', 'scale': f'{sc}x', 'filename': fn})
draw(1024).convert('RGB').save(os.path.join(out, 'ios_1024.png'))
images.append({'idiom': 'universal', 'platform': 'ios', 'size': '1024x1024', 'filename': 'ios_1024.png'})
json.dump({'images': images, 'info': {'version': 1, 'author': 'xcode'}}, open(os.path.join(out, 'Contents.json'), 'w'), indent=1)
print('icon', out)
