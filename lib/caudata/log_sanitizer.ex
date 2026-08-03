defmodule Caudata.LogSanitizer do
  @moduledoc """
  Sanitizes untrusted remote log inputs before they are stored or rendered.
  """

  @max_line_length 5000

  @doc """
  Sanitizes a raw log line string.
  - Ensures valid UTF-8
  - Strips ANSI escape codes
  - Strips or replaces non-printable control characters
  - Truncates extremely long lines
  """
  def sanitize(nil), do: ""

  def sanitize(line) when is_binary(line) do
    line
    |> make_valid_utf8()
    |> strip_ansi_escapes()
    |> strip_control_characters()
    |> truncate_line()
  end

  @ansi_regex ~r{\x1B[@-_][0-?]*[ -/]*[@-~]}
  @control_regex ~r{[\x00-\x08\x0A-\x1F\x7F]}

  # Ensures the binary is valid UTF-8, replacing invalid segments with empty space
  def make_valid_utf8(binary) when is_binary(binary) do
    if String.valid?(binary) do
      binary
    else
      do_make_valid_utf8(binary)
    end
  end

  defp do_make_valid_utf8(binary) do
    case :unicode.characters_to_binary(binary, :utf8, :utf8) do
      valid when is_binary(valid) ->
        valid

      {:incomplete, valid, rest} ->
        valid <> scrub_invalid_utf8(rest)

      {:error, valid, rest} ->
        valid <> scrub_invalid_utf8(rest)
    end
  end

  def scrub_invalid_utf8(binary) when is_binary(binary) do
    case :unicode.characters_to_binary(binary, :utf8, :utf8) do
      valid when is_binary(valid) ->
        valid

      {:incomplete, valid, rest} ->
        valid <> scrub_bytes(rest)

      {:error, valid, rest} ->
        valid <> scrub_bytes(rest)
    end
  end

  defp scrub_bytes(<<_byte, rest::binary>>) do
    "" <> scrub_invalid_utf8(rest)
  end

  defp scrub_bytes(<<>>), do: ""

  # Strips standard ANSI color and formatting escape sequences
  def strip_ansi_escapes(binary) do
    String.replace(binary, @ansi_regex, "")
  end

  # Strips control characters (0x00 to 0x1F except tab, and 0x7F to 0x9F)
  def strip_control_characters(binary) do
    String.replace(binary, @control_regex, "")
  end

  # Truncates lines exceeding the maximum length
  def truncate_line(binary) do
    if byte_size(binary) > @max_line_length and String.length(binary) > @max_line_length do
      String.slice(binary, 0, @max_line_length) <> "... [truncated]"
    else
      binary
    end
  end

  @max_buffer_size 10_000

  @doc """
  Processes an incoming binary log chunk accumulated with a buffer.
  Splits lines by newline while capping line lengths to max_buffer_size.
  Returns `{complete_lines, remaining_buffer}`.
  """
  def process_chunk(chunk, buffer, max_size \\ @max_buffer_size) do
    combined = buffer <> chunk

    case String.split(combined, ~r{\r?\n}) do
      [single_part] ->
        if byte_size(single_part) > max_size do
          {chunk_part, rest_part} = String.split_at(single_part, max_size)
          {[chunk_part], rest_part}
        else
          {[], single_part}
        end

      parts ->
        {complete_lines, [incomplete_part]} = Enum.split(parts, -1)

        cleaned_complete_lines =
          Enum.map(complete_lines, fn line ->
            if byte_size(line) > max_size do
              String.slice(line, 0, max_size)
            else
              line
            end
          end)

        if byte_size(incomplete_part) > max_size do
          {chunk_part, rest_part} = String.split_at(incomplete_part, max_size)
          {cleaned_complete_lines ++ [chunk_part], rest_part}
        else
          {cleaned_complete_lines, incomplete_part}
        end
    end
  end
end
