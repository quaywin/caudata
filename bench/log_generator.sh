#!/usr/bin/env bash
# High-Throughput Synthetic Log Generator for Caudata Benchmarking
# Usage: ./bench/log_generator.sh [rate_per_sec] [format]
# Formats: json, logfmt, text (default: json)

RATE=${1:-1000}
FORMAT=${2:-json}
DELAY=$(awk "BEGIN {print 1.0 / $RATE}")

IPS=("192.168.1.1" "10.0.0.5" "172.16.254.1" "2001:0db8:85a3:0000:0000:8a2e:0370:7334")
METHODS=("GET" "POST" "PUT" "DELETE")
STATUSES=(200 201 400 401 404 500 502)
URLS=("/api/v1/users" "/healthz" "/auth/login" "/data/export" "/static/main.css")
LEVELS=("INFO" "DEBUG" "WARN" "ERROR")

echo "Starting Log Generator ($FORMAT format, ~$RATE lines/sec)... Press Ctrl+C to stop." >&2

while true; do
  TS=$(date -u +"%Y-%m-%dT%H:%M:%S.%3NZ")
  IP=${IPS[$RANDOM % ${#IPS[@]}]}
  METHOD=${METHODS[$RANDOM % ${#METHODS[@]}]}
  STATUS=${STATUSES[$RANDOM % ${#STATUSES[@]}]}
  URL=${URLS[$RANDOM % ${#URLS[@]}]}
  LEVEL=${LEVELS[$RANDOM % ${#LEVELS[@]}]}
  UUID="550e8400-e29b-41d4-a716-$((RANDOM%89999 + 10000))"
  DUR=$((RANDOM % 500 + 1))

  case $FORMAT in
    json)
      echo "{\"time\":\"$TS\",\"level\":\"$LEVEL\",\"ip\":\"$IP\",\"method\":\"$METHOD\",\"url\":\"$URL\",\"status\":$STATUS,\"req_id\":\"$UUID\",\"duration_ms\":$DUR}"
      ;;
    logfmt)
      echo "time=$TS level=$LEVEL ip=$IP method=$METHOD url=$URL status=$STATUS req_id=$UUID duration_ms=${DUR}ms"
      ;;
    text)
      echo "$TS [$LEVEL] $IP $METHOD $URL HTTP/1.1 $STATUS $DUR ms - req_id=$UUID"
      ;;
  esac

  sleep "$DELAY"
done
