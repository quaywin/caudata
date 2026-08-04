defmodule Caudata.Native do
  @moduledoc """
  Elixir bridge delegating to the standalone ExLogFormatter Rust NIF package.
  """

  def sanitize_log(line), do: ExLogFormatter.sanitize(line)
  def parse_log_line(line), do: ExLogFormatter.format_line_with_meta(line)
  def sub_highlight_native(text), do: ExLogFormatter.sub_highlight(text)
  def process_chunk_native(chunk, buffer, max_len), do: ExLogFormatter.process_chunk(chunk, buffer, max_len)
end
