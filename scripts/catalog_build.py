#!/usr/bin/env python3
"""Genera Sources/Astrolabio/Astronomy/CatalogExtra.swift con el catálogo ampliado de OpenNGC.

Datos: OpenNGC de Mattia Verga (https://github.com/mattiaverga/OpenNGC), licencia CC BY-SA 4.0.
El archivo generado es una adaptación de esa base de datos y se distribuye con la misma licencia.

Uso: python3 scripts/catalog_build.py ruta/a/NGC.csv
(descárgalo de https://raw.githubusercontent.com/mattiaverga/OpenNGC/master/database_files/NGC.csv)
Selección: objetos de cielo profundo con magnitud ≤ 12 o tamaño ≥ 8′, más todos los del catálogo Caldwell.
"""
import csv, os, re, sys

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, '..', 'Sources', 'Astrolabio', 'Astronomy')
KIND = {'G': 'G', 'GPair': 'G', 'GTrpl': 'G', 'GGroup': 'G', 'OCl': 'OC', 'GCl': 'GC', 'PN': 'P',
        'Neb': 'N', 'HII': 'N', 'EmN': 'N', 'RfN': 'N', 'Cl+N': 'N', 'SNR': 'S'}

def pretty(name):
    m = re.match(r'(NGC|IC)0*(\d+)(.*)$', name)
    return f"{m.group(1)} {m.group(2)}{m.group(3)}" if m else name

def num(s):
    try: return float(s)
    except (TypeError, ValueError): return None

def main(path):
    curated = open(os.path.join(SRC, 'Catalog.swift'), encoding='utf-8').read()
    curated_ids = {m.group(1).replace(' ', '').upper() for m in re.finditer(r'^\s*"([^"|]+)\|', curated, re.M)}
    caldwell = []
    for line in open(os.path.join(HERE, 'data', 'caldwell.tsv'), encoding='utf-8'):
        if line.startswith('#') or not line.strip(): continue
        n, ident, name = (line.rstrip('\n').split('\t') + ['', ''])[:3]
        caldwell.append((int(n), ident, name))
    caldwell_ids = {c[1].replace(' ', '').upper() for c in caldwell}

    rows = []
    with open(path, encoding='utf-8') as f:
        for r in csv.DictReader(f, delimiter=';'):
            kind = KIND.get(r['Type'])
            if not kind: continue
            ident = pretty(r['Name'])
            key = ident.replace(' ', '').upper()
            if r['M'] or key in curated_ids: continue          # ya están en la lista principal
            mag = num(r['V-Mag']) or num(r['B-Mag'])
            size = num(r['MajAx'])
            if not (key in caldwell_ids or (mag is not None and mag <= 12) or (size or 0) >= 8): continue
            ra, dec = r['RA'], r['Dec']
            if not ra or not dec: continue
            h, m, s = (float(x) for x in ra.split(':'))
            sign = '-' if dec.startswith('-') else '+'
            d, dm, ds = (abs(float(x)) for x in dec.lstrip('+-').split(':'))
            rows.append(f"{ident}||{kind}|{int(h):02d} {m + s / 60:05.2f}|{sign}{int(d):02d} {dm + ds / 60:04.1f}|"
                        f"{mag if mag is not None else 12:.1f}|{size if size else 1:.1f}")
    # Objetos Caldwell que no son NGC/IC.
    rows.append("Mel 25|Híades|OC|04 26.90|+15 52.0|0.5|330")
    rows.append("Coalsack|Saco de Carbón|N|12 50.00|-62 30.0|99|420")
    rows.sort(key=lambda s: (s.split('|')[0].split(' ')[0], int(re.sub(r'\D.*', '', s.split('|')[0].split(' ')[-1]) or 0)))
    cald = '\n'.join(f"{n}={ident}" for n, ident, _ in caldwell)
    out = f'''// GENERADO por scripts/catalog_build.py — no editar a mano.
// Catálogo ampliado a partir de OpenNGC (Mattia Verga, https://github.com/mattiaverga/OpenNGC),
// licencia CC BY-SA 4.0. Este archivo es una adaptación de esa base de datos y se distribuye con la
// misma licencia. Formato de cada fila: id|nombre|tipo|RA (h m)|Dec (° ′)|mag|tamaño′
// Caldwell: número=identificador (fuente: Wikipedia, «Caldwell catalogue»).

enum CatalogExtra {{
    static let rows = """
{chr(10).join(rows)}
"""

    static let caldwell = """
{cald}
"""
}}
'''
    open(os.path.join(SRC, 'CatalogExtra.swift'), 'w', encoding='utf-8').write(out)
    print(f"{len(rows)} objetos nuevos, {len(caldwell)} Caldwell")

if __name__ == '__main__':
    main(sys.argv[1])
