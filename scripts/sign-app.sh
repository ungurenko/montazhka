#!/bin/bash

set -euo pipefail

if [ "$#" -ne 1 ] || [ ! -d "$1" ]; then
  echo "Использование: scripts/sign-app.sh /путь/к/приложению.app" >&2
  exit 2
fi

APP_PATH="$1"
SIGNING_DIR="${MONTAZHKA_SIGNING_DIR:-${HOME}/Library/Application Support/ru.ungurenko.montazhka/Signing}"
KEYCHAIN_PATH="$SIGNING_DIR/MontazhkaSigning.keychain-db"
PASSWORD_PATH="$SIGNING_DIR/keychain-password"
IDENTITY_NAME="Montazhka Local Code Signing"
temporary_dir=""
keychain_search_changed=false
original_keychains=()

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

create_signing_identity() {
  local p12_password keychain_password
  mkdir -p "$SIGNING_DIR"
  chmod 700 "$SIGNING_DIR"
  umask 077

  openssl rand -hex 32 > "$PASSWORD_PATH"
  keychain_password="$(<"$PASSWORD_PATH")"
  security create-keychain -p "$keychain_password" "$KEYCHAIN_PATH"
  security set-keychain-settings -lut 21600 "$KEYCHAIN_PATH"
  security unlock-keychain -p "$keychain_password" "$KEYCHAIN_PATH"

  temporary_dir="$(mktemp -d)"
  p12_password="$(openssl rand -hex 32)"

  openssl req -x509 -newkey rsa:2048 -sha256 -days 36500 -nodes \
    -keyout "$temporary_dir/signing-key.pem" \
    -out "$temporary_dir/signing-certificate.pem" \
    -subj "/CN=$IDENTITY_NAME/O=Montazhka Local" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" >/dev/null 2>&1
  openssl pkcs12 -export \
    -legacy \
    -inkey "$temporary_dir/signing-key.pem" \
    -in "$temporary_dir/signing-certificate.pem" \
    -name "$IDENTITY_NAME" \
    -out "$temporary_dir/signing-identity.p12" \
    -passout "pass:$p12_password"
  security import "$temporary_dir/signing-identity.p12" \
    -k "$KEYCHAIN_PATH" -P "$p12_password" -T /usr/bin/codesign >/dev/null
  security set-key-partition-list \
    -S apple-tool:,apple:,codesign: -s -k "$keychain_password" "$KEYCHAIN_PATH" >/dev/null
  security add-trusted-cert -r trustRoot -p codeSign \
    -k "$KEYCHAIN_PATH" "$temporary_dir/signing-certificate.pem"
}

if [ ! -f "$KEYCHAIN_PATH" ]; then
  create_signing_identity
fi

if [ ! -f "$PASSWORD_PATH" ]; then
  echo "✗ Не найден пароль локальной подписи: $PASSWORD_PATH" >&2
  exit 1
fi

keychain_password="$(<"$PASSWORD_PATH")"
security unlock-keychain -p "$keychain_password" "$KEYCHAIN_PATH"

while IFS= read -r keychain; do
  keychain="${keychain#*\"}"
  keychain="${keychain%\"*}"
  original_keychains+=("$keychain")
done < <(security list-keychains -d user)
security list-keychains -d user -s "$KEYCHAIN_PATH" "${original_keychains[@]}"
keychain_search_changed=true

identity_hash="$(security find-certificate -a -Z -c "$IDENTITY_NAME" "$KEYCHAIN_PATH" \
  | awk '/SHA-1 hash:/{print $3; exit}')"
if [ -z "$identity_hash" ]; then
  echo "✗ Не найдена постоянная локальная подпись Монтажки" >&2
  exit 1
fi

codesign --force --sign "$identity_hash" --keychain "$KEYCHAIN_PATH" "$APP_PATH"
