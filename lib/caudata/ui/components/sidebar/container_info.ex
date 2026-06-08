defmodule Caudata.UI.Components.Sidebar.ContainerInfo do
  @moduledoc """
  Renders Box 3: Container details (image, status, CPU, RAM) component.
  """
  alias ExRatatui.Style
  alias ExRatatui.Text.Line
  alias ExRatatui.Text.Span
  alias ExRatatui.Widgets.Block
  alias ExRatatui.Widgets.Paragraph

  def render(state, box_area) do
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

          image_text =
            if String.length(container.image) > 26 do
              String.slice(container.image, 0..23) <> "..."
            else
              container.image
            end

          status_text = container.status || container.state || "unknown"
          status_color = if is_running, do: :green, else: :red

          base_lines = [
            Line.new([
              Span.new(" Name:   ", style: %Style{fg: :dark_gray}),
              Span.new(container.name, style: %Style{fg: :white, modifiers: [:bold]})
            ]),
            Line.new([
              Span.new(" Status: ", style: %Style{fg: :dark_gray}),
              Span.new(status_text, style: %Style{fg: status_color})
            ]),
            Line.new([
              Span.new(" Image:  ", style: %Style{fg: :dark_gray}),
              Span.new(image_text, style: %Style{fg: :cyan})
            ])
          ]

          cpu_lines =
            if Map.has_key?(container, :cpu_text) do
              [
                Line.new([
                  Span.new(" CPU:    ", style: %Style{fg: :dark_gray}),
                  Span.new(container.cpu_text, style: %Style{fg: :yellow})
                ])
              ]
            else
              []
            end

          ram_lines =
            if Map.has_key?(container, :ram_text) do
              [
                Line.new([
                  Span.new(" RAM:    ", style: %Style{fg: :dark_gray}),
                  Span.new(container.ram_text, style: %Style{fg: :yellow})
                ])
              ]
            else
              []
            end

          base_lines ++ cpu_lines ++ ram_lines
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
