defmodule Caudata.UI.Components.HelpModal do
  @moduledoc """
  Renders a popup modal displaying all available keyboard shortcuts categorized by section.
  """
  alias ExRatatui.Style
  alias ExRatatui.Text.Line
  alias ExRatatui.Text.Span
  alias ExRatatui.Widgets.Block
  alias ExRatatui.Widgets.Paragraph
  alias ExRatatui.Widgets.Popup

  @sections [
    {"🌐 Global Shortcuts", [
      {"1 / 2 / 3", "Jump focus to Servers (1), Containers (2), or Logs (3)"},
      {"h / l  or  ← / →", "Cycle active focus (1 ↔ 2 ↔ 3)"},
      {"Tab", "Cycle active panel focus (1 → 2 → 3 → 1)"},
      {"a / A", "Open Add Server connection modal"},
      {"s / S", "Open Global Settings modal"},
      {"f / F", "Toggle Fullscreen Logs view"},
      {"t / T", "Toggle log timestamps"},
      {"? ", "Toggle this Help modal"},
      {"q / Ctrl+C", "Quit Caudata"}
    ]},
    {"📁 Servers (Panel 1)", [
      {"j / k  or  ↑ / ↓", "Navigate server list"},
      {"Enter", "Connect / Refresh server"}
    ]},
    {"📦 Containers & Services (Panel 2)", [
      {"j / k  or  ↑ / ↓", "Navigate container / service list"},
      {"Enter / m", "Open Docker container actions (Start/Stop/Restart/Kill/Inspect)"},
      {"Space", "Toggle log stream on/off"}
    ]},
    {"📜 Logs Pane (Panel 3)", [
      {"j / k  or  ↑ / ↓", "Scroll logs down / up (with auto-acceleration)"},
      {"g / G", "Jump to Top (g) or Bottom (G) of logs"},
      {"PageUp / PageDown", "Scroll logs page-by-page"},
      {"/", "Enter Live Regex Filter search mode"},
      {"v / V", "Enter Visual Selection mode (extend selection with j/k)"},
      {"y / Y", "Copy all displayed logs (or selected lines) to clipboard"},
      {"Esc", "Clear active filter regex / exit visual mode"}
    ]},
    {"✏️ Form & Modal Shortcuts", [
      {"Tab / Shift+Tab", "Navigate next / previous form field"},
      {"Enter", "Submit form / Confirm modal action"},
      {"1 - 6", "Quick-select action number in container action modal"},
      {"y / n", "Confirm (y) or Cancel (n) destructive confirmation dialogs"},
      {"Esc / q", "Close active modal"}
    ]}
  ]

  @doc """
  Renders the help modal popup widget.
  """
  def render(state) do
    scroll_y = Map.get(state, :help_modal_scroll_y, 0)

    lines =
      Enum.flat_map(@sections, fn {header, shortcuts} ->
        header_line = Line.new([Span.new(header, style: %Style{fg: :cyan, modifiers: [:bold]})])

        shortcut_lines =
          Enum.map(shortcuts, fn {keys, desc} ->
            pad_keys = String.pad_trailing(keys, 22)

            Line.new([
              Span.new("  " <> pad_keys, style: %Style{fg: :yellow, modifiers: [:bold]}),
              Span.new(desc, style: %Style{fg: :white})
            ])
          end)

        [header_line | shortcut_lines] ++ [Line.new([])]
      end)

    header_bar = [
      Line.new([
        Span.new(" Caudata Keyboard Reference — Lazygit-Style Navigation",
          style: %Style{fg: :green, modifiers: [:bold]}
        )
      ]),
      Line.new([
        Span.new(String.duplicate("─", max(1, state.width - 15)), style: %Style{fg: :dark_gray})
      ]),
      Line.new([])
    ]

    footer_bar = [
      Line.new([
        Span.new(" Press ", style: %Style{fg: :dark_gray}),
        Span.new("[Esc]", style: %Style{fg: :red, modifiers: [:bold]}),
        Span.new(" or ", style: %Style{fg: :dark_gray}),
        Span.new("[q]", style: %Style{fg: :red, modifiers: [:bold]}),
        Span.new(" or ", style: %Style{fg: :dark_gray}),
        Span.new("[?]", style: %Style{fg: :yellow, modifiers: [:bold]}),
        Span.new(" to close help menu ", style: %Style{fg: :dark_gray})
      ])
    ]

    total_content_lines = header_bar ++ lines ++ footer_bar

    popup_widget = %Popup{
      content: %Paragraph{
        text: total_content_lines,
        scroll: {scroll_y, 0}
      },
      block: %Block{
        title: " ❓ Keybinding Help Reference ",
        borders: [:all],
        border_type: :rounded
      },
      percent_width: 80,
      percent_height: 80
    }

    [popup_widget]
  end

  @doc """
  Handles key events when the help modal is active.
  """
  def handle_key(key, key_data, model) do
    norm_key = if key == :char, do: Map.get(key_data, :char), else: key
    scroll_y = Map.get(model, :help_modal_scroll_y, 0)

    case norm_key do
      k when k in [:escape, :esc, "q", "Q", "?"] ->
        {%{model | modal_visible: false, modal_type: :select_ssh}, []}

      k when k in [:down, "j", "J"] ->
        {%{model | help_modal_scroll_y: scroll_y + 1}, []}

      k when k in [:up, "k", "K"] ->
        {%{model | help_modal_scroll_y: max(0, scroll_y - 1)}, []}

      k when k in [:page_down, :pagedown] ->
        {%{model | help_modal_scroll_y: scroll_y + 10}, []}

      k when k in [:page_up, :pageup] ->
        {%{model | help_modal_scroll_y: max(0, scroll_y - 10)}, []}

      "g" ->
        {%{model | help_modal_scroll_y: 0}, []}

      "G" ->
        {%{model | help_modal_scroll_y: 50}, []}

      _ ->
        {model, []}
    end
  end
end
