# Throughput Benchmark for Caudata — real ingest + parse throughput (lines/s)
# Run with: mix run bench/throughput_bench.exs
#
# Measures what the per-op suites do not:
#
#   1. STEADY-STATE INGEST throughput (lines/s) through LogStore — the real
#      append cost: per-line sanitize + the O(n log n) queue re-sort on every
#      append (log_store.ex handle_cast) + ETS snapshot insert + PubSub
#      broadcast. append_logs/3 is a cast, so we pair it with get_stats/2
#      (a call) as a FIFO mailbox barrier — the call's reply is only sent
#      after the cast's work is fully processed, so the measured time
#      includes the real append cost. The store is pre-filled to capacity so
#      the measurement reflects the production steady state (buffer full,
#      eviction active), not a best-case empty buffer.
#
#      lines/s = ips (iterations/s) x batch_size
#
#   2. PARSE-ONLY throughput (lines/s) — sanitize + Rust NIF parse_log_line
#      over a batch. This is the backing for the "lines/s parsing" claim,
#      measured end-to-end on a batch instead of a single call.

alias Caudata.LogStore
alias Caudata.LogSanitizer
alias Caudata.Native

IO.puts("=================================================================")
IO.puts(" 🦎 Caudata Throughput Benchmark (ingest + parse, lines/s)")
IO.puts("=================================================================\n")

capacity = 10_000
batch_100_size = 100
batch_1000_size = 1000

format_lines = fn
  lps when lps >= 1_000_000 -> :erlang.float_to_binary(lps / 1_000_000, decimals: 2) <> "M"
  lps when lps >= 1_000 -> :erlang.float_to_binary(lps / 1_000, decimals: 1) <> "k"
  lps -> :erlang.float_to_binary(lps, decimals: 0)
end

json_log = "{\"time\":\"2026-08-04T13:14:00Z\",\"level\":\"info\",\"ip\":\"192.168.1.10\",\"method\":\"GET\",\"url\":\"/api/v1/users\",\"status\":200,\"req_id\":\"550e8400-e29b-41d4-a716-446655440000\",\"duration_ms\":45}"
text_log = "2026-08-04T13:14:00Z [INFO] 192.168.1.10 GET /api/v1/users HTTP/1.1 200 45 ms - req_id=550e8400-e29b-41d4-a716-446655440000"

# ---------------------------------------------------------------------------
# 1. Steady-state ingest: pre-fill to capacity, then benchmark full-buffer appends
# ---------------------------------------------------------------------------
{:ok, store} = LogStore.start_link(name: :bench_tp_store, capacity: capacity)

LogStore.append_logs(
  store,
  "tp",
  Enum.map(1..capacity, fn i ->
    "2026-08-04T13:14:00Z [INFO] prefilled line #{i} from 192.168.1.#{rem(i, 255)}"
  end)
)

# Drain the pre-fill cast + confirm the buffer is full before measuring
Process.sleep(200)
%{size: ^capacity} = LogStore.get_stats(store, "tp")

batch_100 = Enum.map(1..batch_100_size, fn _ -> json_log end)
batch_1000 = Enum.map(1..batch_1000_size, fn _ -> json_log end)

IO.puts("--- [1/2] Ingest throughput (steady-state, full #{capacity}-line buffer) ---\n")

ingest_suite =
  Benchee.run(
    %{
      "Ingest: append_logs + sync barrier (100-line batch)" => fn ->
        LogStore.append_logs(store, "tp", batch_100)
        LogStore.get_stats(store, "tp")
      end,
      "Ingest: append_logs + sync barrier (1000-line batch)" => fn ->
        LogStore.append_logs(store, "tp", batch_1000)
        LogStore.get_stats(store, "tp")
      end
    },
    warmup: 1,
    time: 5,
    memory_time: 1,
    parallel: 1,
    print: [fast_warning: false]
  )

# ---------------------------------------------------------------------------
# 2. Parse-only throughput: sanitize + NIF parse over a batch
# ---------------------------------------------------------------------------
parse_batch_json = Enum.map(1..batch_1000_size, fn _ -> json_log end)
parse_batch_text = Enum.map(1..batch_1000_size, fn _ -> text_log end)

IO.puts("\n--- [2/2] Parse throughput (sanitize + Caudata.Native.parse_log_line, 1000-line batch) ---\n")

parse_suite =
  Benchee.run(
    %{
      "Parse: sanitize + Native.parse_log_line (JSON)" => fn ->
        Enum.each(parse_batch_json, fn line ->
          line |> LogSanitizer.sanitize() |> Native.parse_log_line()
        end)
      end,
      "Parse: sanitize + Native.parse_log_line (Text)" => fn ->
        Enum.each(parse_batch_text, fn line ->
          line |> LogSanitizer.sanitize() |> Native.parse_log_line()
        end)
      end
    },
    warmup: 1,
    time: 5,
    memory_time: 1,
    parallel: 1,
    print: [fast_warning: false]
  )

# ---------------------------------------------------------------------------
# Summary: derive lines/s from ips x batch_size
# ---------------------------------------------------------------------------
batch_for = fn job_name ->
  cond do
    String.contains?(job_name, "1000-line") -> batch_1000_size
    String.contains?(job_name, "100-line") -> batch_100_size
    true -> batch_1000_size
  end
end

ips_of = fn scenario -> scenario.run_time_data.statistics.ips end

rows =
  (ingest_suite.scenarios ++ parse_suite.scenarios)
  |> Enum.map(fn sc -> {sc.job_name, ips_of.(sc) * batch_for.(sc.job_name)} end)
  |> Enum.sort_by(fn {_n, lps} -> lps end, :desc)

IO.puts("\n=================================================================")
IO.puts(" 📈 Throughput Summary (lines/s)")
IO.puts("=================================================================")

Enum.each(rows, fn {name, lps} ->
  IO.puts("  #{format_lines.(lps)} lines/s  <=  #{name}")
end)

IO.puts("=================================================================\n")

:ok
