defmodule Caudata.UI.Components.SettingsModal.ServersTab do
  @moduledoc """
  Renders the 'Servers' configuration tab in SettingsModal.
  """
  alias ExRatatui.Style
  alias ExRatatui.Text.Line
  alias ExRatatui.Text.Span

  @doc """
  Renders the servers list tab content.
  """
  def render(state) do
    if Enum.empty?(state.profiles) do
      [
        Line.new([]),
        Line.new([
          Span.new("  No servers configured. Add one first.", style: %Style{fg: :yellow})
        ])
      ]
    else
      display_rows_limit = max(3, div(state.height * 90, 100) - 9)

      start_row =
        if state.settings_selected_profile_idx >= display_rows_limit,
          do: state.settings_selected_profile_idx - display_rows_limit + 1,
          else: 0

      rows =
        state.profiles
        |> Enum.with_index()
        |> Enum.slice(start_row, display_rows_limit)
        |> Enum.map(fn {p, idx} ->
          selected = idx == state.settings_selected_profile_idx
          cursor = if selected, do: " > ", else: "   "
          color = if selected, do: :green, else: :white

          enabled = Map.get(p, :enabled, true)
          checkbox = if enabled, do: "[X] ", else: "[ ] "
          checkbox_color = if enabled, do: :green, else: :red

          status =
            if enabled do
              Map.get(state.statuses, p.id, :disconnected)
            else
              :disabled
            end

          status_color = Caudata.UI.ViewHelper.status_color(status)

          status_icon =
            case status do
              :connected -> "● "
              :connecting -> "◌ "
              :disabled -> "⊘ "
              _ -> "○ "
            end

          conn_info = "(#{p.user || "root"}@#{p.host_name}:#{p.port})"

          max_id_len = max(15, div(state.width, 4))
          id_padded = String.pad_trailing(p.id, max_id_len)

          Line.new([
            Span.new(cursor, style: %Style{fg: :green}),
            Span.new(checkbox, style: %Style{fg: checkbox_color}),
            Span.new(status_icon, style: %Style{fg: status_color}),
            Span.new(id_padded,
              style: %Style{fg: color, modifiers: if(selected, do: [:bold], else: [])}
            ),
            Span.new(conn_info, style: %Style{fg: :dark_gray})
          ])
        end)

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

      [Line.new([]) | rows] ++ status_lines
    end
  end
end
