defmodule Caudata.UI.LogFormatter do
  @moduledoc """
  Parses raw log strings and converts them into structured `ExRatatui.Text.Span` lists
  with appropriate styling based on log levels and patterns.
  """
  alias ExRatatui.Style
  alias ExRatatui.Text.Span

  @log_regex ~r/^(?:(?=\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}|\d{2}:\d{2}:\d{2}|\[[a-zA-Z0-9_-]+\]|\b(?:info|warn|warning|error|err|debug|fatal|trace|critical|crit|emerg|emergency|stderr|fail|failure)\b)(?:(?<ts>\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:?\d{2})?|\d{2}:\d{2}:\d{2}(?:\.\d+)?)\s)?(?:(?:\[(?<bracket_lvl>[a-zA-Z0-9_-]+)\]|(?<colon_lvl>\b(?:info|warn|warning|error|err|debug|fatal|trace|critical|crit|emerg|emergency|stderr|fail|failure)\b):|(?<bare_lvl>\b(?:info|warn|warning|error|err|debug|fatal|trace|critical|crit|emerg|emergency|stderr|fail|failure)\b))\s?)?)?(?<msg>.*)$/i

  @doc """
  Formats a single log line into a list of spans.
  """
  def format_line(line) do
    case Regex.named_captures(@log_regex, line) do
      %{
        "ts" => ts,
        "bracket_lvl" => bracket_lvl,
        "colon_lvl" => colon_lvl,
        "bare_lvl" => bare_lvl,
        "msg" => msg
      } ->
        {_level, lvl_style} =
          cond do
            bracket_lvl != "" -> {bracket_lvl, level_style(bracket_lvl)}
            colon_lvl != "" -> {colon_lvl, level_style(colon_lvl)}
            bare_lvl != "" -> {bare_lvl, level_style(bare_lvl)}
            true -> {nil, nil}
          end

        msg_style = %Style{fg: :white}

        spans = []

        spans =
          if ts != "" do
            spans ++ [Span.new(ts <> " ", style: %Style{fg: :dark_gray})]
          else
            spans
          end

        spans =
          cond do
            bracket_lvl != "" ->
              spans ++
                [Span.new("[" <> bracket_lvl <> "] ", style: %{lvl_style | modifiers: [:bold]})]

            colon_lvl != "" ->
              spans ++ [Span.new(colon_lvl <> ": ", style: %{lvl_style | modifiers: [:bold]})]

            bare_lvl != "" ->
              spans ++ [Span.new(bare_lvl <> " ", style: %{lvl_style | modifiers: [:bold]})]

            true ->
              spans
          end

        spans ++ [Span.new(msg, style: msg_style)]

      nil ->
        [Span.new(line, style: %Style{fg: :white})]
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
end
