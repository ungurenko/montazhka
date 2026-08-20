#!/bin/bash

set -euo pipefail
cd "$(dirname "$0")/.."

developer_dir="$(xcode-select -p)"

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

swift test \
  -Xswiftc -F -Xswiftc "$frameworks_dir" \
  -Xlinker -F -Xlinker "$frameworks_dir" \
  -Xlinker -rpath -Xlinker "$frameworks_dir" \
  -Xlinker -rpath -Xlinker "$testing_lib_dir"
