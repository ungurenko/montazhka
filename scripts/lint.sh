#!/bin/bash

set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/verify-config.sh
./scripts/check-error-texts.sh
.tools/actionlint .github/workflows/*.yml
swift format lint --strict --recursive Sources Tests Package.swift

swiftlint_bin=""
if [ -x ".tools/swiftlint" ]; then
  swiftlint_bin=".tools/swiftlint"
elif command -v swiftlint >/dev/null 2>&1; then
  swiftlint_bin="$(command -v swiftlint)"
fi

if [ -n "$swiftlint_bin" ]; then
  developer_dir="$(xcode-select -p)"
  if [ -d "$developer_dir/Platforms/MacOSX.platform" ]; then
    "$swiftlint_bin" lint --strict
  else
    DYLD_FRAMEWORK_PATH="$developer_dir/usr/lib" "$swiftlint_bin" lint --strict
  fi
else
  echo "ℹ SwiftLint не установлен локально; CI использует закреплённую версию 0.65.0."
fi
