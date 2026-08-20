#!/bin/bash

set -euo pipefail
cd "$(dirname "$0")/.."

xcodegen_version="2.45.4"
xcodegen_sha256="090ec29491aad50aec10631bf6e62253fed733c50f3aab0f5ffc86bc170bdbef"
swiftlint_version="0.65.0"
swiftlint_sha256="d6cb0aa7a2f5f1ef306fc9e37bcb54dc9a26facc8f7784ac0c3dd3eccf5c6ba6"

mkdir -p .tools
temporary_dir="$(mktemp -d "${TMPDIR:-/tmp}/montazhka-tools.XXXXXX")"
cleanup() {
  case "$temporary_dir" in
    /tmp/*|/private/tmp/*|/var/folders/*|/private/var/folders/*) rm -rf -- "$temporary_dir" ;;
  esac
}
trap cleanup EXIT

verify_archive() {
  local archive="$1"
  local expected="$2"
  local actual
  actual="$(shasum -a 256 "$archive" | awk '{print $1}')"
  if [ "$actual" != "$expected" ]; then
    echo "✗ Контрольная сумма не совпала: $archive" >&2
    echo "  ожидалось: $expected" >&2
    echo "  получено:  $actual" >&2
    exit 1
  fi
}

if [ ! -x .tools/xcodegen ] || ! .tools/xcodegen --version 2>/dev/null | grep -q "$xcodegen_version"; then
  echo "▸ Загружаю XcodeGen ${xcodegen_version}…"
  xcodegen_archive="$temporary_dir/xcodegen.zip"
  xcodegen_unpack="$temporary_dir/xcodegen"
  curl --fail --location --retry 3 \
    "https://github.com/yonaskolb/XcodeGen/releases/download/$xcodegen_version/xcodegen.zip" \
    --output "$xcodegen_archive"
  verify_archive "$xcodegen_archive" "$xcodegen_sha256"
  mkdir -p "$xcodegen_unpack"
  ditto -x -k "$xcodegen_archive" "$xcodegen_unpack"
  install -m 755 "$xcodegen_unpack/xcodegen/bin/xcodegen" .tools/xcodegen
fi

if [ ! -x .tools/swiftlint ] || ! .tools/swiftlint version 2>/dev/null | grep -q "$swiftlint_version"; then
  echo "▸ Загружаю SwiftLint ${swiftlint_version}…"
  swiftlint_archive="$temporary_dir/swiftlint.zip"
  swiftlint_unpack="$temporary_dir/swiftlint"
  curl --fail --location --retry 3 \
    "https://github.com/realm/SwiftLint/releases/download/$swiftlint_version/portable_swiftlint.zip" \
    --output "$swiftlint_archive"
  verify_archive "$swiftlint_archive" "$swiftlint_sha256"
  mkdir -p "$swiftlint_unpack"
  ditto -x -k "$swiftlint_archive" "$swiftlint_unpack"
  install -m 755 "$swiftlint_unpack/swiftlint" .tools/swiftlint
fi

echo "✓ XcodeGen $xcodegen_version и SwiftLint $swiftlint_version готовы в .tools"
