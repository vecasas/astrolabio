#!/bin/bash
# Compila Astrolabio en modo optimizado y crea Astrolabio.app en la carpeta dist/.
set -euo pipefail
cd "$(dirname "$0")/.."

# Si Xcode está instalado pero no seleccionado (xcode-select apunta a las Command Line
# Tools), se usa Xcode solo para esta compilación, sin cambiar la configuración del sistema.
if [[ -z "${DEVELOPER_DIR:-}" && "$(xcode-select -p)" == *CommandLineTools* && -d /Applications/Xcode.app ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

# Binario universal (Apple Silicon e Intel) cuando la herramienta lo permite.
if swift build -c release --arch arm64 --arch x86_64; then
  BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/Astrolabio"
else
  echo "Aviso: no se pudo crear el binario universal; se compila solo para esta arquitectura."
  swift build -c release
  BIN="$(swift build -c release --show-bin-path)/Astrolabio"
fi

APP="dist/Astrolabio.app"
# Versión y autor desde Sources/Astrolabio/AppInfo.swift (un único sitio).
VERSION=$(sed -n 's/.*static let version = "\(.*\)".*/\1/p' Sources/Astrolabio/AppInfo.swift)
BUILD=$(sed -n 's/.*static let build = "\(.*\)".*/\1/p' Sources/Astrolabio/AppInfo.swift)
AUTHOR=$(sed -n 's/.*static let author = "\(.*\)".*/\1/p' Sources/Astrolabio/AppInfo.swift)
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Astrolabio"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Astrolabio</string>
  <key>CFBundleDevelopmentRegion</key><string>es</string>
  <key>CFBundleLocalizations</key><array><string>es</string><string>en</string><string>fr</string><string>de</string><string>zh-Hans</string><string>ru</string></array>
  <key>CFBundleDisplayName</key><string>Astrolabio</string>
  <key>CFBundleIdentifier</key><string>es.vecasas.astrolabio</string>
  <key>CFBundleExecutable</key><string>Astrolabio</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>CFBundleIconFile</key><string>Astrolabio</string>
  <key>NSHumanReadableCopyright</key><string>© 2026 $AUTHOR</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSLocalNetworkUsageDescription</key><string>Astrolabio se conecta a tu Seestar en la red local y, si lo activas, deja que tu móvil lo controle desde la misma wifi.</string>
  <key>NSAppTransportSecurity</key>
  <dict><key>NSAllowsLocalNetworking</key><true/></dict>
</dict>
</plist>
PLIST

# Carpetas de idioma: macOS muestra sus propios textos (menús del sistema) en el idioma del Mac.
for lang in es en fr de zh-Hans ru; do
  mkdir -p "$APP/Contents/Resources/$lang.lproj"
  printf '"CFBundleName" = "Astrolabio";\n' > "$APP/Contents/Resources/$lang.lproj/InfoPlist.strings"
done

cp scripts/assets/Astrolabio.icns "$APP/Contents/Resources/Astrolabio.icns"

# Firma local (ad hoc) para que macOS permita abrirla en este Mac.
codesign --force --deep --sign - "$APP"
echo "Listo: $APP"
