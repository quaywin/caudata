defmodule Caudata.UI.LogFormatter do
  @moduledoc """
  High-performance log formatter for Caudata, delegating parsing and syntax highlighting
  directly to the Rust Native `ExLogFormatter` NIF engine with process-level memoization.
  """

  alias ExRatatui.Style
  alias ExRatatui.Text.Span

  alias Caudata.UI.Cache

  @doc """
  Formats a single log line into a tuple `{spans, is_error, severity_num}`.
  Caches the result in a bounded 2-generation cache for sub-millisecond redraws.
  """
  def format_line_with_meta(line) when is_binary(line) do
    Cache.fetch(:fmt_line_meta, line, fn -> do_format_line_with_meta(line) end)
  end

  def format_line_with_meta(nil), do: {[], false, 0}

  @doc """
  Formats a single log line into a list of spans.
  """
  def format_line(line) do
    {spans, _is_error, _level} = format_line_with_meta(line)
    spans
  end

  @doc """
  Sub-highlights a line of text using native token parsing.
  """
  def sub_highlight(text) when is_binary(text) do
    Cache.fetch(:sub_highlight, text, fn -> Caudata.Native.sub_highlight_native(text) end)
  end

  defp do_format_line_with_meta(line) do
    try do
      Caudata.Native.parse_log_line(line)
    rescue
      _ ->
        {[Span.new(line, style: %Style{fg: :white})], false, 0}
    end
  end
end
