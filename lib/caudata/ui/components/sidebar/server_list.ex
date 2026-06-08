defmodule Caudata.UI.Components.Sidebar.ServerList do
  @moduledoc """
  Renders the Box 1: Servers List component of the sidebar.
  """
  alias ExRatatui.Style
  alias ExRatatui.Text.Line
  alias ExRatatui.Text.Span
  alias ExRatatui.Widgets.Block
  alias ExRatatui.Widgets.Paragraph

  alias Caudata.UI.ViewHelper

  def render(state, box_area) do
    focus = Map.get(state, :sidebar_focus, :servers)

    server_rows =
      Enum.map(state.profiles, fn profile ->
        status =
          if Map.get(profile, :enabled, true) do
            Map.get(state.statuses, profile.id, :disconnected)
          else
            :disabled
          end

        status_color = ViewHelper.status_color(status)

        status_icon =
          case status do
            :connected -> "● "
            :connecting -> "◌ "
            :disabled -> "⊘ "
            _ -> "○ "
          end

        is_selected = state.selected_profile_id == profile.id
        prefix = if is_selected, do: "> ", else: "  "

        fg_color =
          cond do
            is_selected && focus == :servers -> :green
            is_selected -> :white
            status == :disabled -> :dark_gray
            true -> :white
          end

        style = %Style{
          fg: fg_color,
          modifiers: if(is_selected, do: [:bold], else: [])
        }

        Line.new([
          Span.new(prefix, style: style),
          Span.new(status_icon, style: %Style{fg: status_color}),
          Span.new(profile.id, style: style)
        ])
      end)

    border_color = if focus == :servers, do: :green, else: :white

    selected_idx = Enum.find_index(state.profiles, &(&1.id == state.selected_profile_id))
    n = length(state.profiles)
    inner_height = max(0, box_area.height - 2)

    scroll_y =
      cond do
        n <= inner_height -> 0
        is_nil(selected_idx) -> 0
        true -> max(0, min(selected_idx - div(inner_height, 2), n - inner_height))
      end

    widget = %Paragraph{
      text: server_rows,
      scroll: {scroll_y, 0},
      block: %Block{
        title: " Servers ",
        borders: [:all],
        border_type: :rounded,
        border_style: %Style{fg: border_color}
      }
    }

    {widget, box_area}
  end
end
