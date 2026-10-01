#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/swift-env.sh

# Build release test products separately before timing this standalone harness.
shorts_products="${SHORTS_BENCHMARK_PRODUCTS_DIR:-$PWD/.build/out/Products/Release}"
shorts_binary="$PWD/.build/performance-review/shorts-subtitles"
if [ ! -f "$shorts_products/libMontazhkaKit.a" ]; then
  echo "Release test products are missing: $shorts_products" >&2
  exit 1
fi
mkdir -p "$(dirname "$shorts_binary")"
swiftc -O -parse-as-library \
  -I "$shorts_products" -L "$shorts_products" -lMontazhkaKit \
  -I .build/checkouts/FluidAudio/Sources/FastClusterWrapper/include \
  -I .build/checkouts/FluidAudio/Sources/MachTaskSelfWrapper/include \
  scripts/benchmark-shorts-subtitles.swift -o "$shorts_binary"
"$shorts_binary"
