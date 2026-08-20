#!/bin/bash

set -euo pipefail
cd "$(dirname "$0")/.."

install_app=false
universal=false
adhoc=false

for argument in "$@"; do
  case "$argument" in
    --install) install_app=true ;;
    --universal) universal=true ;;
    --adhoc) adhoc=true ;;
    *)
      echo "Использование: scripts/build-app.sh [--universal] [--adhoc] [--install]" >&2
      exit 2
      ;;
  esac
done

staging_root="$(mktemp -d "${TMPDIR:-/tmp}/montazhka-build.XXXXXX")"
cleanup() {
  case "$staging_root" in
    /tmp/*|/private/tmp/*|/var/folders/*|/private/var/folders/*) rm -rf -- "$staging_root" ;;
  esac
}
trap cleanup EXIT

binary="$staging_root/Montazhka"

scripts/verify-config.sh

if [ "$universal" = true ]; then
  universal_root=".build/universal"
  mkdir -p "$universal_root"
  echo "▸ Компилирую arm64…"
  swift build -c release --arch arm64 --scratch-path "$universal_root/arm64"
  arm64_bin_dir="$(swift build -c release --arch arm64 --scratch-path "$universal_root/arm64" --show-bin-path)"

  echo "▸ Компилирую x86_64…"
  swift build -c release --arch x86_64 --scratch-path "$universal_root/x86_64"
  x86_bin_dir="$(swift build -c release --arch x86_64 --scratch-path "$universal_root/x86_64" --show-bin-path)"

  lipo -create "$arm64_bin_dir/Montazhka" "$x86_bin_dir/Montazhka" -output "$binary"
else
  echo "▸ Компилирую для текущего Mac…"
  swift build -c release
  bin_dir="$(swift build -c release --show-bin-path)"
  cp "$bin_dir/Montazhka" "$binary"
fi

app_staging="$staging_root/Монтажка.app"
mkdir -p "$app_staging/Contents/MacOS" "$app_staging/Contents/Resources"
cp "$binary" "$app_staging/Contents/MacOS/Montazhka"
cp Resources/Info.plist "$app_staging/Contents/Info.plist"

if [ -n "${MONTAZHKA_VERSION:-}" ]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $MONTAZHKA_VERSION" "$app_staging/Contents/Info.plist"
fi
if [ -n "${MONTAZHKA_BUILD_NUMBER:-}" ]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $MONTAZHKA_BUILD_NUMBER" "$app_staging/Contents/Info.plist"
fi

if [ -d Resources/App ]; then
  ditto Resources/App "$app_staging/Contents/Resources"
fi

if [ "$adhoc" = true ]; then
  scripts/sign-app.sh "$app_staging" --adhoc
else
  scripts/sign-app.sh "$app_staging"
fi

app_output="build.noindex/Монтажка.app"
mkdir -p build.noindex
rm -rf -- "$app_output"
ditto "$app_staging" "$app_output"

if [ "$universal" = true ]; then
  architectures="$(lipo -archs "$app_output/Contents/MacOS/Montazhka")"
  if [ "$architectures" != "x86_64 arm64" ] && [ "$architectures" != "arm64 x86_64" ]; then
    echo "✗ Universal-бинарник содержит неожиданные архитектуры: $architectures" >&2
    exit 1
  fi
fi

echo "✓ Готово: $app_output"

if [ "$install_app" = true ]; then
  destination="/Applications/Монтажка.app"
  rm -rf -- "$destination"
  ditto "$app_output" "$destination"
  echo "✓ Установлено: $destination"
fi
