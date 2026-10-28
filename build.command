#!/bin/bash
# Compila Carpetas Dock, lo instala en Aplicaciones y actualiza las carpetas ya creadas.
# Uso: doble clic en este archivo, o ./build.command desde el Terminal.
cd "$(dirname "$0")"
LOG="$PWD/build.log"
APPNAME="Carpetas Dock"
EXE="CarpetasDock"
(
  set -e
  echo "== Compilando $(date '+%H:%M:%S')"
  TMP="$(mktemp -d)"
  APP="$TMP/$APPNAME.app"
  mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
  SDK="$(xcrun --show-sdk-path)"
  # Binario universal (Apple Silicon + Intel).
  for ARCH in arm64 x86_64; do
    xcrun swiftc -swift-version 5 -parse-as-library -O -target "$ARCH-apple-macos26.0" -sdk "$SDK" \
      -module-name CarpetasDock Sources/*.swift -o "$TMP/$EXE-$ARCH"
  done
  lipo -create "$TMP/$EXE-arm64" "$TMP/$EXE-x86_64" -output "$APP/Contents/MacOS/$EXE"
  cp Resources/Info.plist "$APP/Contents/Info.plist"
  # El icono se genera la primera vez a partir de iconos de apps del sistema (no se incluye en el repositorio).
  if [ ! -f Resources/AppIcon.icns ]; then
    "$APP/Contents/MacOS/$EXE" --render-icon "$PWD/Resources/AppIcon.icns" || echo "(sin icono)"
  fi
  [ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
  codesign --force --sign - "$APP"
  DEST=/Applications
  [ -w "$DEST" ] || DEST="$HOME/Applications"
  mkdir -p "$DEST"
  pkill -x "$EXE" || true          # cierra también las carpetas (usan el mismo ejecutable)
  sleep 0.7
  rm -rf "$DEST/$APPNAME.app"
  cp -R "$APP" "$DEST/"
  LSR=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
  "$LSR" -f "$DEST/$APPNAME.app" || true
  # Las carpetas ya creadas usan el mismo ejecutable: se actualiza y se vuelven a abrir en segundo plano.
  for F in "$HOME/Applications/Carpetas Dock/"*.app; do
    [ -d "$F" ] || continue
    cp "$APP/Contents/MacOS/$EXE" "$F/Contents/MacOS/$EXE"
    codesign --force --sign - "$F"
    "$LSR" -f "$F" || true
    open -g "$F" --args --silent || true
    echo "   carpeta actualizada: $(basename "$F")"
  done
  rm -rf "$TMP"
  echo "== BUILD_OK $(date '+%H:%M:%S')"
) > "$LOG" 2>&1
if grep -q BUILD_OK "$LOG"; then
  DEST=/Applications; [ -w "$DEST" ] || DEST="$HOME/Applications"
  open "$DEST/$APPNAME.app"
  rm -f "$LOG"
else
  echo "La compilación ha fallado. Detalles en build.log:"
  tail -30 "$LOG"
  osascript -e 'display notification "Revisa build.log" with title "Carpetas Dock: la compilación ha fallado"' 2>/dev/null
fi
exit 0
