# Micro-Benchmark for Caudata Log Pipeline
# Run with: mix run bench/parser_bench.exs

alias Caudata.LogSanitizer
alias Caudata.UI.LogFormatter

json_log = "{\"time\":\"2026-08-04T13:14:00Z\",\"level\":\"info\",\"ip\":\"192.168.1.10\",\"method\":\"GET\",\"url\":\"/api/v1/users\",\"status\":200,\"req_id\":\"550e8400-e29b-41d4-a716-446655440000\",\"duration_ms\":45}"

logfmt_log = "time=2026-08-04T13:14:00Z level=info ip=192.168.1.10 method=GET url=/api/v1/users status=200 req_id=550e8400-e29b-41d4-a716-446655440000 duration_ms=45ms"

text_log = "2026-08-04T13:14:00Z [INFO] 192.168.1.10 GET /api/v1/users HTTP/1.1 200 45 ms - req_id=550e8400-e29b-41d4-a716-446655440000"

ansi_log = "\e[32m2026-08-04T13:14:00Z\e[0m [\e[31mERROR\e[0m] Failed to process request 550e8400-e29b-41d4-a716-446655440000: \e[4mHTTP 500\e[0m"

alias Caudata.LogStore

# Start a dedicated LogStore instance for benchmarking
{:ok, _pid} = LogStore.start_link(name: :bench_log_store, capacity: 10_000)

sample_batch = Enum.map(1..100, fn _i -> json_log end)

IO.puts("=================================================================")
IO.puts(" 🦎 Caudata Micro-Benchmark: LogSanitizer, LogFormatter & LogStore")
IO.puts("=================================================================\n")

Benchee.run(
  %{
    "LogSanitizer.sanitize (JSON log)" => fn -> LogSanitizer.sanitize(json_log) end,
    "LogSanitizer.sanitize (ANSI colored log)" => fn -> LogSanitizer.sanitize(ansi_log) end,
    "LogFormatter.format_line (JSON)" => fn -> LogFormatter.format_line(json_log) end,
    "LogFormatter.format_line (Logfmt)" => fn -> LogFormatter.format_line(logfmt_log) end,
    "LogFormatter.format_line (Text + SubHighlight)" => fn -> LogFormatter.format_line(text_log) end,
    "Full Pipeline: Sanitize + Format (JSON)" => fn ->
      json_log |> LogSanitizer.sanitize() |> LogFormatter.format_line()
    end,
    "Full Pipeline: Sanitize + Format (Text)" => fn ->
      text_log |> LogSanitizer.sanitize() |> LogFormatter.format_line()
    end,
    "RUST NIF: Caudata.Native.sanitize_log (ANSI)" => fn ->
      Caudata.Native.sanitize_log(ansi_log)
    end,
    "RUST NIF: Caudata.Native.parse_log_line (JSON)" => fn ->
      Caudata.Native.parse_log_line(json_log)
    end,
    "LogStore.append_logs (100 lines batch)" => fn ->
      LogStore.append_logs(:bench_log_store, "bench_stream", sample_batch)
    end
  },
  time: 3,
  warmup: 1,
  memory_time: 1
)
