#!/bin/bash
# Crea dist/Astrolabio-<versión>.dmg: la app y un acceso a Aplicaciones para arrastrarla.
set -euo pipefail
cd "$(dirname "$0")/.."
./scripts/make_app.sh
VERSION=$(sed -n 's/.*static let version = "\(.*\)".*/\1/p' Sources/Astrolabio/AppInfo.swift)
DMG="dist/Astrolabio-$VERSION.dmg"
STAGE=$(mktemp -d)
cp -R dist/Astrolabio.app "$STAGE/"
ln -s /Applications "$STAGE/Aplicaciones"
cat > "$STAGE/LÉEME.txt" <<TXT
Astrolabio $VERSION

1. Arrastra Astrolabio a la carpeta Aplicaciones.
2. La primera vez, abre Aplicaciones, haz clic derecho sobre Astrolabio y elige «Abrir»
   (la app está firmada localmente, no con un certificado de Apple, y macOS lo pide una vez).

Drag Astrolabio to Applications. The first time, right-click it and choose "Open".
TXT
rm -f "$DMG"
RAW="$(mktemp -d)/raw.dmg"
# makehybrid crea la imagen sin montarla (funciona también en entornos donde montar está restringido);
# después se convierte al formato comprimido habitual.
hdiutil makehybrid -hfs -hfs-volume-name "Astrolabio $VERSION" -o "$RAW" "$STAGE" >/dev/null
hdiutil convert "$RAW" -format UDZO -o "$DMG" >/dev/null
rm -f "$RAW"
rm -rf "$STAGE"
hdiutil verify "$DMG" >/dev/null && echo "Listo: $DMG ($(du -h "$DMG" | cut -f1))"
