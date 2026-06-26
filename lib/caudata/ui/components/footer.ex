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
                Span.new("[⇅/j/k] Navigate ", style: %Style{fg: :yellow}),
                Span.new("[Enter] Select ", style: %Style{fg: :green}),
                Span.new("[Esc] Cancel ", style: %Style{fg: :red})
              ]

            :manual_input ->
              [
                Span.new("[⇅] Navigate fields  ", style: %Style{fg: :yellow}),
                Span.new("[Type] Edit text ", style: %Style{fg: :cyan}),
                Span.new("[Enter] Submit/Action ", style: %Style{fg: :green}),
                Span.new("[Esc] Close ", style: %Style{fg: :red})
              ]

            :settings ->
              if state.settings_input_active do
                [
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

                    :connection ->
                      [
                        Span.new("[⇅] Navigate fields ", style: %Style{fg: :cyan}),
                        Span.new("[Type] Edit text ", style: %Style{fg: :green})
                      ]

                    :containers ->
                      [
                        Span.new("[⇅/j/k] Select Container ", style: %Style{fg: :cyan}),
                        Span.new("[Space] Toggle Container ", style: %Style{fg: :green})
                      ]

                    :services ->
                      if state.settings_service_search_active do
                        [
                          Span.new("[Type] Filter ", style: %Style{fg: :cyan}),
                          Span.new("[Enter] Apply ", style: %Style{fg: :green}),
                          Span.new("[Esc] Close ", style: %Style{fg: :red})
                        ]
                      else
                        [
                          Span.new("[⇅/j/k] Select Service ", style: %Style{fg: :cyan}),
                          Span.new("[Space] Toggle Service ", style: %Style{fg: :green}),
                          Span.new("[/] Search/Filter ", style: %Style{fg: :yellow})
                        ]
                      end

                    :custom_logs ->
                      [
                        Span.new("[⇅/j/k] Select Path ", style: %Style{fg: :cyan}),
                        Span.new("[a] Add Path ", style: %Style{fg: :green}),
                        Span.new("[d/Backspace] Delete Path ", style: %Style{fg: :red})
                      ]

                    :general ->
                      [
                        Span.new("[⇅] Navigate fields ", style: %Style{fg: :cyan}),
                        Span.new("[Type] Edit text ", style: %Style{fg: :green})
                      ]
                  end

                [
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
            Span.new("[Esc] Cancel ", style: %Style{fg: :yellow}),
            Span.new("[Enter] Apply ", style: %Style{fg: :green})
          ]

        state.mode == :selecting ->
          [
            Span.new("[j/k] Move ", style: %Style{fg: :yellow}),
            Span.new("[↑/↓] Select ", style: %Style{fg: :cyan}),
            Span.new("[y] Yank ", style: %Style{fg: :green}),
            Span.new("[Esc] Cancel ", style: %Style{fg: :red})
          ]

        true ->
          current_src_id =
            cond do
              state.selected_profile_id && state.selected_container_id ->
                "#{state.selected_profile_id}/#{state.selected_container_id}"

              state.selected_profile_id ->
                state.selected_profile_id

              true ->
                nil
            end

          size =
            if current_src_id, do: Map.get(state.buffer_sizes, current_src_id, 0), else: 0

          base_shortcuts =
            if Map.get(state, :logs_full_screen, false) do
              [
                Span.new("[q] Quit "),
                Span.new("[f/Esc] Normal Screen ", style: %Style{fg: :yellow}),
                Span.new("[t] Time ", style: %Style{fg: :magenta}),
                Span.new("[/] Filter "),
                Span.new("[y] Copy All ", style: %Style{fg: :green}),
                Span.new("[v] Select ", style: %Style{fg: :cyan}),
                Span.new("[j/k] Scroll Logs ")
              ]
            else
              [
                Span.new("[q] Quit "),
                Span.new("[Enter] Connect "),
                Span.new("[a] Add Server "),
                Span.new("[f] Fullscreen ", style: %Style{fg: :yellow}),
                Span.new("[t] Time ", style: %Style{fg: :magenta}),
                Span.new("[/] Filter "),
                Span.new("[y] Copy ", style: %Style{fg: :green}),
                Span.new("[v] Select ", style: %Style{fg: :cyan}),
                Span.new("[⇅] Navigate | [j/k] Scroll ")
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

          capacity =
            if Process.whereis(Caudata.ConfigStore) do
              Caudata.ConfigStore.get_setting(Caudata.ConfigStore, :global, :capacity, 1000)
            else
              1000
            end

          if size > 0 do
            base_shortcuts ++ [Span.new(" | Lines: #{size}/#{capacity}")]
          else
            base_shortcuts
          end
      end

    %Paragraph{
      text: [Line.new(footer_spans)]
    }
  end
end
