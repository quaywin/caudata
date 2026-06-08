defmodule Caudata.UI.Components.Footer do
  @moduledoc """
  Renders the shortcut guidelines and status stats at the bottom of the interface.
  """
  alias ExRatatui.Style
  alias ExRatatui.Text.Line
  alias ExRatatui.Text.Span
  alias ExRatatui.Widgets.Paragraph

  @doc """
  Renders the footer paragraph displaying shortcuts dynamically based on the current state.
  """
  def render(state) do
    footer_spans =
      cond do
        state.modal_visible ->
          case state.modal_type do
            :select_ssh ->
              [
                Span.new(" Shortcuts: "),
                Span.new("[⇅/j/k] Navigate ", style: %Style{fg: :yellow}),
                Span.new("[Enter] Select ", style: %Style{fg: :green}),
                Span.new("[Esc] Cancel ", style: %Style{fg: :red})
              ]

            :manual_input ->
              [
                Span.new(" Shortcuts: "),
                Span.new("[⇅] Navigate fields ", style: %Style{fg: :yellow}),
                Span.new("[Type] Edit text ", style: %Style{fg: :cyan}),
                Span.new("[Enter] Submit/Action ", style: %Style{fg: :green}),
                Span.new("[Esc] Close ", style: %Style{fg: :red})
              ]

            :settings ->
              if state.settings_input_active do
                [
                  Span.new(" Shortcuts: "),
                  Span.new("[Type] Input path ", style: %Style{fg: :cyan}),
                  Span.new("[Enter] Validate & Save ", style: %Style{fg: :green}),
                  Span.new("[Esc] Cancel ", style: %Style{fg: :red})
                ]
              else
                tab_specific_shortcuts =
                  case state.settings_focus do
                    :servers ->
                      [
                        Span.new("[⇅/j/k] Select Server ", style: %Style{fg: :cyan}),
                        Span.new("[Space] Toggle Server ", style: %Style{fg: :green}),
                        Span.new("[d/Backspace] Delete Server ", style: %Style{fg: :red})
                      ]

                    :containers ->
                      [
                        Span.new("[⇅/j/k] Select Container ", style: %Style{fg: :cyan}),
                        Span.new("[Space] Toggle Container ", style: %Style{fg: :green})
                      ]

                    :custom_logs ->
                      [
                        Span.new("[⇅/j/k] Select Path ", style: %Style{fg: :cyan}),
                        Span.new("[a] Add Path ", style: %Style{fg: :green}),
                        Span.new("[d/Backspace] Delete Path ", style: %Style{fg: :red})
                      ]
                  end

                [
                  Span.new(" Shortcuts: "),
                  Span.new("[Tab/⇅/⇄] Switch Tab ", style: %Style{fg: :yellow})
                ] ++
                  tab_specific_shortcuts ++
                  [
                    Span.new("[Esc] Close ", style: %Style{fg: :red})
                  ]
              end
          end

        state.mode == :searching ->
          [
            Span.new(" Shortcuts: "),
            Span.new("[Esc] Cancel ", style: %Style{fg: :yellow}),
            Span.new("[Enter] Apply ", style: %Style{fg: :green})
          ]

        true ->
          selected_profile = Enum.find(state.profiles, &(&1.id == state.selected_profile_id))

          size =
            if selected_profile, do: Map.get(state.buffer_sizes, selected_profile.id, 0), else: 0

          drops =
            if selected_profile, do: Map.get(state.drop_counts, selected_profile.id, 0), else: 0

          base_shortcuts =
            if Map.get(state, :logs_full_screen, false) do
              [
                Span.new(" Shortcuts: "),
                Span.new("[q] Quit "),
                Span.new("[f/Esc] Normal Screen ", style: %Style{fg: :yellow}),
                Span.new("[/] Filter "),
                Span.new("[j/k] Scroll Logs ")
              ]
            else
              [
                Span.new(" Shortcuts: "),
                Span.new("[q] Quit "),
                Span.new("[Enter] Connect "),
                Span.new("[a] Add Server "),
                Span.new("[f] Fullscreen ", style: %Style{fg: :yellow}),
                Span.new("[/] Filter "),
                Span.new("[⇅] Navigate | [j/k] Scroll Logs ")
              ]
            end

          base_shortcuts =
            if Map.get(state, :update_available) do
              base_shortcuts ++
                [
                  Span.new(
                    " | Update v#{state.update_available} available! Run 'caudata upgrade'",
                    style: %Style{fg: :green}
                  )
                ]
            else
              base_shortcuts
            end

          if size > 0 do
            base_shortcuts ++ [Span.new(" | Size: #{size}/1000 | Drops: #{drops}")]
          else
            base_shortcuts
          end
      end

    %Paragraph{
      text: [Line.new(footer_spans)]
    }
  end
end
