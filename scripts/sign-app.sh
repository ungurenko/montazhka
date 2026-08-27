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
keychain_args=()
signing_dir="${MONTAZHKA_SIGNING_DIR:-${HOME}/Library/Application Support/ru.ungurenko.montazhka/Signing}"
keychain_path="$signing_dir/MontazhkaSigning.keychain-db"
password_path="$signing_dir/keychain-password"
local_identity_name="Montazhka Local Code Signing"
temporary_dir=""
keychain_search_changed=false
original_keychains=()
uses_developer_id=false

cleanup() {
  if [ "$keychain_search_changed" = true ]; then
    security list-keychains -d user -s "${original_keychains[@]}"
  fi
  case "$temporary_dir" in
    /tmp/*|/private/tmp/*|/var/folders/*|/private/var/folders/*)
      rm -rf -- "$temporary_dir"
      ;;
  esac
}
trap cleanup EXIT

create_local_identity() {
  local keychain_password p12_password

  mkdir -p "$signing_dir"
  chmod 700 "$signing_dir"
  umask 077

  openssl rand -hex 32 > "$password_path"
  keychain_password="$(<"$password_path")"
  security create-keychain -p "$keychain_password" "$keychain_path"
  security set-keychain-settings -lut 21600 "$keychain_path"
  security unlock-keychain -p "$keychain_password" "$keychain_path"

  temporary_dir="$(mktemp -d)"
  p12_password="$(openssl rand -hex 32)"
  openssl req -x509 -newkey rsa:2048 -sha256 -days 36500 -nodes \
    -keyout "$temporary_dir/signing-key.pem" \
    -out "$temporary_dir/signing-certificate.pem" \
    -subj "/CN=$local_identity_name/O=Montazhka Local" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" >/dev/null 2>&1
  openssl pkcs12 -export -legacy \
    -inkey "$temporary_dir/signing-key.pem" \
    -in "$temporary_dir/signing-certificate.pem" \
    -name "$local_identity_name" \
    -out "$temporary_dir/signing-identity.p12" \
    -passout "pass:$p12_password"
  security import "$temporary_dir/signing-identity.p12" \
    -k "$keychain_path" -P "$p12_password" -T /usr/bin/codesign >/dev/null
  security set-key-partition-list \
    -S apple-tool:,apple:,codesign: -s -k "$keychain_password" "$keychain_path" >/dev/null
  security add-trusted-cert -r trustRoot -p codeSign \
    -k "$keychain_path" "$temporary_dir/signing-certificate.pem" >/dev/null
}

prepare_local_identity() {
  local keychain_password identity_hash keychain

  if [ ! -f "$keychain_path" ]; then
    create_local_identity
  fi
  if [ ! -f "$password_path" ]; then
    echo "✗ Не найден пароль постоянной локальной подписи: $password_path" >&2
    exit 1
  fi

  keychain_password="$(<"$password_path")"
  security unlock-keychain -p "$keychain_password" "$keychain_path"

  while IFS= read -r keychain; do
    keychain="${keychain#*\"}"
    keychain="${keychain%\"*}"
    original_keychains+=("$keychain")
  done < <(security list-keychains -d user)
  security list-keychains -d user -s "$keychain_path" "${original_keychains[@]}"
  keychain_search_changed=true

  identity_hash="$(security find-certificate -a -Z -c "$local_identity_name" "$keychain_path" \
    | awk '/SHA-1 hash:/{print $3; exit}')"
  if [ -z "$identity_hash" ]; then
    echo "✗ Не найдена постоянная локальная подпись Монтажки" >&2
    exit 1
  fi

  identity="$identity_hash"
  keychain_args=(--keychain "$keychain_path")
  timestamp=(--timestamp=none)
}

if [ "$mode" = "--adhoc" ]; then
  identity="-"
  timestamp=(--timestamp=none)
elif [ -n "$mode" ]; then
  usage
  exit 2
elif [ -n "$identity" ]; then
  uses_developer_id=true
else
  prepare_local_identity
fi

codesign \
  --force \
  --sign "$identity" \
  "${keychain_args[@]}" \
  --options runtime \
  "${timestamp[@]}" \
  "$app_path"

codesign --verify --deep --strict --verbose=2 "$app_path"

if [ "$uses_developer_id" = true ]; then
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
