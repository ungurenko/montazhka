#!/bin/bash

set -euo pipefail
cd "$(dirname "$0")/.."

scripts/build-app.sh

app_path="build.noindex/Монтажка.app"
codesign --verify --deep --strict --verbose=2 "$app_path"

flags="$(codesign -dv --verbose=4 "$app_path" 2>&1 | sed -n 's/^CodeDirectory.*flags=\([^ ]*\).*/\1/p')"
if [ "$flags" = "0x0" ] || [ -z "$flags" ]; then
  echo "✗ В подписи не обнаружен Hardened Runtime" >&2
  exit 1
fi

test_root="$(mktemp -d "${TMPDIR:-/tmp}/montazhka-signing-test.XXXXXX")"
cleanup() {
  case "$test_root" in
    /tmp/*|/private/tmp/*|/var/folders/*|/private/var/folders/*) rm -rf -- "$test_root" ;;
  esac
}
trap cleanup EXIT

first_app="$test_root/first.app"
second_app="$test_root/second.app"
ditto "$app_path" "$first_app"
ditto "$app_path" "$second_app"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion 9999" "$second_app/Contents/Info.plist"
scripts/sign-app.sh "$second_app"

first_requirement="$(codesign -d -r- "$first_app" 2>&1 | sed -n '/^designated => /p')"
second_requirement="$(codesign -d -r- "$second_app" 2>&1 | sed -n '/^designated => /p')"
if [ "$first_requirement" != "$second_requirement" ]; then
  echo "✗ Подпись приложения меняется после пересборки" >&2
  exit 1
fi
if [[ "$first_requirement" != *"certificate"* ]]; then
  echo "✗ Сборка всё ещё использует временную подпись" >&2
  exit 1
fi

echo "✓ Подпись стабильна между пересборками, Hardened Runtime включён"
