defmodule Caudata.UI.LogFormatterTest do
  use ExUnit.Case, async: true

  alias Caudata.UI.LogFormatter

  test "formats info log with bracket level" do
    spans = LogFormatter.format_line("2026-06-08 12:00:00 [info]   message with leading spaces")
    assert [ts, lvl, msg] = spans
    assert ts.content == "2026-06-08 12:00:00 "
    assert ts.style.fg == :dark_gray
    assert lvl.content == "[info] "
    assert lvl.style.fg == :green
    assert :bold in lvl.style.modifiers
    assert msg.content == "  message with leading spaces"
    assert msg.style.fg == :white
  end

  test "formats warn log with colon level" do
    spans = LogFormatter.format_line("2026-06-08 15:33:22 ERROR: Database error")
    assert [ts, lvl, msg] = spans
    assert ts.content == "2026-06-08 15:33:22 "
    assert lvl.content == "ERROR: "
    assert lvl.style.fg == :red
    assert msg.content == "Database error"
  end

  test "formats plain message without structured level or timestamp" do
    spans = LogFormatter.format_line("Just a plain message")
    assert [msg] = spans
    assert msg.content == "Just a plain message"
    assert msg.style.fg == :white
  end
end
