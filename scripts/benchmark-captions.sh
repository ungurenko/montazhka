#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/swift-env.sh

# Compile the standalone harness only. Release test products must already exist;
# package builds are deliberately separate so measurements never overlap them.
caption_products="${CAPTION_BENCHMARK_PRODUCTS_DIR:-$PWD/.build/out/Products/Release}"
caption_modules="$PWD/.build/out/Products/Release"
caption_binary="${CAPTION_BENCHMARK_BINARY:-$PWD/.build/performance-review/captions-current}"
caption_runs=1
if [ "${1:-}" = "--compile-only" ]; then
  caption_runs=0
  shift
elif [ "${1:-}" = "--runs" ]; then
  caption_runs="$2"
  shift 2
fi
if [ ! -f "$caption_products/libMontazhkaKit.a" ]; then
  echo "Release test products are missing: $caption_products" >&2
  exit 1
fi
mkdir -p "$(dirname "$caption_binary")"
swiftc -O -parse-as-library -D CAPTION_BENCHMARK \
  -I "$caption_products" -I "$caption_modules" -L "$caption_products" -lMontazhkaKit \
  -I .build/checkouts/FluidAudio/Sources/FastClusterWrapper/include \
  -I .build/checkouts/FluidAudio/Sources/MachTaskSelfWrapper/include \
  Tests/MontazhkaTests/OverlayFrameRendererTests.swift scripts/benchmark-captions.swift \
  -o "$caption_binary"
for ((caption_run = 1; caption_run <= caption_runs; caption_run++)); do
  "$caption_binary" "$@"
done
