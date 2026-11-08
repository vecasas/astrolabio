#!/usr/bin/env python3
"""Extrae todos los textos traducibles de Astrolabio (claves en español).
Uso: python3 scripts/i18n_keys.py > claves.json"""
import re, os, json, sys
ROOT = os.path.join(os.path.dirname(__file__), '..', 'Sources', 'Astrolabio')
keys = set()
lit = re.compile(r'tr\("((?:[^"\\]|\\.)*)"')
def unescape(s):
    return s.encode('utf-8').decode('unicode_escape').encode('latin-1').decode('utf-8') if '\\' in s else s
for root, _, files in os.walk(ROOT):
    for f in files:
        if not f.endswith('.swift') or f in ('Translations.swift', 'StarData.swift', 'MoonTexture.swift'): continue
        src = open(os.path.join(root, f), encoding='utf-8').read()
        for m in lit.finditer(src):
            keys.add(unescape(m.group(1)))
        # Valores de enums que se muestran traducidos con tr(rawValue)
        for m in re.finditer(r'enum (ObjectKind|AppSection|PickStyle|Tab|Filter|Range|ListStatus)\b[^{]*\{(.*?)\n\s*(?:var|static|func|init)', src, re.S):
            for v in re.findall(r'=\s*"((?:[^"\\]|\\.)*)"', m.group(2)):
                keys.add(unescape(v))
        # Títulos de grupos de la barra lateral y notas de planetas
        for m in re.finditer(r'\("([^"]+)", \[\.', src): keys.add(m.group(1))
        for m in re.finditer(r'note: "((?:[^"\\]|\\.)*)"', src): keys.add(unescape(m.group(1)))
        for m in re.finditer(r'static let planetNames = \[([^\]]*)\]', src):
            keys.update(re.findall(r'"([^"]+)"', m.group(1)))
# Nombres comunes del catálogo
cat = open(os.path.join(ROOT, 'Astronomy', 'Catalog.swift'), encoding='utf-8').read()
for m in re.finditer(r'^\s*"([^"|]+)\|([^"|]*)\|', cat, re.M):
    if m.group(2): keys.add(m.group(2))
extra = open(os.path.join(ROOT, 'Astronomy', 'CatalogExtra.swift'), encoding='utf-8').read()
for m in re.finditer(r'^([^|\n"/]+)\|([^|\n]+)\|(?:N|G|OC|GC|P|S)\|', extra, re.M):
    keys.add(m.group(2))
keys.discard('')
json.dump(sorted(keys), sys.stdout, ensure_ascii=False, indent=0)
