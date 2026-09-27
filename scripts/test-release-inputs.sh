#!/bin/bash
# Безопасная проверка защиты ручного релиза: без секретов и без публикации.
# 1) Проверка версии и номера сборки принимает верные значения и отвергает
#    значения с кавычками и синтаксисом оболочки как данные, не исполняя их.
# 2) release.yml не подставляет параметры запуска прямо в текст команд.

set -euo pipefail
cd "$(dirname "$0")/.."

failures=0
marker="$(mktemp -d)/pwned"

expect() {
  local want="$1" version="$2" build="$3" code=0
  RELEASE_VERSION="$version" RELEASE_BUILD_NUMBER="$build" ./scripts/validate-release-inputs.sh >/dev/null 2>&1 || code=$?
  if [ "$code" != "$want" ]; then
    echo "✗ версия [$version], сборка [$build]: код $code, ожидался $want" >&2
    failures=$((failures + 1))
  fi
}

expect 0 "1.2.3" "42"
expect 0 "10.0.12" "1"
expect 2 "1.2" "42"
expect 2 "1.2.3" "0"
expect 2 "1.2.3" "042"
expect 2 "" "1"
expect 2 "1.2.3'; touch '$marker'; echo '" "1"
expect 2 "\$(touch $marker)" "1"
expect 2 "1.2.3" "1\`touch $marker\`"
expect 2 "1.2.3\"; touch \"$marker" "1"
expect 2 $'1.2.3\ntouch '"$marker" "1"

if [ -e "$marker" ]; then
  echo "✗ значение исполнилось как команда" >&2
  failures=$((failures + 1))
fi

# Параметры запуска доходят до оболочки только переменными окружения.
if awk '/^[[:space:]]*run:/ { inrun = 1; indent = match($0, /[^ ]/) }
        inrun && /\$\{\{[[:space:]]*(inputs|github\.event\.inputs)\./ { found = 1 }
        /^[[:space:]]*-[[:space:]]/ && match($0, /[^ ]/) <= indent { inrun = 0 }
        END { exit found ? 0 : 1 }' .github/workflows/release.yml; then
  echo "✗ release.yml подставляет inputs прямо в текст команды" >&2
  failures=$((failures + 1))
fi

if [ "$failures" -gt 0 ]; then
  echo "✗ Проверка параметров релиза: провалов $failures" >&2
  exit 1
fi
echo "✓ Параметры релиза проверяются как данные"
