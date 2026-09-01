defmodule Caudata.UI.Components.SettingsModal.CustomLogsTab do
  @moduledoc """
  Renders the 'Custom Logs' configuration tab in SettingsModal.
  """
  alias ExRatatui.Style
  alias ExRatatui.Text.Line
  alias ExRatatui.Text.Span

  @doc """
  Renders custom log file paths list for the selected profile.
  """
  def render(_state, nil, _custom_logs) do
    [
      Line.new([]),
      Line.new([Span.new("  No server selected.", style: %Style{fg: :yellow})])
    ]
  end

  def render(state, profile, custom_logs) do
    info_line =
      Line.new([
        Span.new("  Server: ", style: %Style{fg: :cyan}),
        Span.new(profile.id, style: %Style{fg: :yellow})
      ])

    list_rows =
      if Enum.empty?(custom_logs) do
        [
          Line.new([]),
          Line.new([
            Span.new("  No custom logs configured. Press 'a' to add a path.",
              style: %Style{fg: :dark_gray}
            )
          ])
        ]
      else
        display_rows_limit = max(2, div(state.height * 90, 100) - 11)
        start_row = Caudata.UI.ViewHelper.scroll_start_row(state.settings_custom_log_idx, display_rows_limit)

        custom_logs
        |> Enum.with_index()
        |> Enum.slice(start_row, display_rows_limit)
        |> Enum.map(fn {path, idx} ->
          selected = idx == state.settings_custom_log_idx
          cursor = if selected, do: " > ", else: "   "
          color = if selected, do: :green, else: :white

          container_id = "file:#{path}"

          enabled =
            container_id not in profile.disabled_containers and
              path not in profile.disabled_containers

          checkbox = if enabled, do: "[X] ", else: "[ ] "

          Line.new([
            Span.new(cursor, style: %Style{fg: :green}),
            Span.new(checkbox, style: %Style{fg: if(enabled, do: :green, else: :red)}),
            Span.new(path,
              style: %Style{fg: color, modifiers: if(selected, do: [:bold], else: [])}
            )
          ])
        end)
      end

    input_lines =
      if state.settings_input_active do
        [
          Line.new([]),
          Line.new([
            Span.new("  ┌─ Enter new log path ─────────────────────────────────┐",
              style: %Style{fg: :cyan}
            )
          ]),
          Line.new([
            Span.new("  │ ", style: %Style{fg: :cyan}),
            Span.new(state.settings_input_value <> "█", style: %Style{fg: :green})
          ]),
          Line.new([
            Span.new("  └──────────────────────────────────────────────────────┘",
              style: %Style{fg: :cyan}
            )
          ])
        ]
      else
        []
      end

    status_lines =
      if state.settings_status_msg do
        color =
          if String.starts_with?(state.settings_status_msg, "Error"), do: :red, else: :yellow

        [
          Line.new([]),
          Line.new([
            Span.new("  ℹ ", style: %Style{fg: color}),
            Span.new(state.settings_status_msg, style: %Style{fg: color})
          ])
        ]
      else
        []
      end

    [info_line, Line.new([]) | list_rows] ++ input_lines ++ status_lines
  end
end
