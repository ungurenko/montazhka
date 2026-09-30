#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/swift-env.sh

# Builds and exports are explicit separate phases; the default only compiles.
resolution_mode="--compile-only"
if [ "$#" -gt 0 ]; then resolution_mode="$1"; fi
case "$resolution_mode" in
  --compile-only|--matrix-only|--pairs-only|--all) ;;
  *)
    echo "Use --compile-only, --matrix-only, --pairs-only or --all." >&2
    exit 1
    ;;
esac
resolution_products="$PWD/.build/out/Products/Release"
resolution_fixture="$PWD/Tests/MontazhkaTests/ExportRenderResolutionTests.swift"
resolution_source="$PWD/scripts/benchmark-export-resolution.swift"
resolution_binary="$PWD/.build/performance-review/export-resolution-driver"
resolution_root="$PWD/.build/performance-review/export-resolution"
if [ ! -f "$resolution_fixture" ] || [ ! -f "$resolution_products/libMontazhkaKit.a" ]; then
  echo "Install the prepared fixture tests and build the release test target first." >&2
  exit 1
fi
for resolution_engine_source in \
  Sources/Montazhka/Engine/ProjectVideoComposition.swift \
  Sources/Montazhka/Engine/ProjectVideoComposition+Preparation.swift \
  Sources/Montazhka/Engine/MediaPipeline.swift; do
  if [ "$resolution_engine_source" -nt "$resolution_products/libMontazhkaKit.a" ]; then
    echo "Release products are older than $resolution_engine_source." >&2
    exit 1
  fi
done
mkdir -p "$resolution_root"
if [ ! -f "$resolution_binary" ] \
  || [ "$resolution_fixture" -nt "$resolution_binary" ] \
  || [ "$resolution_source" -nt "$resolution_binary" ] \
  || [ "$resolution_products/libMontazhkaKit.a" -nt "$resolution_binary" ]; then
  swiftc -swift-version 6 -O -parse-as-library -D EXPORT_RESOLUTION_BENCHMARK \
    -target "$(uname -m)-apple-macosx14.0" \
    -I "$resolution_products" -L "$resolution_products" -lMontazhkaKit \
    -I .build/checkouts/FluidAudio/Sources/FastClusterWrapper/include \
    -I .build/checkouts/FluidAudio/Sources/MachTaskSelfWrapper/include \
    "$resolution_fixture" "$resolution_source" -o "$resolution_binary"
fi
if [ "$resolution_mode" = "--compile-only" ]; then
  exit 0
fi

# An interrupted rerun must not leave a previous acceptance result in place.
: > "$resolution_root/gate.json"

# Preparation is outside each fresh measurement process.
"$resolution_binary" --phase prepare --root "$resolution_root" > "$resolution_root/fixtures.json"
if [ "$resolution_mode" = "--matrix-only" ] || [ "$resolution_mode" = "--all" ]; then
  : > "$resolution_root/matrix.jsonl"
  for resolution_scene in plain rotated mixed animation subtitles freeze; do
    for resolution_colour in sdr hlg; do
      for resolution_quality in medium compact; do
        resolution_case="$resolution_scene-$resolution_colour-$resolution_quality"
        "$resolution_binary" --phase matrix --case "$resolution_case" --root "$resolution_root" \
          | tee -a "$resolution_root/matrix.jsonl"
      done
    done
  done
fi
if [ "$resolution_mode" = "--pairs-only" ] || [ "$resolution_mode" = "--all" ]; then
  : > "$resolution_root/pairs.jsonl"
  for resolution_quality in medium compact; do
    resolution_case="freeze-sdr-$resolution_quality"
    for resolution_pair in 1 2 3 4 5; do
      if [ $((resolution_pair % 2)) -eq 1 ]; then
        resolution_order="native target"
      else
        resolution_order="target native"
      fi
      for resolution_engine in $resolution_order; do
        "$resolution_binary" --phase sample --case "$resolution_case" --engine "$resolution_engine" \
          --pair "$resolution_pair" --root "$resolution_root" | tee -a "$resolution_root/pairs.jsonl"
      done
    done
  done
fi
if [ -s "$resolution_root/matrix.jsonl" ] && [ -s "$resolution_root/pairs.jsonl" ]; then
  "$resolution_binary" --phase summary --root "$resolution_root" | tee "$resolution_root/gate.json"
fi
