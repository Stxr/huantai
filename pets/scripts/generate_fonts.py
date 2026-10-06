#!/usr/bin/env python3
"""Generate the exact UTF-8 glyph inventory used by the board UI."""
from pathlib import Path
import subprocess
import hashlib
import json
ROOT = Path(__file__).resolve().parents[1]
font = ROOT / '.local/NotoSansCJKsc-Regular.otf'
sources = [ROOT / 'firmware/main/pet_main.c', ROOT / 'firmware/main/pet_assets.c']
symbols = ''.join(sorted({ch for p in sources for ch in p.read_text() if ord(ch) > 126}))
common = set()
for code in range(127,65536):
    ch = chr(code)
    try: ch.encode('gb2312')
    except UnicodeError: continue
    if ch.isprintable(): common.add(ch)
body_symbols = ''.join(sorted(set(symbols) | common))
converter = ROOT / '.local/font-tools/node_modules/.bin/lv_font_conv'
for size in (16, 20):
    subprocess.run([str(converter), '--font', str(font.relative_to(ROOT)), '--range', '0x20-0x7E', '--symbols', body_symbols if size == 16 else symbols,
                    '--size', str(size), '--bpp', '4', '--format', 'lvgl', '--no-compress',
                    '--lv-font-name', f'pet_font_{size}', '--lv-include', 'lvgl.h',
                    '--output', f'firmware/main/pet_font_{size}.c'], check=True, cwd=ROOT)
    generated = ROOT / f'firmware/main/pet_font_{size}.c'
    generated.write_text(generated.read_text().rstrip() + '\n')
(ROOT / 'evidence/fonts.json').write_text(json.dumps({'source':'Noto Sans CJK SC Regular',
    'sha256': hashlib.sha256(font.read_bytes()).hexdigest(), 'sizes':[16,20],
    'ascii': 'U+0020-U+007E', 'symbols': symbols, 'body_dynamic_charset': 'Printable GB2312 plus UI inventory', 'body_glyph_count': len(body_symbols)}, ensure_ascii=False, indent=2)+'\n')
print(f'Generated 2 fonts with {len(symbols)} additional glyphs')
