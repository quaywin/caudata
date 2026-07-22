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

  # Ensures the binary is valid UTF-8, replacing invalid segments with empty space
  def make_valid_utf8(binary) do
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
    # Regex matching ESC [ ... letter, using curly brackets as delimiters for the regex to avoid slash issues
    String.replace(binary, ~r{\x1B[@-_][0-?]*[ -/]*[@-~]}, "")
  end

  # Strips control characters (0x00 to 0x1F except tab, and 0x7F to 0x9F)
  def strip_control_characters(binary) do
    # Replace non-printable ASCII controls (0x00-0x1F except tab 0x09) and DEL (0x7F)
    binary
    |> String.replace(~r{[\x00-\x08\x0A-\x1F\x7F]}, "")
  end

  # Truncates lines exceeding the maximum length
  def truncate_line(binary) do
    if String.length(binary) > @max_line_length do
      String.slice(binary, 0, @max_line_length) <> "... [truncated]"
    else
      binary
    end
  end
end
