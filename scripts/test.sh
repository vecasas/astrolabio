#!/bin/bash
# Ejecuta las pruebas. Con solo las Command Line Tools (sin Xcode), SwiftPM no
# encuentra Testing.framework por sí mismo, así que se le pasan las rutas.
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ -z "${DEVELOPER_DIR:-}" && "$(xcode-select -p)" == *CommandLineTools* && -d /Applications/Xcode.app ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
DEV="${DEVELOPER_DIR:-$(xcode-select -p)}"
if [[ "$DEV" == *CommandLineTools* ]]; then
  F="$DEV/Library/Developer/Frameworks"
  L="$DEV/Library/Developer/usr/lib"
  exec swift test -Xswiftc -F"$F" -Xlinker -F"$F" \
    -Xlinker -rpath -Xlinker "$F" -Xlinker -rpath -Xlinker "$L" "$@"
fi
exec swift test "$@"
