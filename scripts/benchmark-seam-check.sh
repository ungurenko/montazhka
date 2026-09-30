#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/swift-env.sh

# Swift test включает доступ к internal API для эталона и счётчика читателей.
./scripts/test.sh -c release --disable-automatic-resolution --no-parallel \
  --filter SeamFrameReadingTests/noVideoKeepsItsError >&2
bin_dir="$(swift build -c release --show-bin-path)"
benchmark_dir="$PWD/.build/seam-check-benchmark"
mkdir -p "$benchmark_dir"
swiftc -O -parse-as-library \
  -I "$bin_dir" -L "$bin_dir" -lMontazhkaKit \
  -I .build/checkouts/FluidAudio/Sources/FastClusterWrapper/include \
  -I .build/checkouts/FluidAudio/Sources/MachTaskSelfWrapper/include \
  Tests/MontazhkaTests/SeamFrameFixture.swift scripts/benchmark-seam-check.swift \
  -o "$benchmark_dir/current"
"$benchmark_dir/current" "$benchmark_dir/fixture" "$@"
