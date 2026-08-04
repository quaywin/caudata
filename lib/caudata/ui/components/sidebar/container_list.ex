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
        Caudata.UI.ViewHelper.get_enabled_containers(
          selected_profile,
          Map.get(state.containers, selected_profile.id, [])
        )
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
            is_selected = to_string(state.selected_container_id) == to_string(container.id)
            prefix = if is_selected, do: "> ", else: "  "

            is_file =
              container.image == "file" or String.starts_with?(to_string(container.id), "file:")

            container_image = Map.get(container, :image)

            is_systemd =
              container_image == "systemd" or
                String.starts_with?(to_string(container.id), "systemd:")

            is_launchd =
              container_image == "launchd" or
                String.starts_with?(to_string(container.id), "launchd:")

            is_running =
              Map.get(container, :state) == "running" or is_file or is_systemd or is_launchd

            {icon, icon_color} =
              cond do
                is_file -> {"📄 ", :yellow}
                is_systemd -> {"⚙ ", :magenta}
                is_launchd -> {"⚙ ", :light_blue}
                is_running -> {"🐳 ", :cyan}
                true -> {"🔴 ", :red}
              end

            fg_color =
              cond do
                is_selected && focus == :containers -> :green
                is_selected -> :white
                not is_running -> :dark_gray
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

    active_panel = Map.get(state, :active_panel, :sidebar)

    border_color =
      cond do
        active_panel == :sidebar and focus == :containers -> :cyan
        active_panel == :sidebar -> :white
        true -> :dark_gray
      end

    selected_idx =
      Enum.find_index(
        enabled_containers,
        &(to_string(&1.id) == to_string(state.selected_container_id))
      )

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
        title: if(active_panel == :sidebar and focus == :containers, do: " Containers / Services [ACTIVE] ", else: " Containers / Services "),
        borders: [:all],
        border_type: :rounded,
        border_style: %Style{fg: border_color}
      }
    }

    {widget, box_area}
  end
end
