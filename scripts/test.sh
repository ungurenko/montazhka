#!/bin/bash

set -euo pipefail
cd "$(dirname "$0")/.."

source scripts/swift-env.sh

if [ -d "$developer_dir/Platforms/MacOSX.platform" ]; then
  swift test
  exit 0
fi

frameworks_dir="$developer_dir/Library/Developer/Frameworks"
testing_lib_dir="$developer_dir/Library/Developer/usr/lib"

if [ ! -d "$frameworks_dir/Testing.framework" ]; then
  echo "✗ Swift Testing не найден в $frameworks_dir" >&2
  exit 1
fi

# Плагин макросов Swift Testing в CLT лежит в подпапке, которую компилятор сам не просматривает.
plugin_args=()
testing_plugins_dir="$developer_dir/usr/lib/swift/host/plugins/testing"
if [ -e "$testing_plugins_dir/libTestingMacros.dylib" ]; then
  plugin_args=(-Xswiftc -plugin-path -Xswiftc "$testing_plugins_dir")
fi

swift test \
  ${plugin_args[@]+"${plugin_args[@]}"} \
  -Xswiftc -F -Xswiftc "$frameworks_dir" \
  -Xlinker -F -Xlinker "$frameworks_dir" \
  -Xlinker -rpath -Xlinker "$frameworks_dir" \
  -Xlinker -rpath -Xlinker "$testing_lib_dir"
