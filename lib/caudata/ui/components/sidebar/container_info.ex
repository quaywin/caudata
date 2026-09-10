defmodule Caudata.UI.Components.Sidebar.ContainerInfo do
  @moduledoc """
  Renders Box 3: Container details (image, status, CPU, RAM) component.
  """
  alias ExRatatui.Style
  alias ExRatatui.Text.Line
  alias ExRatatui.Text.Span
  alias ExRatatui.Widgets.Block
  alias ExRatatui.Widgets.Paragraph
  alias Caudata.UI.ViewHelper

  def render(state, box_area) do
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

    selected_container =
      if selected_profile && state.selected_container_id do
        Enum.find(
          enabled_containers,
          &(to_string(&1.id) == to_string(state.selected_container_id))
        )
      end

    container_info_lines =
      case selected_container do
        nil ->
          [
            Line.new([Span.new("  No active container")]),
            Line.new([Span.new("  Select a container in Box 2")])
          ]

        container ->
          is_running = Map.get(container, :state) == "running"

          status_text = container.status || container.state || "unknown"
          status_color = if is_running, do: :green, else: :red

          cpu_text = Map.get(container, :cpu_text) || "--"
          ram_text = Map.get(container, :ram_text) || "--"

          net_line =
            if is_integer(container[:net_rx_speed]) and is_integer(container[:net_tx_speed]) do
              rx_str = ViewHelper.format_speed(container.net_rx_speed)
              tx_str = ViewHelper.format_speed(container.net_tx_speed)

              Line.new([
                Span.new(" Net:    ", style: %Style{fg: :dark_gray}),
                Span.new("▼ ", style: %Style{fg: :green}),
                Span.new(rx_str, style: %Style{fg: :yellow}),
                Span.new("  ▲ ", style: %Style{fg: :cyan}),
                Span.new(tx_str, style: %Style{fg: :yellow})
              ])
            else
              Line.new([
                Span.new(" Net:    ", style: %Style{fg: :dark_gray}),
                Span.new("--", style: %Style{fg: :yellow})
              ])
            end

          [
            Line.new([
              Span.new(" Status: ", style: %Style{fg: :dark_gray}),
              Span.new(status_text, style: %Style{fg: status_color})
            ]),
            Line.new([
              Span.new(" CPU:    ", style: %Style{fg: :dark_gray}),
              Span.new(cpu_text, style: %Style{fg: :yellow})
            ]),
            Line.new([
              Span.new(" RAM:    ", style: %Style{fg: :dark_gray}),
              Span.new(ram_text, style: %Style{fg: :yellow})
            ]),
            net_line
          ]
      end

    widget = %Paragraph{
      text: container_info_lines,
      block: %Block{
        title: " Container Info ",
        borders: [:all],
        border_type: :rounded
      }
    }

    {widget, box_area}
  end
end
