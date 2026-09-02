#!/bin/bash
# Сторож: системный текст ошибки (английский) не должен попадать в интерфейс.
# Единственный разрешённый путь наружу — UserFacingError.make, который
# одновременно пишет оригинал в лог.

set -euo pipefail
cd "$(dirname "$0")/.."

leaks="$(
  grep -rn "localizedDescription" Sources/Montazhka --include="*.swift" \
    | grep -v "Logger\." \
    | grep -v "privacy: .public" \
    | grep -v "Sources/Montazhka/Agent/" \
    | grep -v "Sources/Montazhka/SelfTest/" \
    | grep -v "Sources/Montazhka/Support/UserFacingError.swift" \
    || true
)"

if [ -n "$leaks" ]; then
  echo "✗ Системный текст ошибки утекает в интерфейс — заверни его в UserFacingError.make:" >&2
  echo "$leaks" >&2
  exit 1
fi

echo "✓ Тексты ошибок: системных сообщений в интерфейсе нет"
