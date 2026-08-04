defmodule Caudata.UI.Components.SettingsModal.GeneralTab do
  @moduledoc """
  Renders the 'General' global configuration tab in SettingsModal.
  """
  alias ExRatatui.Style
  alias ExRatatui.Text.Line
  alias ExRatatui.Text.Span

  @doc """
  Renders global capacity and settings inputs.
  """
  def render(state) do
    active_idx = state.settings_global_focus_idx || 0

    prefix = if active_idx == 0, do: "> ", else: "  "
    label_color = if active_idx == 0, do: :cyan, else: :white
    value_color = if active_idx == 0, do: :green, else: :white

    value = state.settings_global_capacity || "10000"
    display_value = if active_idx == 0, do: value <> "█", else: value

    form_lines = [
      Line.new([
        Span.new(prefix),
        Span.new("Global Log Capacity (lines):", style: %Style{fg: label_color})
      ]),
      Line.new([
        Span.new("    "),
        Span.new(display_value, style: %Style{fg: value_color})
      ])
    ]

    save_active = active_idx == 1
    cancel_active = active_idx == 2

    buttons_line =
      Line.new([
        Span.new(
          if(save_active,
            do: "> [ Save General Settings ]   ",
            else: "  [ Save General Settings ]   "
          ),
          style: %Style{fg: if(save_active, do: :green, else: :white)}
        ),
        Span.new(if(cancel_active, do: "> [ Cancel ]", else: "  [ Cancel ]"),
          style: %Style{fg: if(cancel_active, do: :red, else: :white)}
        )
      ])

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

    [Line.new([])] ++ form_lines ++ [Line.new([]), buttons_line] ++ status_lines
  end
end
