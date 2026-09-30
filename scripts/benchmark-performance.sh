#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/swift-env.sh

# Run after a release test build. Override products to compare a frozen archive.
performance_case="${1:?Choose timeline, inspection or preview}"
shift
performance_products="${PERFORMANCE_PRODUCTS_DIR:-$PWD/.build/out/Products/Release}"
performance_binary="${PERFORMANCE_BINARY:-$PWD/.build/performance-review/$performance_case-current}"
performance_sources=("scripts/benchmark-$performance_case.swift")
case "$performance_case" in
  timeline) performance_sources+=(Tests/MontazhkaTests/TimelineWaveformFixture.swift) ;;
  inspection|preview) ;;
  *) echo "Unknown benchmark: $performance_case" >&2; exit 1 ;;
esac
if [ ! -f "$performance_products/libMontazhkaKit.a" ]; then
  echo "Run release tests first; missing $performance_products/libMontazhkaKit.a" >&2
  exit 1
fi
mkdir -p "$(dirname "$performance_binary")"
swiftc -swift-version 6 -O -parse-as-library -target arm64-apple-macosx14.0 \
  -I "$performance_products" -L "$performance_products" -lMontazhkaKit \
  -I "$PWD/.build/out/Products/Release" \
  -I .build/checkouts/FluidAudio/Sources/FastClusterWrapper/include \
  -I .build/checkouts/FluidAudio/Sources/MachTaskSelfWrapper/include \
  "${performance_sources[@]}" -o "$performance_binary"
if [ "${1:-}" = "--compile-only" ]; then exit 0; fi
"$performance_binary" "$@"
