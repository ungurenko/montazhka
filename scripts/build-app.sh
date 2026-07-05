#!/bin/bash
# Сборка Монтажка.app из Swift-пакета (без Xcode).
# Использование: scripts/build-app.sh [--install]
#   --install  скопировать готовое приложение в /Applications

set -euo pipefail
cd "$(dirname "$0")/.."

echo "▸ Компилирую (release)…"
swift build -c release 2>&1 | grep -v "^warning:" || true

BIN=".build/release/Montazhka"
if [ ! -f "$BIN" ]; then
  echo "✗ Сборка не удалась — бинарник не найден"
  exit 1
fi

APP="build/Монтажка.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN" "$APP/Contents/MacOS/Montazhka"
cp Resources/Info.plist "$APP/Contents/Info.plist"
if [ -f Resources/AppIcon.icns ]; then
  cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi

codesign --force -s - "$APP" 2>/dev/null

echo "✓ Готово: $APP"

if [ "${1:-}" = "--install" ]; then
  rm -rf "/Applications/Монтажка.app"
  cp -R "$APP" "/Applications/Монтажка.app"
  echo "✓ Установлено в /Applications/Монтажка.app"
fi
