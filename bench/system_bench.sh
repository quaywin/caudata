#!/usr/bin/env bash
# System Macro-Benchmark Script for Caudata
#
# Measures idle RSS memory + CPU of the PRODUCTION Burrito binary.
#
# The Burrito binary is the real user-facing artifact: rel/vm.args.eex bakes in
# the +S 2:2 scheduler tuning, +sbwt none, and the exclude_apps list, none of
# which apply to `mix run` (dev mode). Measuring `mix run` therefore overstates
# RAM (~98 MB here) and cannot reproduce the release footprint.
#
# Usage:
#   bash bench/system_bench.sh            # measure the existing burrito_out binary
#   bash bench/system_bench.sh --build    # rebuild via `mix release` first (slow)
#
# Note: throughput (lines/s) is measured separately by bench/throughput_bench.exs.
# This script measures the idle footprint only — the TUI does not ingest from
# stdin, so sustained-load testing is not possible from outside the process.

set -eo pipefail

OUTPUT_FILE="bench/system_bench_results.txt"
WARMUP_SEC=8          # let Burrito unpack ERTS (first run) and let RSS settle
SAMPLES=10
SAMPLE_INTERVAL=2     # seconds between samples

OS="$(uname -s)"
ARCH="$(uname -m)"

# Map host -> native Burrito binary + build target
case "${OS}-${ARCH}" in
  Darwin-arm64)
    BINARY="burrito_out/caudata_macos_aarch64"
    NATIVE_TARGET="macos_aarch64"
    ;;
  Linux-x86_64)
    BINARY="burrito_out/caudata_linux_x86_64"
    NATIVE_TARGET="linux_x86_64"
    ;;
  *)
    echo "Unsupported platform: ${OS}-${ARCH}." >&2
    echo "Build a binary first: BURRITO_TARGET=<macos_aarch64|linux_x86_64> mix release" >&2
    exit 1
    ;;
esac

# Optional rebuild from current source
if [[ "${1:-}" == "--build" ]]; then
  echo "[build] Building native Burrito release (BURRITO_TARGET=${NATIVE_TARGET})..."
  BURRITO_TARGET="${NATIVE_TARGET}" mix release
fi

if [[ ! -x "$BINARY" ]]; then
  echo "Binary not found: $BINARY" >&2
  echo "Build it first: BURRITO_TARGET=${NATIVE_TARGET} mix release  (or re-run with --build)" >&2
  exit 1
fi

BIN_SIZE="$(du -h "$BINARY" | cut -f1)"
LAUNCH_LOG="$(mktemp -t caudata_bench)"
trap 'rm -f "$LAUNCH_LOG"' EXIT

{
  echo "=== Caudata System Macro-Benchmark (Burrito binary) ==="
  echo "Date: $(date)"
  echo "OS: $(uname -sr)"
  echo "Binary: $BINARY ($BIN_SIZE)"
  echo "Tuning: +S 2:2, +sbwt none, +sbwtdcpu none (from rel/vm.args.eex)"
  echo "----------------------------------------------"
} > "$OUTPUT_FILE"

echo "[1/2] Launching $BINARY (headless), warmup ${WARMUP_SEC}s..." | tee -a "$OUTPUT_FILE"
"$BINARY" </dev/null >"$LAUNCH_LOG" 2>&1 &
APP_PID=$!

# Always clean up the launched process on exit
cleanup() {
  kill "$APP_PID" 2>/dev/null || true
  wait "$APP_PID" 2>/dev/null || true
}
trap 'cleanup; rm -f "$LAUNCH_LOG"' EXIT

sleep "$WARMUP_SEC"

if ! ps -p "$APP_PID" >/dev/null 2>&1; then
  echo "Application exited during warmup. Launch log:" | tee -a "$OUTPUT_FILE"
  tail -20 "$LAUNCH_LOG" | tee -a "$OUTPUT_FILE" >&2
  exit 1
fi

echo "[2/2] Sampling RSS & CPU (${SAMPLES}x ${SAMPLE_INTERVAL}s)..." | tee -a "$OUTPUT_FILE"

SAMPLES_KB=()
for i in $(seq 1 "$SAMPLES"); do
  RSS_KB="$(ps -o rss= -p "$APP_PID" 2>/dev/null | tr -d ' ')"
  CPU="$(ps -o %cpu= -p "$APP_PID" 2>/dev/null | tr -d ' ')"
  RSS_MB="$(awk "BEGIN {print (${RSS_KB:-0}) / 1024}")"
  echo "  Sample ${i}: RSS = ${RSS_MB} MB, CPU = ${CPU:-0}%" >> "$OUTPUT_FILE"
  SAMPLES_KB+=("${RSS_KB:-0}")
  sleep "$SAMPLE_INTERVAL"
done

# min / avg / max via awk
read -r AVG_MB MIN_MB MAX_MB <<< "$(printf '%s\n' "${SAMPLES_KB[@]}" | awk '
  { v[NR]=$1; sum+=$1; if (NR==1 || $1<min) min=$1; if ($1>max) max=$1 }
  END { printf "%.2f %.2f %.2f", sum/NR/1024, min/1024, max/1024 }')"

{
  echo "----------------------------------------------"
  echo "=> Average RSS: ${AVG_MB} MB | Min: ${MIN_MB} MB | Max: ${MAX_MB} MB"
  echo "(Min = settled idle footprint of the production binary)"
  echo "Results saved to $OUTPUT_FILE"
} | tee -a "$OUTPUT_FILE"
