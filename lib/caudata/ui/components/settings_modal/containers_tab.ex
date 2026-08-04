defmodule Caudata.UI.Components.SettingsModal.ContainersTab do
  @moduledoc """
  Renders the 'Docker Containers' configuration tab in SettingsModal.
  """
  alias ExRatatui.Style
  alias ExRatatui.Text.Line
  alias ExRatatui.Text.Span

  @doc """
  Renders containers list for the selected profile.
  """
  def render(_state, nil, _containers) do
    [
      Line.new([]),
      Line.new([Span.new("  No server selected.", style: %Style{fg: :yellow})])
    ]
  end

  def render(state, profile, containers) do
    info_line =
      Line.new([
        Span.new("  Server: ", style: %Style{fg: :cyan}),
        Span.new(profile.id, style: %Style{fg: :yellow})
      ])

    # Filter out virtual file containers, systemd, and launchd services
    docker_only_containers =
      Enum.reject(containers, fn c ->
        c.image == "file" or String.starts_with?(to_string(c.id), "file:") or
          c.image == "systemd" or String.starts_with?(to_string(c.id), "systemd:") or
          c.image == "launchd" or String.starts_with?(to_string(c.id), "launchd:")
      end)

    list_rows =
      if Enum.empty?(docker_only_containers) do
        [
          Line.new([]),
          Line.new([
            Span.new("  No docker containers found or server is disconnected.",
              style: %Style{fg: :dark_gray}
            )
          ])
        ]
      else
        display_rows_limit = max(2, div(state.height * 90, 100) - 11)

        start_row =
          if state.settings_container_idx >= display_rows_limit,
            do: state.settings_container_idx - display_rows_limit + 1,
            else: 0

        docker_only_containers
        |> Enum.with_index()
        |> Enum.slice(start_row, display_rows_limit)
        |> Enum.map(fn {c, idx} ->
          enabled =
            c.id not in profile.disabled_containers and c.name not in profile.disabled_containers

          checkbox = if enabled, do: "[X] ", else: "[ ] "
          selected = idx == state.settings_container_idx
          cursor = if selected, do: " > ", else: "   "
          color = if selected, do: :green, else: :white

          Line.new([
            Span.new(cursor, style: %Style{fg: :green}),
            Span.new(checkbox, style: %Style{fg: if(enabled, do: :green, else: :red)}),
            Span.new(c.name,
              style: %Style{fg: color, modifiers: if(selected, do: [:bold], else: [])}
            )
          ])
        end)
      end

    status_lines =
      if state.settings_status_msg do
        color =
          if String.starts_with?(state.settings_status_msg, "Error"), do: :red, else: :yellow

        [
          Line.new([]),
          Line.new([
            Span.new("  ℹ ", style: %Style{fg: color}),
            Span.new(state.settings_status_msg, style: %Style{fg: color})
          ])
        ]
      else
        []
      end

    [info_line, Line.new([]) | list_rows] ++ status_lines
  end
end
