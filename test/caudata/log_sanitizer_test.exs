defmodule Caudata.LogSanitizerTest do
  use ExUnit.Case, async: true
  alias Caudata.LogSanitizer

  test "make_valid_utf8 cleans up invalid sequences" do
    invalid = <<0x80, 0x81, "valid string", 0xFF>>
    cleaned = LogSanitizer.make_valid_utf8(invalid)
    assert cleaned == "valid string"
  end

  test "strip_ansi_escapes removes terminal formatting" do
    line = "\e[31mRed Text\e[0m and \e[1mBold Text\e[22m"
    cleaned = LogSanitizer.strip_ansi_escapes(line)
    assert cleaned == "Red Text and Bold Text"
  end

  test "strip_control_characters removes non-printable controls but preserves tab" do
    # \x00 is null, \x07 is bell, \x09 is tab
    line = "Hello\x00World\x07!\t"
    cleaned = LogSanitizer.strip_control_characters(line)
    assert cleaned == "HelloWorld!\t"
  end

  test "truncate_line cuts extremely long lines and appends suffix" do
    long_line = String.duplicate("A", 6000)
    truncated = LogSanitizer.truncate_line(long_line)
    assert String.length(truncated) == 5015
    assert String.ends_with?(truncated, "... [truncated]")
  end

  test "sanitize combines all rules" do
    line = <<0x80, "\e[32m[INFO]\e[0m Connection \x00 established", 0xFF>>
    assert LogSanitizer.sanitize(line) == "[INFO] Connection  established"
  end
end
