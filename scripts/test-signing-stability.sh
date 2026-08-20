#!/bin/bash

set -euo pipefail
cd "$(dirname "$0")/.."

identity="${MONTAZHKA_SIGNING_IDENTITY:-${DEVELOPER_ID_APPLICATION:-}}"
if [ -z "$identity" ]; then
  echo "ℹ Developer ID Application недоступен; проверяю Hardened Runtime на ad-hoc сборке."
  scripts/build-app.sh --adhoc
else
  scripts/build-app.sh
fi

app_path="build.noindex/Монтажка.app"
codesign --verify --deep --strict --verbose=2 "$app_path"

flags="$(codesign -dv --verbose=4 "$app_path" 2>&1 | sed -n 's/^CodeDirectory.*flags=\([^ ]*\).*/\1/p')"
if [ "$flags" = "0x0" ] || [ -z "$flags" ]; then
  echo "✗ В подписи не обнаружен Hardened Runtime" >&2
  exit 1
fi

echo "✓ Подпись валидна, Hardened Runtime включён"
