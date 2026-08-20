#!/bin/bash

set -euo pipefail

usage() {
  echo "Использование: scripts/sign-app.sh /путь/к/приложению.app [--adhoc]" >&2
}

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ] || [ ! -d "$1" ]; then
  usage
  exit 2
fi

app_path="$1"
mode="${2:-}"
identity="${MONTAZHKA_SIGNING_IDENTITY:-${DEVELOPER_ID_APPLICATION:-}}"
timestamp=(--timestamp)

if [ "$mode" = "--adhoc" ]; then
  identity="-"
  timestamp=(--timestamp=none)
elif [ -n "$mode" ]; then
  usage
  exit 2
elif [ -z "$identity" ]; then
  echo "✗ Укажи MONTAZHKA_SIGNING_IDENTITY с сертификатом Developer ID Application." >&2
  echo "  Для локальной проверки явно добавь --adhoc." >&2
  exit 1
fi

codesign \
  --force \
  --sign "$identity" \
  --options runtime \
  "${timestamp[@]}" \
  "$app_path"

codesign --verify --deep --strict --verbose=2 "$app_path"

if [ "$identity" != "-" ]; then
  signing_details="$(codesign -dv --verbose=4 "$app_path" 2>&1)"
  authority="$(printf '%s\n' "$signing_details" | awk -F= '/^Authority=/ && !found {print substr($0, 11); found=1}')"
  case "$authority" in
    "Developer ID Application:"*) ;;
    *)
      echo "✗ Приложение подписано не сертификатом Developer ID Application: $authority" >&2
      exit 1
      ;;
  esac
fi
