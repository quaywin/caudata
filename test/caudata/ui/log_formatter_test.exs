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

  describe "Stage 1: JSON Log Parser" do
    test "parses structured info JSON log" do
      json_line = ~s({"level":"info","timestamp":"2026-06-08 12:00:00","message":"Server booted","port":4000})
      {spans, is_error} = LogFormatter.format_line_with_meta(json_line)

      refute is_error
      contents = Enum.map(spans, & &1.content)
      assert "level=" in contents or "[INFO]" in contents
      assert "Server booted" in contents
      assert "4000" in contents
    end

    test "parses error JSON log and flags is_error" do
      json_line = ~s({"severity":"ERROR","msg":"Database timeout","error":"ETIMEDOUT"})
      {spans, is_error} = LogFormatter.format_line_with_meta(json_line)

      assert is_error
      contents = Enum.map(spans, & &1.content)
      assert "[ERROR]" in contents
      assert "Database timeout" in contents
      assert "ETIMEDOUT" in contents
    end

    test "handles nested JSON map/list values" do
      json_line = ~s({"level":"debug","message":"Event dispatched","meta":{"active":true}})
      {_spans, is_error} = LogFormatter.format_line_with_meta(json_line)

      refute is_error
    end

    test "parses container prefixed JSON logs" do
      prefixed_line = ~s(2026-08-04T10:15:00Z stdout F {"level":"info","message":"App started","port":4000})
      {spans, is_error} = LogFormatter.format_line_with_meta(prefixed_line)

      refute is_error
      contents = Enum.map(spans, & &1.content)
      assert "App started" in contents
      assert "4000" in contents
    end

    test "supports alternative message keys like event or payload" do
      json_line = ~s({"level":"info","event":"User login successful","user_id":123})
      {spans, is_error} = LogFormatter.format_line_with_meta(json_line)

      refute is_error
      contents = Enum.map(spans, & &1.content)
      assert "[INFO]" in contents
      assert "User login successful" in contents
      assert "123" in contents
    end
  end

  describe "Stage 2: Logfmt Parser" do
    test "parses key-value logfmt log in-place" do
      logfmt = ~s(ts="2026-06-08 12:00:00" level=info msg="User login" user_id=42 duration=15ms)
      {spans, is_error} = LogFormatter.format_line_with_meta(logfmt)

      refute is_error
      contents = Enum.map(spans, & &1.content)
      assert "ts=" in contents
      assert "2026-06-08 12:00:00" in contents
      assert "[INFO]" in contents
      assert "User login" in contents
      assert "42" in contents
      assert "15ms" in contents
    end

    test "flags error logfmt based on status 500 or error level" do
      logfmt = ~s(level=error msg="Internal error" status=500)
      {_spans, is_error} = LogFormatter.format_line_with_meta(logfmt)

      assert is_error
    end
  end

  describe "Stage 4: Sub-Highlighter" do
    test "highlights HTTP method, path, status, duration, IP, and UUID" do
      line = "GET /api/v1/checkout 200 120ms 192.168.1.1 550e8400-e29b-44d4-a716-446655440000"
      spans = LogFormatter.sub_highlight(line)

      contents = Enum.map(spans, & &1.content)
      assert "GET" in contents
      assert "200" in contents
      assert "120ms" in contents
      assert "192.168.1.1" in contents
      assert "550e8400-e29b-44d4-a716-446655440000" in contents

      get_span = Enum.find(spans, &(&1.content == "GET"))
      assert get_span.style.fg == :blue
      assert :bold in get_span.style.modifiers

      status_span = Enum.find(spans, &(&1.content == "200"))
      assert status_span.style.fg == :green

      dur_span = Enum.find(spans, &(&1.content == "120ms"))
      assert dur_span.style.fg == :cyan

      ip_span = Enum.find(spans, &(&1.content == "192.168.1.1"))
      assert ip_span.style.fg == :magenta

      uuid_span = Enum.find(spans, &(&1.content == "550e8400-e29b-44d4-a716-446655440000"))
      assert uuid_span.style.fg == :dark_gray
    end

    test "highlights HTTP error status codes (4xx yellow, 5xx red bold)" do
      spans_404 = LogFormatter.sub_highlight("GET /missing 404")
      span_404 = Enum.find(spans_404, &(&1.content == "404"))
      assert span_404.style.fg == :yellow

      spans_500 = LogFormatter.sub_highlight("POST /crash 500")
      span_500 = Enum.find(spans_500, &(&1.content == "500"))
      assert span_500.style.fg == :red
      assert :bold in span_500.style.modifiers
    end

    test "highlights all IP variants (IPv4, IPv4 with port, IPv4 CIDR, IPv6, IPv6 CIDR, bracketed IPv6 with port, ::/0, ::)" do
      line = "Conn from 192.168.1.1 172.16.0.1:8080 10.0.0.0/8 2001:db8::1 fe80::/10 [2001:db8::1]:443 ::/0 ::"
      spans = LogFormatter.sub_highlight(line)

      ip_spans = Enum.filter(spans, &(&1.style.fg == :magenta))
      contents = Enum.map(ip_spans, & &1.content)

      assert "192.168.1.1" in contents
      assert "172.16.0.1:8080" in contents
      assert "10.0.0.0/8" in contents
      assert "2001:db8::1" in contents
      assert "fe80::/10" in contents
      assert "[2001:db8::1]:443" in contents
      assert "::/0" in contents
      assert "::" in contents
    end

    test "sanitizes trailing quotes and punctuation from URL and Path tokens" do
      line = ~s("1" => "https://dns.quaywin.com/assets/js/app.js?vsn=d", "file" => "/api/v1/checkout",)
      spans = LogFormatter.sub_highlight(line)

      url_span = Enum.find(spans, &(&1.content == "https://dns.quaywin.com/assets/js/app.js?vsn=d"))
      assert url_span != nil
      assert url_span.style.fg == :magenta

      path_span = Enum.find(spans, &(&1.content == "/api/v1/checkout"))
      assert path_span != nil
      assert path_span.style.fg == :cyan

      reconstituted = Enum.map_join(spans, "", & &1.content)
      assert reconstituted == line
    end

    test "evaluates is_error comprehensively across JSON, Logfmt, General, Exceptions and Panics" do
      assert elem(LogFormatter.format_line_with_meta(~s({"level":"error","msg":"Failed"})), 1) == true
      assert elem(LogFormatter.format_line_with_meta(~s({"status":500,"msg":"Server Error"})), 1) == true
      assert elem(LogFormatter.format_line_with_meta(~s({"status":"502","msg":"Bad Gateway"})), 1) == true
      assert elem(LogFormatter.format_line_with_meta(~s(ts=12:00:00 level=warn err="connection refused")), 1) == true
      assert elem(LogFormatter.format_line_with_meta(~s(ts=12:00:00 status=503 msg="Service Unavailable")), 1) == true
      assert elem(LogFormatter.format_line_with_meta("2026-08-04 10:00:00 [info] GET /checkout 500 120ms"), 1) == true
      assert elem(LogFormatter.format_line_with_meta("2026-08-04 10:00:00 [info] ** (RuntimeError) crash"), 1) == true
      assert elem(LogFormatter.format_line_with_meta("panic: runtime error: index out of range"), 1) == true

      refute elem(LogFormatter.format_line_with_meta("2026-08-04 10:00:00 [info] GET /checkout 200 15ms"), 1)
    end
  end
end
