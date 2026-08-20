#!/bin/bash

set -euo pipefail
cd "$(dirname "$0")/.."

info_plist="Resources/Info.plist"

assert_plist_value() {
  local key="$1"
  local expected="$2"
  local actual
  actual="$(/usr/libexec/PlistBuddy -c "Print :$key" "$info_plist")"
  if [ "$actual" != "$expected" ]; then
    echo "✗ $key в $info_plist: ожидалось '$expected', получено '$actual'" >&2
    exit 1
  fi
}

plutil -lint "$info_plist" >/dev/null
plutil -lint Resources/App/ru.lproj/Localizable.strings >/dev/null

if grep -Fq '$(' "$info_plist"; then
  echo "✗ $info_plist содержит нераскрытые Xcode placeholders" >&2
  exit 1
fi

assert_plist_value CFBundleExecutable Montazhka
assert_plist_value CFBundleIdentifier ru.ungurenko.montazhka
assert_plist_value CFBundlePackageType APPL
assert_plist_value LSMinimumSystemVersion 14.0

echo "✓ Info.plist и Localizable.strings корректны"
