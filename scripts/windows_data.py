#!/usr/bin/env python3
"""Genera los datos de la versión de Windows a partir de los de macOS (una sola fuente):
catálogo, estrellas, constelaciones, mapa de la Luna y traducciones."""
import os, re, json, base64, glob
HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, '..', 'Sources', 'Astrolabio')
OUT = os.path.join(HERE, '..', 'windows', 'Astrolabio.Core', 'Data')
os.makedirs(OUT, exist_ok=True)

def multiline(swift, name):
    m = re.search(r'static let ' + name + r' = """\n(.*?)\n"""', swift, re.S)
    return m.group(1)

star = open(os.path.join(SRC, 'Astronomy', 'StarData.swift'), encoding='utf-8').read()
for n in ('stars', 'lines', 'constellations'):
    open(os.path.join(OUT, n + '.txt'), 'w', encoding='utf-8').write(multiline(star, n) + '\n')

cat = open(os.path.join(SRC, 'Astronomy', 'Catalog.swift'), encoding='utf-8').read()
rows = re.findall(r'^\s*"([^"\n]*\|[^"\n]*)",\s*$', cat, re.M)
open(os.path.join(OUT, 'catalog.txt'), 'w', encoding='utf-8').write('\n'.join(rows) + '\n')

moon = open(os.path.join(SRC, 'Astronomy', 'MoonTexture.swift'), encoding='utf-8').read()
b64 = ''.join(multiline(moon, 'jpegBase64').split())
open(os.path.join(OUT, 'moon.jpg'), 'wb').write(base64.b64decode(b64))

LANGS = ['en', 'fr', 'de', 'zh', 'ru']
tables = {l: {} for l in LANGS}
for path in sorted(glob.glob(os.path.join(HERE, 'i18n', '*.tsv'))):
    for line in open(path, encoding='utf-8').read().split('\n'):
        cols = line.split('\t')
        if len(cols) == 6:
            for l, t in zip(LANGS, cols[1:]): tables[l][cols[0]] = t
win = os.path.join(HERE, 'i18n', 'windows')
for path in sorted(glob.glob(os.path.join(win, '*.tsv'))):
    for line in open(path, encoding='utf-8').read().split('\n'):
        cols = line.split('\t')
        if len(cols) == 6:
            for l, t in zip(LANGS, cols[1:]): tables[l][cols[0]] = t
json.dump(tables, open(os.path.join(OUT, 'translations.json'), 'w', encoding='utf-8'), ensure_ascii=False)
print(f'catálogo {len(rows)} · traducciones {len(tables["en"])} · datos en {os.path.relpath(OUT)}')
