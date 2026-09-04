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
          cond do
            Map.get(profile, :is_local, false) ->
              case status do
                :connected -> "■"
                _ -> "□"
              end

            true ->
              case status do
                :connected -> "●"
                :connecting -> "◌"
                :disabled -> "⊘"
                _ -> "○"
              end
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
          Span.new(" ", style: style),
          Span.new(profile.id, style: style)
        ])
      end)

    active_panel = Map.get(state, :active_panel, :sidebar)

    border_color =
      if active_panel == :sidebar and focus == :servers do
        :cyan
      else
        :dark_gray
      end

    selected_idx = Enum.find_index(state.profiles, &(&1.id == state.selected_profile_id))
    n = length(state.profiles)
    inner_height = max(0, box_area.height - 2)

    scroll_y = ViewHelper.centered_scroll_y(selected_idx, n, inner_height)

    widget = %Paragraph{
      text: server_rows,
      scroll: {scroll_y, 0},
      block: %Block{
        title: if(active_panel == :sidebar and focus == :servers, do: " [1] Servers [ACTIVE] ", else: " [1] Servers "),
        borders: [:all],
        border_type: :rounded,
        border_style: %Style{fg: border_color}
      }
    }

    if n > inner_height do
      max_scroll = max(1, n - inner_height)

      scrollbar_widget = %ExRatatui.Widgets.Scrollbar{
        orientation: :vertical_right,
        content_length: max_scroll,
        position: min(scroll_y, max_scroll),
        thumb_style: %Style{fg: :cyan},
        track_style: %Style{fg: :dark_gray}
      }

      [{widget, box_area}, {scrollbar_widget, box_area}]
    else
      {widget, box_area}
    end
  end
end
