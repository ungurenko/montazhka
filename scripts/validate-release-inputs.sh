#!/bin/bash
# Версия и номер сборки ручного релиза приходят переменными окружения и проверяются
# как данные — до импорта сертификата и ключей нотаризации.

set -euo pipefail

version="${RELEASE_VERSION:-}"
build_number="${RELEASE_BUILD_NUMBER:-}"

if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "✗ Версия должна быть вида X.Y.Z, например 1.1.0" >&2
  exit 2
fi
if [[ ! "$build_number" =~ ^[1-9][0-9]*$ ]]; then
  echo "✗ Номер сборки — целое число больше нуля без ведущих нулей" >&2
  exit 2
fi
echo "✓ Релиз $version, сборка $build_number"
