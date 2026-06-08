defmodule Caudata.UI.Components.Sidebar.ServerMetrics do
  @moduledoc """
  Renders Box 4: Server Metrics component.
  """
  alias ExRatatui.Style
  alias ExRatatui.Text.Line
  alias ExRatatui.Text.Span
  alias ExRatatui.Widgets.Block
  alias ExRatatui.Widgets.Paragraph

  alias Caudata.UI.ViewHelper

  def render(state, box_area) do
    selected_profile = Enum.find(state.profiles, &(&1.id == state.selected_profile_id))

    server_metrics_lines =
      case selected_profile do
        nil ->
          [
            Line.new([Span.new("  No server selected")]),
            Line.new([Span.new("  Add/Select a server in Box 1")])
          ]

        profile ->
          status =
            if Map.get(profile, :enabled, true) do
              Map.get(state.statuses, profile.id, :disconnected)
            else
              :disabled
            end

          metrics = Map.get(state.metrics, profile.id)

          case metrics do
            nil ->
              msg =
                case status do
                  :disabled -> "  Disabled"
                  :connecting -> "  Connecting..."
                  :disconnected -> "  Disconnected"
                  :connected -> "  Connecting..."
                end

              status_color = ViewHelper.status_color(status)
              [Line.new([Span.new(msg, style: %Style{fg: status_color, modifiers: [:bold]})])]

            {cpu, ram_pct, used_ram, total_ram, disk_pct, used_disk, total_disk} ->
              [
                draw_cpu_bar(cpu),
                draw_ram_bar(ram_pct, used_ram, total_ram),
                draw_disk_bar(disk_pct, used_disk, total_disk)
              ]
          end
      end

    widget = %Paragraph{
      text: server_metrics_lines,
      block: %Block{
        title: " Server Metrics ",
        borders: [:all],
        border_type: :rounded
      }
    }

    {widget, box_area}
  end

  # Draws CPU progress bar
  defp draw_cpu_bar(pct) do
    filled = div(pct * 10, 100)
    empty = 10 - filled

    bar_str = "[" <> String.duplicate("|", filled) <> String.duplicate(" ", empty) <> "]"
    pct_str = String.pad_leading("#{pct}%", 4)

    Line.new([
      Span.new(" CPU:    ", style: %Style{fg: :dark_gray}),
      Span.new(bar_str, style: %Style{fg: :cyan}),
      Span.new(" " <> pct_str, style: %Style{fg: :yellow})
    ])
  end

  # Draws RAM progress bar with used/total
  defp draw_ram_bar(pct, used, total) do
    filled = div(pct * 10, 100)
    empty = 10 - filled

    bar_str = "[" <> String.duplicate("|", filled) <> String.duplicate(" ", empty) <> "]"
    val_str = " #{used}G / #{total}G"

    Line.new([
      Span.new(" RAM:    ", style: %Style{fg: :dark_gray}),
      Span.new(bar_str, style: %Style{fg: :cyan}),
      Span.new(val_str, style: %Style{fg: :yellow})
    ])
  end

  # Draws Disk progress bar with used/total
  defp draw_disk_bar(pct, used, total) do
    filled = div(pct * 10, 100)
    empty = 10 - filled

    bar_str = "[" <> String.duplicate("|", filled) <> String.duplicate(" ", empty) <> "]"
    val_str = " #{used}G / #{total}G"

    Line.new([
      Span.new(" Disk:   ", style: %Style{fg: :dark_gray}),
      Span.new(bar_str, style: %Style{fg: :cyan}),
      Span.new(val_str, style: %Style{fg: :yellow})
    ])
  end
end
