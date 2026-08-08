# Full Comprehensive Micro-Benchmark Suite for Caudata
# Run with: mix run bench/full_benchmark_suite.exs

alias Caudata.LogSanitizer
alias Caudata.UI.LogFormatter
alias Caudata.LogStore
alias Caudata.ConfigStore
alias Caudata.UI.ViewHelper

IO.puts("=================================================================")
IO.puts(" 🦎 Caudata Comprehensive Benchmark Suite (100% Coverage)")
IO.puts("=================================================================\n")

# Setup 1: Dedicated LogStores for Append vs Snapshot to isolate mailbox pressure
{:ok, _append_store} = LogStore.start_link(name: :bench_append_store, capacity: 10_000)
{:ok, _snapshot_store} = LogStore.start_link(name: :bench_snapshot_store, capacity: 10_000)

# Setup 2: ConfigStore
tmp_config_dir = System.tmp_dir!() |> Path.join("caudata_bench_#{:rand.uniform(1_000_000)}")
File.mkdir_p!(tmp_config_dir)
tmp_config_file = Path.join(tmp_config_dir, "config.db")
{:ok, _cfg_pid} = ConfigStore.start_link(name: :bench_full_config_store, config_path: tmp_config_file)

# Sample Data
json_log = "{\"time\":\"2026-08-04T13:14:00Z\",\"level\":\"info\",\"ip\":\"192.168.1.10\",\"method\":\"GET\",\"url\":\"/api/v1/users\",\"status\":200,\"req_id\":\"550e8400-e29b-41d4-a716-446655440000\",\"duration_ms\":45}"
logfmt_log = "time=2026-08-04T13:14:00Z level=info ip=192.168.1.10 method=GET url=/api/v1/users status=200 req_id=550e8400-e29b-41d4-a716-446655440000 duration_ms=45ms"
text_log = "2026-08-04T13:14:00Z [INFO] 192.168.1.10 GET /api/v1/users HTTP/1.1 200 45 ms - req_id=550e8400-e29b-41d4-a716-446655440000"
ansi_log = "\e[32m2026-08-04T13:14:00Z\e[0m [\e[31mERROR\e[0m] Failed to process request 550e8400-e29b-41d4-a716-446655440000: \e[4mHTTP 500\e[0m"

raw_chunk = String.duplicate(text_log <> "\n", 50)
sample_batch_100 = Enum.map(1..100, fn _ -> json_log end)

# Pre-fill snapshot store once
LogStore.append_logs(:bench_snapshot_store, "stream_5k", Enum.map(1..5_000, fn i -> "2026-08-04T13:14:00Z [INFO] User #{i} logged in from 192.168.1.#{rem(i, 255)}" end))
Process.sleep(100)

logs_5k = LogStore.get_snapshot(:bench_snapshot_store, "stream_5k", 5_000)

model_5k_filtered = %{
  logs: logs_5k,
  filter_regex: "User 12",
  filter_error: false,
  selected_container_id: "container_123",
  mode: :normal,
  height: 40
}

Benchee.run(
  %{
    # 1. LogSanitizer
    "[LogSanitizer] sanitize (JSON)" => fn -> LogSanitizer.sanitize(json_log) end,
    "[LogSanitizer] sanitize (ANSI)" => fn -> LogSanitizer.sanitize(ansi_log) end,
    "[LogSanitizer] process_chunk (50 lines chunk)" => fn -> LogSanitizer.process_chunk(raw_chunk, "") end,

    # 2. LogFormatter
    "[LogFormatter] format_line (JSON)" => fn -> LogFormatter.format_line(json_log) end,
    "[LogFormatter] format_line (Logfmt)" => fn -> LogFormatter.format_line(logfmt_log) end,
    "[LogFormatter] format_line (Text + SubHighlight)" => fn -> LogFormatter.format_line(text_log) end,

    # 3. LogStore
    "[LogStore] append_logs (100 lines cast)" => fn -> LogStore.append_logs(:bench_append_store, "bench_stream", sample_batch_100) end,
    "[LogStore] get_snapshot (5,000 lines snapshot)" => fn -> LogStore.get_snapshot(:bench_snapshot_store, "stream_5k", 5_000) end,

    # 4. ConfigStore (ETS zero-latency reads vs writes)
    "[ConfigStore] get_setting (ETS read)" => fn -> ConfigStore.get_setting(:bench_full_config_store, "global", "theme", "dark") end,
    "[ConfigStore] put_setting (GenServer call + Task write)" => fn -> ConfigStore.put_setting(:bench_full_config_store, "global", "buffer_capacity", 10_000) end,

    # 5. UI ViewHelper (Filtering & Processing)
    "[ViewHelper] get_displayed_logs (Regex Filter over 5,000 lines)" => fn -> ViewHelper.get_displayed_logs(model_5k_filtered) end
  },
  time: 5,
  warmup: 1,
  memory_time: 1
)

# Cleanup
File.rm_rf!(tmp_config_dir)
