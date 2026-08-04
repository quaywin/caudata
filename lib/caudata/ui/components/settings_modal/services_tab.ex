defmodule Caudata.UI.Components.SettingsModal.ServicesTab do
  @moduledoc """
  Renders the 'System Services' configuration tab in SettingsModal.
  """
  alias ExRatatui.Style
  alias ExRatatui.Text.Line
  alias ExRatatui.Text.Span

  @doc """
  Renders systemd and launchd services list for the selected profile.
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

    popup_inner_width = div(state.width * 80, 100) - 4

    services =
      Enum.filter(containers, fn c ->
        c.image == "systemd" or String.starts_with?(to_string(c.id), "systemd:") or
          c.image == "launchd" or String.starts_with?(to_string(c.id), "launchd:")
      end)

    filtered_services = filter_services(services, state.settings_service_search)
    max_name_len = max(20, div(state.width, 3))

    preview_lines =
      with false <- Enum.empty?(filtered_services),
           service <- Enum.at(filtered_services, state.settings_service_idx),
           true <- service != nil,
           name_str <- to_string(service.name),
           true <- String.length(name_str) > max_name_len do
        [
          Line.new([]),
          Line.new([
            Span.new("  → ", style: %Style{fg: :cyan}),
            Span.new(name_str, style: %Style{fg: :cyan, modifiers: [:bold]}),
            Span.new("  [#{service.image}: #{service.status}]",
              style: %Style{fg: :dark_gray}
            )
          ])
        ]
      else
        _ -> []
      end

    search_lines =
      if state.settings_service_search_active or state.settings_service_search != "" do
        divider_line =
          Line.new([
            Span.new("  " <> String.duplicate("─", max(2, popup_inner_width - 4)),
              style: %Style{fg: :dark_gray}
            )
          ])

        filter_line =
          if state.settings_service_search_active do
            Line.new([
              Span.new("  Filter: /", style: %Style{fg: :cyan, modifiers: [:bold]}),
              Span.new(state.settings_service_search <> "█", style: %Style{fg: :white})
            ])
          else
            Line.new([
              Span.new("  Filter active: /", style: %Style{fg: :green}),
              Span.new(state.settings_service_search, style: %Style{fg: :white})
            ])
          end

        [divider_line, filter_line]
      else
        []
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

    popup_parent_height = state.height - 3
    outer_height = div(popup_parent_height * 90, 100)
    inner_height = outer_height - 1
    upper_lines_count = 6
    max_bottom_lines = 4
    display_rows_limit = max(2, inner_height - upper_lines_count - max_bottom_lines)

    list_rows =
      if Enum.empty?(filtered_services) do
        empty_msg =
          if state.settings_service_search != "" do
            "  No services match \"#{state.settings_service_search}\"."
          else
            "  No system services found or server is disconnected."
          end

        [
          Line.new([]),
          Line.new([Span.new(empty_msg, style: %Style{fg: :dark_gray})])
        ]
      else
        start_row =
          if state.settings_service_idx >= display_rows_limit,
            do: state.settings_service_idx - display_rows_limit + 1,
            else: 0

        filtered_services
        |> Enum.with_index()
        |> Enum.slice(start_row, display_rows_limit)
        |> Enum.map(fn {service, idx} ->
          selected = idx == state.settings_service_idx
          cursor = if selected, do: " > ", else: "   "
          color = if selected, do: :green, else: :white

          enabled_services = Map.get(profile, :enabled_services) || []
          enabled = service.id in enabled_services or service.name in enabled_services
          checkbox = if enabled, do: "[X] ", else: "[ ] "

          Line.new([
            Span.new(cursor, style: %Style{fg: :green}),
            Span.new(checkbox, style: %Style{fg: if(enabled, do: :green, else: :dark_gray)}),
            Span.new(truncate_name(service.name, max_name_len), style: %Style{fg: color}),
            Span.new(" "),
            Span.new(String.pad_trailing(service.image, 12), style: %Style{fg: :dark_gray}),
            Span.new(" "),
            Span.new(service.status, style: %Style{fg: :dark_gray})
          ])
        end)
      end

    list_rows_count = length(list_rows)
    bottom_lines_count = length(preview_lines) + length(search_lines) + length(status_lines)
    used_lines = upper_lines_count + list_rows_count + bottom_lines_count

    padding_lines_count = max(0, inner_height - used_lines)
    padding_lines = List.duplicate(Line.new([]), padding_lines_count)

    [info_line, Line.new([]) | list_rows] ++
      padding_lines ++ preview_lines ++ search_lines ++ status_lines
  end

  def filter_services(services, search_query) do
    if is_binary(search_query) and String.trim(search_query) != "" do
      q = String.downcase(String.trim(search_query))

      Enum.filter(services, fn s ->
        name = String.downcase(to_string(s.name || ""))
        id = String.downcase(to_string(s.id || ""))
        String.contains?(name, q) or String.contains?(id, q)
      end)
    else
      services
    end
  end

  def truncate_name(name, max_len) when is_binary(name) do
    if String.length(name) > max_len do
      String.slice(name, 0, max_len - 1) <> "…"
    else
      String.pad_trailing(name, max_len)
    end
  end

  def truncate_name(other, max_len), do: truncate_name(to_string(other), max_len)
end
