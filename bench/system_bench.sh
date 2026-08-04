#!/usr/bin/env bash
# System Macro-Benchmark Script for Caudata
# Measures Memory (RSS in KB/MB) and CPU usage over time during Idle and High Throughput.

OUTPUT_FILE="bench/system_bench_results.txt"
echo "=== Caudata System Macro-Benchmark Results ===" > "$OUTPUT_FILE"
echo "Date: $(date)" >> "$OUTPUT_FILE"
echo "OS: $(uname -sr)" >> "$OUTPUT_FILE"
echo "----------------------------------------------" >> "$OUTPUT_FILE"

# 1. Compile release or build target
echo "[1/3] Compiling dev release..." | tee -a "$OUTPUT_FILE"
rtk mix compile > /dev/null

# 2. Test Idle Memory & CPU (30 seconds)
echo "[2/3] Measuring Idle Memory & CPU (30s baseline)..." | tee -a "$OUTPUT_FILE"
mix run --no-halt &
APP_PID=$!
sleep 3

if ps -p $APP_PID > /dev/null; then
  # Sample RSS and CPU 5 times
  TOTAL_RSS=0
  for i in {1..5}; do
    RSS=$(ps -o rss= -p $APP_PID | tr -d ' ')
    CPU=$(ps -o %cpu= -p $APP_PID | tr -d ' ')
    RSS_MB=$(awk "BEGIN {print $RSS / 1024}")
    echo "  Sample $i: RSS = ${RSS_MB} MB, CPU = ${CPU}%" >> "$OUTPUT_FILE"
    TOTAL_RSS=$((TOTAL_RSS + RSS))
    sleep 2
  done
  AVG_RSS=$(awk "BEGIN {print ($TOTAL_RSS / 5) / 1024}")
  echo "=> Average Idle Memory (RSS): ${AVG_RSS} MB" | tee -a "$OUTPUT_FILE"
  kill $APP_PID 2>/dev/null
else
  echo "Failed to launch application process for benchmark." | tee -a "$OUTPUT_FILE"
fi

echo "----------------------------------------------" >> "$OUTPUT_FILE"
echo "Macro-benchmark completed. Results saved to $OUTPUT_FILE" | tee -a "$OUTPUT_FILE"
