#!/usr/bin/env python3
"""Copia la página del móvil (scripts/companion/page.html) a la app de Mac y a la de Windows."""
import pathlib
root = pathlib.Path(__file__).resolve().parent.parent
page = (root / "scripts/companion/page.html").read_text(encoding="utf-8")
assert '"""' not in page and "\\" not in page.replace("\\d", "")
(root / "Sources/Astrolabio/Services/CompanionPage.swift").write_text(
    "// Generado por scripts/companion_build.py a partir de scripts/companion/page.html. No editar a mano.\n"
    "enum CompanionPage {\n    static let html = #\"\"\"\n" + page + "\"\"\"#\n}\n", encoding="utf-8")
(root / "windows/Astrolabio.Core/Data/companion.html").write_text(page, encoding="utf-8")
print("página del móvil:", len(page), "bytes")
