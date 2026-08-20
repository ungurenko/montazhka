#!/bin/bash

set -euo pipefail
cd "$(dirname "$0")/.."

version="${1:-}"
build_number="${2:-}"

if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || [[ ! "$build_number" =~ ^[1-9][0-9]*$ ]]; then
  echo "Использование: scripts/release.sh <версия X.Y.Z> <номер сборки>" >&2
  exit 2
fi
if [ -z "${MONTAZHKA_SIGNING_IDENTITY:-${DEVELOPER_ID_APPLICATION:-}}" ]; then
  echo "✗ Для релиза нужен MONTAZHKA_SIGNING_IDENTITY или DEVELOPER_ID_APPLICATION." >&2
  exit 1
fi

./scripts/lint.sh
./scripts/test.sh

MONTAZHKA_VERSION="$version" MONTAZHKA_BUILD_NUMBER="$build_number" \
  ./scripts/build-app.sh --universal
MONTAZHKA_SELFTEST_TIMEOUT=120 "build.noindex/Монтажка.app/Contents/MacOS/Montazhka" --selftest
./scripts/notarize.sh "build.noindex/Монтажка.app"

release_dir="build.noindex/release"
mkdir -p "$release_dir"
archive="$release_dir/Монтажка-$version-universal.zip"
rm -f -- "$archive" "$archive.sha256"
ditto -c -k --keepParent "build.noindex/Монтажка.app" "$archive"
shasum -a 256 "$archive" > "$archive.sha256"

echo "✓ Релизные артефакты готовы в $release_dir"
echo "ℹ Скрипт ничего не публикует: загрузка в GitHub Releases выполняется отдельным явным действием."
