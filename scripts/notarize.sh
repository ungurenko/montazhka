#!/bin/bash

set -euo pipefail
cd "$(dirname "$0")/.."

app_path="${1:-build.noindex/Монтажка.app}"
profile="${NOTARY_KEYCHAIN_PROFILE:-}"
keychain_path="${NOTARY_KEYCHAIN_PATH:-}"

if [ ! -d "$app_path" ]; then
  echo "✗ Приложение не найдено: $app_path" >&2
  exit 1
fi
if [ -z "$profile" ]; then
  echo "✗ Укажи NOTARY_KEYCHAIN_PROFILE, созданный через xcrun notarytool store-credentials." >&2
  exit 1
fi

archive="$(mktemp "${TMPDIR:-/tmp}/montazhka-notary.XXXXXX.zip")"
cleanup() {
  case "$archive" in
    /tmp/*|/private/tmp/*|/var/folders/*|/private/var/folders/*) rm -f -- "$archive" ;;
  esac
}
trap cleanup EXIT

ditto -c -k --keepParent "$app_path" "$archive"
notary_credentials=(--keychain-profile "$profile")
if [ -n "$keychain_path" ]; then
  notary_credentials+=(--keychain "$keychain_path")
fi
xcrun notarytool submit "$archive" "${notary_credentials[@]}" --wait
xcrun stapler staple "$app_path"
xcrun stapler validate "$app_path"
spctl --assess --type execute --verbose=2 "$app_path"

echo "✓ Нотаризация и Gatekeeper-проверка завершены"
