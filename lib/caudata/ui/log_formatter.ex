defmodule Caudata.UI.LogFormatter do
  @moduledoc """
  Parses raw log strings using a Multi-Stage Parser Pipeline and converts them into
  structured `ExRatatui.Text.Span` lists with rich styling and sub-element highlighting.

  Pipeline Stages:
  1. JSON Parser (`Jason.decode/1`) - Formats structured JSON logs.
  2. Logfmt / Key-Value Parser - Formats `key=value` log streams.
  3. General Regex Parser - Formats traditional `[timestamp] [level] message` logs.
  4. Sub-Highlighter - Auto-highlights HTTP status codes, durations, IPs, URLs, paths, UUIDs, and HTTP methods.
  """

  alias ExRatatui.Style
  alias ExRatatui.Text.Span

  @log_regex ~r/^(?:(?=\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}|\d{2}:\d{2}:\d{2}|\[[a-zA-Z0-9_-]+\]|\b(?:info|warn|warning|error|err|debug|fatal|trace|critical|crit|emerg|emergency|stderr|fail|failure)\b)(?:(?<ts>\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:?\d{2})?|\d{2}:\d{2}:\d{2}(?:\.\d+)?)\s)?(?:(?:\[(?<bracket_lvl>[a-zA-Z0-9_-]+)\]|(?<colon_lvl>\b(?:info|warn|warning|error|err|debug|fatal|trace|critical|crit|emerg|emergency|stderr|fail|failure)\b):|(?<bare_lvl>\b(?:info|warn|warning|error|err|debug|fatal|trace|critical|crit|emerg|emergency|stderr|fail|failure)\b))\s?)?)?(?<msg>.*)$/i

  @logfmt_regex ~r/(?<key>[a-zA-Z0-9_.-]+)=(?:"(?<qval>[^"]*)"|(?<uval>[^\s]+))/

  @sub_highlight_regex ~r/(?<uuid>\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b)|(?<hash>\b0x[0-9a-fA-F]+\b|\b[0-9a-fA-F]{40}\b)|(?<url>\bhttps?:\/\/[^\s]+)|(?<ip_bracket>\[[0-9a-fA-F:]+\](?::\d{1,5})?)|(?<ip_v4>\b(?:[0-9]{1,3}\.){3}[0-9]{1,3}(?::\d{1,5}|\/(?:[0-9]|[12][0-9]|3[0-2]))?\b)|(?<ip_v6>\b(?:[0-9a-fA-F]{1,4}:)+(?::[0-9a-fA-F]{1,4})+(?:\/(?:[0-9]|[1-9][0-9]|1[0-1][0-9]|12[0-8]))?\b|\b(?:[0-9a-fA-F]{1,4}:){1,7}:(?:\/(?:[0-9]|[1-9][0-9]|1[0-1][0-9]|12[0-8]))?\b|(?:^|[\s"'\x28])::(?:[0-9a-fA-F]{1,4}:){0,5}[0-9a-fA-F]{1,4}(?:\/(?:[0-9]|[1-9][0-9]|1[0-1][0-9]|12[0-8]))?\b|(?:^|[\s"'\x28])::(?:\/(?:[0-9]|[1-9][0-9]|1[0-1][0-9]|12[0-8]))?)|(?<path>(?:^|[\s"'\x28])\/(?:[a-zA-Z0-9._-]+\/)*[a-zA-Z0-9._-]*)|(?<duration>\b\d+(?:\.\d+)?(?:µs|us|ms|s|min|ns)\b)|(?<method>\b(?:GET|POST|PUT|DELETE|PATCH|OPTIONS|HEAD)\b)|(?<status>\b[1-5]\d{2}\b)/i

  @doc """
  Formats a single log line into a tuple `{spans, is_error}`.
  """
  def format_line_with_meta(line) when is_binary(line) do
    case Process.get({:fmt_line_meta, line}) do
      nil ->
        res = do_format_line_with_meta(line)
        Process.put({:fmt_line_meta, line}, res)
        res

      cached ->
        cached
    end
  end

  def format_line_with_meta(nil), do: {[], false}

  defp do_format_line_with_meta(line) do
    cond do
      line == "" ->
        {[Span.new("", style: %Style{fg: :white})], false}

      match = try_parse_json(line) ->
        match

      match = try_parse_logfmt(line) ->
        match

      true ->
        parse_general_log(line)
    end
  end

  @doc """
  Formats a single log line into a list of spans.
  """
  def format_line(line) do
    {spans, _is_error} = format_line_with_meta(line)
    spans
  end

  # ===========================================================================
  # Stage 1: JSON Log Parser
  # ===========================================================================

  defp try_parse_json(line) do
    trimmed = String.trim(line)

    cond do
      String.starts_with?(trimmed, "{") and String.ends_with?(trimmed, "}") ->
        case Jason.decode(trimmed) do
          {:ok, map} when is_map(map) and map != %{} ->
            format_json_map(map)

          _ ->
            nil
        end

      # Handles container stream headers before JSON (e.g., "2026-08-04T10:15:00Z stdout F {"level":"info",...}")
      String.contains?(trimmed, "{") and String.ends_with?(trimmed, "}") ->
        case Regex.run(~r/^(?<prefix>.*?)\s*(?<json>\{.*?\})$/s, trimmed) do
          [_, prefix, json_str] ->
            case Jason.decode(json_str) do
              {:ok, map} when is_map(map) and map != %{} ->
                format_prefixed_json(prefix, map)

              _ ->
                nil
            end

          _ ->
            nil
        end

      true ->
        nil
    end
  end

  defp format_prefixed_json(prefix, map) do
    {prefix_spans, prefix_is_err} = parse_general_log(prefix)
    {json_spans, json_is_err} = format_json_map(map)
    {prefix_spans ++ json_spans, prefix_is_err or json_is_err}
  end

  defp format_json_map(map) do
    lvl_val = fetch_first_key_value(map, ["level", "severity", "lvl", "log.level", "s"])
    is_err = is_json_error?(map, lvl_val && to_string(lvl_val))

    spans =
      map
      |> Enum.with_index()
      |> Enum.flat_map(fn {{k, v}, idx} ->
        prefix = if idx > 0, do: " ", else: ""
        key_span = Span.new(prefix <> k <> "=", style: %Style{fg: :cyan})

        val_spans =
          cond do
            k in ["level", "severity", "lvl", "log.level", "s"] ->
              str = to_string(v)
              style = level_style(str)
              [Span.new("[" <> String.upcase(str) <> "]", style: %{style | modifiers: [:bold]})]

            k in ["timestamp", "time", "ts", "@timestamp", "datetime"] ->
              [Span.new(to_string(v), style: %Style{fg: :dark_gray})]

            k in [
              "message",
              "msg",
              "log",
              "message_text",
              "event",
              "detail",
              "details",
              "description",
              "reason",
              "text",
              "body",
              "payload",
              "summary",
              "info"
            ] ->
              sub_highlight(to_string(v), %Style{fg: :white})

            true ->
              format_json_val(v)
          end

        [key_span | val_spans]
      end)

    {spans, is_err}
  end

  defp fetch_first_key_entry(map, keys) do
    Enum.find_value(keys, fn k ->
      if Map.has_key?(map, k), do: {k, Map.get(map, k)}, else: nil
    end)
  end

  defp fetch_first_key_value(map, keys) do
    case fetch_first_key_entry(map, keys) do
      {_k, v} -> v
      nil -> nil
    end
  end

  defp is_json_error?(map, level_str) do
    is_error_line?(map, level_str, nil)
  end

  defp format_json_val(v) when is_binary(v) do
    sub_highlight(v, %Style{fg: :green})
  end

  defp format_json_val(v) when is_number(v), do: [Span.new(to_string(v), style: %Style{fg: :yellow})]
  defp format_json_val(v) when is_boolean(v), do: [Span.new(to_string(v), style: %Style{fg: :magenta})]
  defp format_json_val(nil), do: [Span.new("null", style: %Style{fg: :dark_gray})]

  defp format_json_val(v) when is_map(v) or is_list(v) do
    encoded = Jason.encode!(v)
    [Span.new(encoded, style: %Style{fg: :dark_gray})]
  end

  # ===========================================================================
  # Stage 2: Logfmt / Key-Value Parser
  # ===========================================================================

  defp try_parse_logfmt(line) do
    # Logfmt requires '=' and must NOT be an Elixir map (%{, =>) or Elixir struct print line
    if String.contains?(line, "=") and not String.contains?(line, "=>") and not String.contains?(line, "%{") do
      matches_index = Regex.scan(@logfmt_regex, line, return: :index)

      if matches_index != [] do
        kv_parsed =
          Enum.map(matches_index, fn [{start, len} | _] ->
            kv_str = binary_part(line, start, len)

            case String.split(kv_str, "=", parts: 2) do
              [key, raw_val] ->
                clean_val = String.trim(raw_val, "\"")
                {key, clean_val, raw_val, start, len}

              _ ->
                nil
            end
          end)
          |> Enum.reject(&is_nil/1)

        if valid_logfmt_line?(line, kv_parsed) do
          format_logfmt_parsed(line, kv_parsed)
        else
          nil
        end
      else
        nil
      end
    else
      nil
    end
  end

  defp valid_logfmt_line?(line, kv_parsed) do
    contains_known_logfmt_key?(kv_parsed) or
      (length(kv_parsed) >= 2 and Regex.match?(~r/^[a-zA-Z0-9_.-]+=/, String.trim_leading(line)))
  end

  defp contains_known_logfmt_key?(kv_parsed) do
    Enum.any?(kv_parsed, fn {key, _val, _raw_val, _start, _len} ->
      String.downcase(key) in [
        "level",
        "lvl",
        "severity",
        "msg",
        "message",
        "ts",
        "time",
        "status",
        "err",
        "error"
      ]
    end)
  end

  defp format_logfmt_parsed(line, kv_parsed) do
    kv_map =
      Enum.into(kv_parsed, %{}, fn {key, val, _raw, _s, _l} -> {key, val} end)

    lvl_val = fetch_first_key_value(kv_map, ["level", "lvl", "severity"])
    is_err = is_logfmt_error?(kv_map, lvl_val, line)

    {spans, last_pos} =
      Enum.reduce(kv_parsed, {[], 0}, fn {key, clean_val, raw_val, start, len}, {acc, pos} ->
        acc =
          if start > pos do
            unmatched = binary_part(line, pos, start - pos)
            [Span.new(unmatched, style: %Style{fg: :white}) | acc]
          else
            acc
          end

        kv_spans = format_logfmt_parsed_pair(key, clean_val, raw_val)

        {Enum.reverse(kv_spans) ++ acc, start + len}
      end)

    total_len = byte_size(line)

    spans =
      if last_pos < total_len do
        remaining = binary_part(line, last_pos, total_len - last_pos)
        [Span.new(remaining, style: %Style{fg: :white}) | spans]
      else
        spans
      end

    {Enum.reverse(spans), is_err}
  end

  defp format_logfmt_parsed_pair(key, clean_val, raw_val) do
    key_span = Span.new(key <> "=", style: %Style{fg: :cyan})

    val_spans =
      cond do
        String.downcase(key) in ["level", "lvl", "severity"] ->
          style = level_style(clean_val)
          [Span.new("[" <> String.upcase(clean_val) <> "]", style: %{style | modifiers: [:bold]})]

        String.downcase(key) in ["ts", "time", "timestamp"] ->
          [Span.new(clean_val, style: %Style{fg: :dark_gray})]

        String.downcase(key) in ["msg", "message"] ->
          sub_highlight(clean_val, %Style{fg: :white})

        true ->
          sub_highlight(raw_val, %Style{fg: :yellow})
      end

    [key_span | val_spans]
  end

  defp is_logfmt_error?(kv_map, level_str, line) do
    is_error_line?(kv_map, level_str, line)
  end

  # ===========================================================================
  # Stage 3: Regex General Parser
  # ===========================================================================

  defp parse_general_log(line) do
    case Regex.named_captures(@log_regex, line) do
      %{
        "ts" => ts,
        "bracket_lvl" => bracket_lvl,
        "colon_lvl" => colon_lvl,
        "bare_lvl" => bare_lvl,
        "msg" => msg
      } ->
        {level, lvl_style} =
          cond do
            bracket_lvl != "" -> {bracket_lvl, level_style(bracket_lvl)}
            colon_lvl != "" -> {colon_lvl, level_style(colon_lvl)}
            bare_lvl != "" -> {bare_lvl, level_style(bare_lvl)}
            true -> {nil, nil}
          end

        is_error = is_error_line?(nil, level, line)

        ts_span =
          if ts != "" do
            [Span.new(ts <> " ", style: %Style{fg: :dark_gray})]
          else
            []
          end

        lvl_span =
          cond do
            bracket_lvl != "" ->
              [Span.new("[" <> bracket_lvl <> "] ", style: %{lvl_style | modifiers: [:bold]})]

            colon_lvl != "" ->
              [Span.new(colon_lvl <> ": ", style: %{lvl_style | modifiers: [:bold]})]

            bare_lvl != "" ->
              [Span.new(bare_lvl <> " ", style: %{lvl_style | modifiers: [:bold]})]

            true ->
              []
          end

        msg_spans = sub_highlight(msg, %Style{fg: :white})
        spans = ts_span ++ lvl_span ++ msg_spans
        {spans, is_error}

      nil ->
        {sub_highlight(line, %Style{fg: :white}), is_error_line?(nil, nil, line)}
    end
  end

  # ===========================================================================
  # Stage 4: Sub-Highlighter
  # ===========================================================================

  @doc """
  Highlights sub-elements (HTTP methods/statuses, durations, IPs, URLs, paths, UUIDs, hashes) inside text.
  """
  def sub_highlight(text, base_style \\ %Style{fg: :white})

  def sub_highlight("", _base_style), do: []
  def sub_highlight(nil, _base_style), do: []

  def sub_highlight(text, base_style) when is_binary(text) do
    try do
      Caudata.Native.sub_highlight_native(text)
    rescue
      _ ->
        do_sub_highlight_fallback(text, base_style)
    end
  end

  defp do_sub_highlight_fallback(text, base_style) do
    matches = Regex.scan(@sub_highlight_regex, text, return: :index)

    if matches == [] do
      [Span.new(text, style: base_style)]
    else
      {spans, last_pos} =
        Enum.reduce(matches, {[], 0}, fn [{start, len} | _captures], {acc, pos} ->
          acc =
            if start > pos do
              unmatched = binary_part(text, pos, start - pos)
              [Span.new(unmatched, style: base_style) | acc]
            else
              acc
            end

          matched_token = binary_part(text, start, len)
          token_spans = style_sub_token(matched_token, base_style)

          {Enum.reverse(token_spans) ++ acc, start + len}
        end)

      total_len = byte_size(text)

      spans =
        if last_pos < total_len do
          remaining = binary_part(text, last_pos, total_len - last_pos)
          [Span.new(remaining, style: base_style) | spans]
        else
          spans
        end

      Enum.reverse(spans)
    end
  end

  defp style_sub_token(token, base_style) do
    cond do
      token =~ ~r/^(?:[\s"'\x28])\// ->
        <<prefix::binary-size(1), path_raw::binary>> = token

        case Regex.run(
               ~r/^(\/(?:[a-zA-Z0-9._-]+\/)*[a-zA-Z0-9._-]*?)([.,;:"'\)\}>\s]*)$/,
               path_raw
             ) do
          [_, clean_path, trailing] ->
            [
              Span.new(prefix, style: base_style),
              Span.new(clean_path, style: %Style{fg: :cyan}),
              Span.new(trailing, style: base_style)
            ]

          _ ->
            [
              Span.new(prefix, style: base_style),
              Span.new(path_raw, style: %Style{fg: :cyan})
            ]
        end

      token =~ ~r/^\/(?:[a-zA-Z0-9._-]+\/)*[a-zA-Z0-9._-]*$/ ->
        case Regex.run(~r/^(\/(?:[a-zA-Z0-9._-]+\/)*[a-zA-Z0-9._-]*?)([.,;:"'\)\}>\s]*)$/, token) do
          [_, clean_path, trailing] ->
            [
              Span.new(clean_path, style: %Style{fg: :cyan}),
              Span.new(trailing, style: base_style)
            ]

          _ ->
            [Span.new(token, style: %Style{fg: :cyan})]
        end

      token =~ ~r/^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/ ->
        [Span.new(token, style: %Style{fg: :dark_gray})]

      token =~ ~r/^(?:0x[0-9a-fA-F]+|[0-9a-fA-F]{40})$/ ->
        [Span.new(token, style: %Style{fg: :dark_gray})]

      token =~ ~r/^https?:\/\// ->
        case Regex.run(~r/^(https?:\/\/[^\s"'<>\(\)\[\]{}]+?)([.,;:"'\)\}>\s]*)$/, token) do
          [_, clean_url, trailing] ->
            [
              Span.new(clean_url, style: %Style{fg: :magenta}),
              Span.new(trailing, style: base_style)
            ]

          _ ->
            [Span.new(token, style: %Style{fg: :magenta})]
        end

      token =~ ~r/^(?:[\s"'\x28])::/ ->
        <<prefix::binary-size(1), ip::binary>> = token
        [
          Span.new(prefix, style: base_style),
          Span.new(ip, style: %Style{fg: :magenta})
        ]

      token =~
        ~r/^(?:\[[0-9a-fA-F:]+\](?::\d{1,5})?|(?:[0-9]{1,3}\.){3}[0-9]{1,3}(?::\d{1,5}|\/(?:[0-9]|[12][0-9]|3[0-2]))?|(?:[0-9a-fA-F]{1,4}:)+(?::[0-9a-fA-F]{1,4})+(?:\/(?:[0-9]|[1-9][0-9]|1[0-1][0-9]|12[0-8]))?|\b(?:[0-9a-fA-F]{1,4}:){1,7}:(?:\/(?:[0-9]|[1-9][0-9]|1[0-1][0-9]|12[0-8]))?|::(?:[0-9a-fA-F]{1,4}:){0,5}[0-9a-fA-F]{1,4}(?:\/(?:[0-9]|[1-9][0-9]|1[0-1][0-9]|12[0-8]))?|::(?:\/(?:[0-9]|[1-9][0-9]|1[0-1][0-9]|12[0-8]))?)$/i ->
        [Span.new(token, style: %Style{fg: :magenta})]

      token =~ ~r/^\d+(?:\.\d+)?(?:µs|us|ms|s|min|ns)$/ ->
        [Span.new(token, style: %Style{fg: :cyan})]

      token in ["GET", "POST", "PUT", "DELETE", "PATCH", "OPTIONS", "HEAD"] ->
        [Span.new(token, style: %Style{fg: :blue, modifiers: [:bold]})]

      token =~ ~r/^[1-5]\d{2}$/ ->
        style =
          case String.to_integer(token) do
            s when s in 200..299 -> %Style{fg: :green}
            s when s in 300..399 -> %Style{fg: :cyan}
            s when s in 400..499 -> %Style{fg: :yellow}
            s when s in 500..599 -> %Style{fg: :red, modifiers: [:bold]}
            _ -> base_style
          end

        [Span.new(token, style: style)]

      true ->
        [Span.new(token, style: base_style)]
    end
  end

  defp level_style(level) do
    case String.downcase(level) do
      l when l in ["info"] ->
        %Style{fg: :green}

      l when l in ["warn", "warning"] ->
        %Style{fg: :yellow}

      l
      when l in [
             "error",
             "err",
             "fatal",
             "critical",
             "crit",
             "emerg",
             "emergency",
             "stderr",
             "fail",
             "failure"
           ] ->
        %Style{fg: :red}

      l when l in ["debug", "trace"] ->
        %Style{fg: :magenta}

      _ ->
        %Style{fg: :cyan}
    end
  end

  @error_keywords_regex ~r/\b(?:panic|fatal|exception|crash|runtimeerror|compileerror|unhandled|traceback|backtrace)\b|\*\*\s*\(|\bcaused by:|\b\s*at\s+[a-zA-Z0-9_.$]+\(/i
  @strict_error_keywords_regex ~r/(?:\b(?:panic|runtimeerror|compileerror)\b:\s*|\b(?:fatal|uncaught|unhandled)\b|\*\*\s*\(|\btraceback \(most recent call last\):|\bcaused by:|\bgoroutine \d+ \[|\bstack backtrace:)/i

  def is_error_line?(map_or_kv, level_str, line) do
    level = level_str && String.downcase(to_string(level_str))
    is_err_lvl = level != nil and error_level?(level)
    is_non_err_lvl = level != nil and level in ["info", "warn", "warning", "debug", "trace", "notice", "30", "20", "10", "4", "5", "6", "7", "i", "w", "d"]

    key_err =
      if is_map(map_or_kv) do
        truthy_error_val?(
          fetch_first_key_value(map_or_kv, [
            "error",
            "err",
            "exception",
            "stack",
            "stacktrace",
            "backtrace",
            "error_message",
            "error_details",
            "exc_info",
            "cause"
          ])
        ) or is_5xx_status?(Map.get(map_or_kv, "status"))
      else
        false
      end

    has_5xx_http =
      line != nil and
        Regex.match?(
          ~r/\b(?:GET|POST|PUT|DELETE|PATCH|OPTIONS|HEAD)\b(?:\s+\S+|\s+"[^"]+")\s+(?:HTTP\/[12]\.[01]"?\s+)?5\d{2}\b(?!\.)|\b5\d{2}\b(?!\.)\s+\d+(?:ms|s|us)/i,
          line
        )

    cond do
      is_err_lvl ->
        true

      is_non_err_lvl ->
        key_err or has_5xx_http or (line != nil and Regex.match?(@strict_error_keywords_regex, line))

      true ->
        key_err or has_5xx_http or (line != nil and Regex.match?(@error_keywords_regex, line))
    end
  end

  defp truthy_error_val?(nil), do: false
  defp truthy_error_val?(false), do: false
  defp truthy_error_val?(""), do: false
  defp truthy_error_val?([]), do: false
  defp truthy_error_val?(%{}), do: false
  defp truthy_error_val?(_), do: true

  def is_5xx_status?(status) when is_integer(status), do: status in 500..599
  def is_5xx_status?(status) when is_binary(status), do: String.match?(status, ~r/^5\d{2}$/)
  def is_5xx_status?(_), do: false

  def log_regex, do: @log_regex

  def error_level?(level) do
    String.downcase(to_string(level)) in [
      "error",
      "err",
      "fatal",
      "critical",
      "crit",
      "emerg",
      "emergency",
      "stderr",
      "fail",
      "failure",
      "panic",
      "severe",
      "e",
      "f",
      "50",
      "60",
      "0",
      "1",
      "2",
      "3"
    ]
  end
end
