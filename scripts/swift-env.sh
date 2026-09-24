#!/bin/bash
# Подключается через `source` из build-app.sh и test.sh.
#
# В Command Line Tools 27 SwiftUI из SDK 27 объявляет `@State` макросом
# (SwiftUIMacros.StateMacro), а плагина с этим макросом в CLT нет — сборка
# падает. Если так, выбираем самый новый SDK из CLT, где `@State` ещё обычная
# обёртка. С полным Xcode или с исправленными CLT ничего не меняется.

developer_dir="$(xcode-select -p)"

sdk_needs_swiftui_macros() {
  grep -qs 'type: "StateMacro"' \
    "$1/System/Library/Frameworks/SwiftUICore.framework/Versions/A/Modules/SwiftUICore.swiftmodule/arm64e-apple-macos.swiftinterface"
}

if [ -z "${SDKROOT:-}" ] \
  && [ ! -d "$developer_dir/Platforms/MacOSX.platform" ] \
  && [ ! -e "$developer_dir/usr/lib/swift/host/plugins/libSwiftUIMacros.dylib" ] \
  && sdk_needs_swiftui_macros "$(xcrun --show-sdk-path)"; then
  fallback_sdk=""
  for candidate in $(ls -d "$developer_dir"/SDKs/MacOSX[0-9]*.sdk 2>/dev/null | sort -V -r); do
    if ! sdk_needs_swiftui_macros "$candidate"; then
      fallback_sdk="$candidate"
      break
    fi
  done
  if [ -z "$fallback_sdk" ]; then
    echo "✗ В Command Line Tools нет SDK, совместимого со SwiftUI без Xcode. Установите Xcode." >&2
    exit 1
  fi
  export SDKROOT="$fallback_sdk"
  echo "ℹ CLT без плагина SwiftUIMacros — собираю с $(basename "$SDKROOT")"
fi
