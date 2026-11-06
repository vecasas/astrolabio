#!/usr/bin/env python3
"""Valida las traducciones de scripts/i18n/*.tsv y genera Sources/Astrolabio/Localization/Translations.swift.
Cada línea: clave(es) \t en \t fr \t de \t zh \t ru"""
import os, re, json, sys, glob, subprocess
HERE = os.path.dirname(os.path.abspath(__file__))
LANGS = ['en', 'fr', 'de', 'zh', 'ru']
SPEC = re.compile(r'%(?:(\d+)\$)?[-+#0]*\d*(?:\.\d+)?([@dfi])|%%')

def specs(s):
    out = []
    for m in SPEC.finditer(s):
        if m.group(0) == '%%': continue
        out.append((int(m.group(1)) if m.group(1) else None, m.group(2)))
    return out

def compatible(key, tr):
    k = [t for _, t in specs(key)]
    t = specs(tr)
    if all(p is None for p, _ in t):
        return [x for _, x in t] == k
    if any(p is None for p, _ in t): return False
    return sorted(p for p, _ in t) == list(range(1, len(k) + 1)) and all(k[p - 1] == ty for p, ty in t)

keys = set(json.loads(subprocess.check_output([sys.executable, '-I', os.path.join(HERE, 'i18n_keys.py')])))
tables = {l: {} for l in LANGS}
errors = []
for path in sorted(glob.glob(os.path.join(HERE, 'i18n', '*.tsv'))):
    for n, line in enumerate(open(path, encoding='utf-8').read().split('\n'), 1):
        if not line.strip(): continue
        cols = line.split('\t')
        if len(cols) != 6: errors.append(f'{os.path.basename(path)}:{n}: {len(cols)} columnas'); continue
        key = cols[0]
        if key not in keys: continue          # clave que ya no existe en el código
        for l, t in zip(LANGS, cols[1:]):
            if not compatible(key, t): errors.append(f'{os.path.basename(path)}:{n} [{l}] huecos distintos: {key!r} → {t!r}')
            tables[l][key] = t
missing = sorted(k for k in keys if any(k not in tables[l] for l in LANGS))
for k in missing: errors.append(f'falta traducción: {k!r}')
if errors:
    print('\n'.join(errors)); sys.exit(1)
out = ['import Foundation', '',
       '/// Tablas de traducción (texto en español → idioma). Generado por scripts/i18n_build.py',
       '/// a partir de scripts/i18n/*.tsv. No editar a mano.',
       'enum Translations {']
for l in LANGS:
    js = json.dumps(tables[l], ensure_ascii=False, sort_keys=True, indent=0)
    assert '"#' not in js
    out.append(f'    static let {l} = #"""\n{js}\n"""#')
out += ['',
        '    static func load() -> [AppLanguage: [String: String]] {',
        '        func parse(_ s: String) -> [String: String] {',
        '            (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [String: String] ?? [:]',
        '        }',
        '        return [.en: parse(en), .fr: parse(fr), .de: parse(de), .zh: parse(zh), .ru: parse(ru)]',
        '    }', '}', '']
open(os.path.join(HERE, '..', 'Sources', 'Astrolabio', 'Localization', 'Translations.swift'), 'w', encoding='utf-8').write('\n'.join(out))
print(f'OK: {len(keys)} textos × {len(LANGS)} idiomas')
