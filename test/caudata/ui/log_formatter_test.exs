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

  test "wrap_spans/2 splits spans at width boundaries correctly" do
    alias Caudata.UI.ViewHelper
    alias ExRatatui.Text.Span
    alias ExRatatui.Style

    spans = [
      Span.new("2026-06-08 12:00:00 ", style: %Style{fg: :dark_gray}),
      Span.new("[info] ", style: %Style{fg: :green}),
      Span.new("Hello world message", style: %Style{fg: :white})
    ]

    # Total lengths: ts=20, lvl=7, msg=19. Total=46.
    # Wrap at width = 25:
    # Line 1 should have: ts (20) + first 5 chars of lvl ("[info") = 25
    # Line 2 should have: rest of lvl ("] ") (2) + msg (19) = 21 (fits within 25)
    wrapped = ViewHelper.wrap_spans(spans, 25)
    assert length(wrapped) == 2

    [line1, line2] = wrapped
    assert [s1, s2] = line1
    assert s1.content == "2026-06-08 12:00:00 "
    assert s1.style.fg == :dark_gray
    assert s2.content == "[info"
    assert s2.style.fg == :green

    assert [s3, s4] = line2
    assert s3.content == "] "
    assert s3.style.fg == :green
    assert s4.content == "Hello world message"
    assert s4.style.fg == :white
  end
end
