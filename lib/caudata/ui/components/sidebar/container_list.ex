defmodule Caudata.UI.Components.Sidebar.ContainerList do
  @moduledoc """
  Renders the Box 2: Containers List component of the sidebar.
  """
  alias ExRatatui.Style
  alias ExRatatui.Text.Line
  alias ExRatatui.Text.Span
  alias ExRatatui.Widgets.Block
  alias ExRatatui.Widgets.Paragraph

  def render(state, box_area) do
    focus = Map.get(state, :sidebar_focus, :servers)
    selected_profile = Enum.find(state.profiles, &(&1.id == state.selected_profile_id))

    enabled_containers =
      if selected_profile do
        containers = Map.get(state.containers, selected_profile.id, [])

        Enum.filter(containers, fn c ->
          c.id not in selected_profile.disabled_containers and
            c.name not in selected_profile.disabled_containers
        end)
      else
        []
      end

    container_rows =
      cond do
        is_nil(selected_profile) ->
          [Line.new([Span.new("  No server selected")])]

        enabled_containers == [] ->
          status = Map.get(state.statuses, selected_profile.id, :disconnected)

          if status == :connected do
            [Line.new([Span.new("  No containers found")])]
          else
            [Line.new([Span.new("  (Disconnected)"), Span.new("       ")])]
          end

        true ->
          Enum.map(enabled_containers, fn container ->
            is_selected = state.selected_container_id == container.id
            prefix = if is_selected, do: "> ", else: "  "

            is_file = container.image == "file" or String.starts_with?(container.id, "file:")
            icon = if is_file, do: "📄 ", else: "🐳 "
            icon_color = if is_file, do: :yellow, else: :cyan

            fg_color =
              cond do
                is_selected && focus == :containers -> :green
                is_selected -> :white
                true -> :white
              end

            style = %Style{
              fg: fg_color,
              modifiers: if(is_selected, do: [:bold], else: [])
            }

            Line.new([
              Span.new(prefix, style: style),
              Span.new(icon, style: %Style{fg: icon_color}),
              Span.new(container.name, style: style)
            ])
          end)
      end

    border_color = if focus == :containers, do: :green, else: :white

    selected_idx = Enum.find_index(enabled_containers, &(&1.id == state.selected_container_id))
    n = length(enabled_containers)
    inner_height = max(0, box_area.height - 2)

    scroll_y =
      cond do
        n <= inner_height -> 0
        is_nil(selected_idx) -> 0
        true -> max(0, min(selected_idx - div(inner_height, 2), n - inner_height))
      end

    widget = %Paragraph{
      text: container_rows,
      scroll: {scroll_y, 0},
      block: %Block{
        title: " Containers ",
        borders: [:all],
        border_type: :rounded,
        border_style: %Style{fg: border_color}
      }
    }

    {widget, box_area}
  end
end
