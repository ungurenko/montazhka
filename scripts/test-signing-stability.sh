#!/bin/bash

set -euo pipefail
cd "$(dirname "$0")/.."

scripts/build-app.sh >/dev/null

TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT

FIRST_APP="$TEST_DIR/first.app"
SECOND_APP="$TEST_DIR/second.app"
cp -R "build.noindex/Монтажка.app" "$FIRST_APP"
cp -R "$FIRST_APP" "$SECOND_APP"

/usr/libexec/PlistBuddy -c "Set :CFBundleVersion 2" "$SECOND_APP/Contents/Info.plist"
scripts/sign-app.sh "$SECOND_APP"

first_requirement="$(codesign -d -r- "$FIRST_APP" 2>&1 | sed -n '/designated =>/p')"
second_requirement="$(codesign -d -r- "$SECOND_APP" 2>&1 | sed -n '/designated =>/p')"

if [ "$first_requirement" != "$second_requirement" ]; then
  echo "✗ Подпись приложения меняется после пересборки"
  echo "Первая: $first_requirement"
  echo "Вторая: $second_requirement"
  exit 1
fi

if [[ "$first_requirement" != *"certificate root"* ]]; then
  echo "✗ Подпись остаётся временной и привязана к содержимому приложения"
  echo "$first_requirement"
  exit 1
fi

echo "✓ Подпись приложения стабильна между обновлениями"
