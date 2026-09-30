#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/swift-env.sh

# Reuse a release test build with @testable enabled; do not rebuild the package here.
# Run ShortsWindowSchedulingTests before this benchmark.
products_dir="${1:-$PWD/.build/out/Products/Release}"
if [ ! -f "$products_dir/libMontazhkaKit.a" ]; then
  echo "Release test products are missing: $products_dir/libMontazhkaKit.a" >&2
  exit 1
fi
if [ Sources/Montazhka/Engine/ShortsCutService.swift -nt "$products_dir/libMontazhkaKit.a" ]; then
  echo "Release products are older than ShortsCutService.swift; rebuild the release test target." >&2
  exit 1
fi
benchmark_dir="$PWD/.build/performance-review"
mkdir -p "$benchmark_dir"
swiftc -swift-version 6 -O -parse-as-library \
  -target "$(uname -m)-apple-macosx14.0" \
  -I "$products_dir" -L "$products_dir" -lMontazhkaKit \
  -I .build/checkouts/FluidAudio/Sources/FastClusterWrapper/include \
  -I .build/checkouts/FluidAudio/Sources/MachTaskSelfWrapper/include \
  scripts/benchmark-short-windows.swift -o "$benchmark_dir/short-windows"
"$benchmark_dir/short-windows" | tee "$benchmark_dir/short-windows-pairs.jsonl"
