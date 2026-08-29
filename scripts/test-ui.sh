#!/bin/bash

set -euo pipefail
cd "$(dirname "$0")/.."

temporary_dir="$(mktemp -d "${TMPDIR:-/tmp}/montazhka-ui-tests.XXXXXX")"
cleanup() {
  case "$temporary_dir" in
    /tmp/*|/private/tmp/*|/var/folders/*|/private/var/folders/*) rm -rf -- "$temporary_dir" ;;
  esac
}
trap cleanup EXIT

run_attempt() {
  local attempt="$1"
  local log_path="$temporary_dir/attempt-${attempt}.log"

  xcodebuild \
    -project Montazhka.xcodeproj \
    -scheme Montazhka \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "build.noindex/xcode-ui-${attempt}" \
    ONLY_ACTIVE_ARCH=YES \
    -skipPackagePluginValidation \
    test 2>&1 | tee "$log_path"
}

if run_attempt 1; then
  exit 0
fi

first_log="$temporary_dir/attempt-1.log"
if ! grep -Eiq 'bundle identifier.*couldn.t be read|module name ""' "$first_log"; then
  exit 1
fi

echo "▸ Xcode потерял путь к тестовой сборке; повторяю на чистом каталоге…"
run_attempt 2
