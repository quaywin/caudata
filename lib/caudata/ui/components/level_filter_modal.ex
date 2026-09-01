defmodule Caudata.UI.Components.LevelFilterModal do
  @moduledoc """
  Renders popup modal for filtering logs by minimum severity level matching the hl standard.
  """
  alias ExRatatui.Style
  alias ExRatatui.Text.Line
  alias ExRatatui.Text.Span
  alias ExRatatui.Widgets.Block
  alias ExRatatui.Widgets.Paragraph
  alias ExRatatui.Widgets.Popup

  @levels [
    {"0", "All Logs (Default)", :all, :white, "Show all log streams"},
    {"1", "Info only (INFO)", :info, :green, "Show INFO logs only"},
    {"2", "Warnings only (WARN)", :warn, :yellow, "Show WARNING logs only"},
    {"3", "Errors & Fatal (ERROR)", :error, :red, "Show ERROR and FATAL logs only"}
  ]

  def levels, do: @levels

  def get_level_by_index(idx) when is_integer(idx) and idx >= 0 and idx < length(@levels) do
    {_key, _label, level_atom, _color, _desc} = Enum.at(@levels, idx)
    level_atom
  end

  def get_level_by_index(_), do: :all

  def get_level_by_key(key) when is_binary(key) do
    case Enum.find(@levels, fn {k, _label, _atom, _color, _desc} -> k == key end) do
      {_k, _label, level_atom, _color, _desc} -> level_atom
      _ -> nil
    end
  end

  def get_index_for_level(level) do
    Enum.find_index(@levels, fn {_k, _label, atom, _color, _desc} -> atom == level end) || 0
  end

  def render(state) do
    selected_idx = Map.get(state, :level_filter_modal_selected_index, 0)
    current_active_level = Map.get(state, :log_level_filter, :all)

    option_lines =
      Enum.with_index(@levels)
      |> Enum.map(fn {{key, label, level_atom, color, _desc}, idx} ->
        is_cursor = selected_idx == idx
        is_active = current_active_level == level_atom

        prefix = if is_cursor, do: "> ", else: "  "
        active_badge = if is_active, do: " [ACTIVE] ✓", else: ""

        item_style =
          if is_cursor do
            %Style{fg: :cyan, modifiers: [:bold]}
          else
            %Style{fg: :white}
          end

        badge_style = %Style{fg: color, modifiers: [:bold]}
        active_style = %Style{fg: :green, modifiers: [:bold]}

        Line.new([
          Span.new(prefix, style: item_style),
          Span.new("[#{key}] ", style: %Style{fg: :yellow, modifiers: [:bold]}),
          Span.new(label, style: badge_style),
          Span.new(active_badge, style: active_style)
        ])
      end)

    popup_inner_width = max(10, div(Map.get(state, :width, 80) * 58, 100) - 4)

    header_lines = [
      Line.new([
        Span.new("Filter Logs by Minimum Severity Level (hl standard):", style: %Style{fg: :cyan, modifiers: [:bold]})
      ]),
      Line.new([
        Span.new(String.duplicate("─", popup_inner_width), style: %Style{fg: :dark_gray})
      ])
    ]

    footer_lines = [
      Line.new([
        Span.new(String.duplicate("─", popup_inner_width), style: %Style{fg: :dark_gray})
      ]),
      Line.new([
        Span.new("↑/↓ / j/k: navigate • 0-3 / Enter: select • Esc: close", style: %Style{fg: :dark_gray})
      ])
    ]

    popup_widget = %Popup{
      content: %Paragraph{
        text: header_lines ++ option_lines ++ footer_lines
      },
      block: %Block{
        title: " 📊 Filter by Log Level [l] ",
        borders: [:all],
        border_type: :rounded,
        border_style: %Style{fg: :cyan}
      },
      percent_width: 58,
      percent_height: 40
    }

    [popup_widget]
  end
end
