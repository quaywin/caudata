defmodule Caudata.UI.Components.SettingsModal do
  @moduledoc """
  Renders the server settings configuration modal and handles its keyboard event flows.
  """
  alias ExRatatui.Style
  alias ExRatatui.Text.Line
  alias ExRatatui.Text.Span
  alias ExRatatui.Widgets.Block
  alias ExRatatui.Widgets.Paragraph
  alias ExRatatui.Widgets.Popup

  @doc """
  Renders the settings modal widget.
  """
  def render(state) do
    # Selected profile
    profile = Enum.at(state.profiles, state.settings_selected_profile_idx)
    containers = if profile, do: Map.get(state.containers, profile.id, []), else: []
    custom_logs = if profile, do: profile.custom_logs || [], else: []

    # Calculate actual inner width of the 80% popup to prevent horizontal text wrapping
    popup_inner_width = div(state.width * 80, 100) - 4

    # Header lines
    header_lines = [
      Line.new([
        Span.new("Configure Server Settings", style: %Style{fg: :cyan, modifiers: [:bold]})
      ]),
      Line.new([
        Span.new(String.duplicate("─", popup_inner_width), style: %Style{fg: :dark_gray})
      ])
    ]

    # Tabs definition
    tabs = [
      {:servers, "Servers"},
      {:connection, "SSH Connection"},
      {:containers, "Docker Containers"},
      {:services, "System Services"},
      {:custom_logs, "Custom Logs"},
      {:general, "General"}
    ]

    tab_spans =
      Enum.map(tabs, fn {focus, name} ->
        if state.settings_focus == focus do
          Span.new(" [ #{name} ] ", style: %Style{fg: :green, modifiers: [:bold]})
        else
          Span.new("   #{name}   ", style: %Style{fg: :white})
        end
      end)
      |> Enum.intersperse(Span.new("│", style: %Style{fg: :dark_gray}))

    tabs_line = Line.new(tab_spans)

    divider_line =
      Line.new([
        Span.new(String.duplicate("─", popup_inner_width), style: %Style{fg: :dark_gray})
      ])

    tab_content =
      case state.settings_focus do
        :servers ->
          render_servers_tab(state)

        :connection ->
          render_connection_tab(state, profile)

        :containers ->
          render_containers_tab(state, profile, containers)

        :services ->
          render_services_tab(state, profile, containers)

        :custom_logs ->
          render_custom_logs_tab(state, profile, custom_logs)

        :general ->
          render_general_tab(state)
      end

    popup_widget = %Popup{
      content: %Paragraph{
        text: header_lines ++ [tabs_line, divider_line] ++ tab_content
      },
      block: %Block{
        title: " Settings ",
        borders: [:all],
        border_type: :rounded
      },
      percent_width: 80,
      percent_height: 90
    }

    [popup_widget]
  end

  defp render_servers_tab(state) do
    if Enum.empty?(state.profiles) do
      [
        Line.new([]),
        Line.new([
          Span.new("  No servers configured. Add one first.", style: %Style{fg: :yellow})
        ])
      ]
    else
      display_rows_limit = max(3, div(state.height * 90, 100) - 9)

      start_row =
        if state.settings_selected_profile_idx >= display_rows_limit,
          do: state.settings_selected_profile_idx - display_rows_limit + 1,
          else: 0

      rows =
        state.profiles
        |> Enum.with_index()
        |> Enum.slice(start_row, display_rows_limit)
        |> Enum.map(fn {p, idx} ->
          selected = idx == state.settings_selected_profile_idx
          cursor = if selected, do: " > ", else: "   "
          color = if selected, do: :green, else: :white

          enabled = Map.get(p, :enabled, true)
          checkbox = if enabled, do: "[X] ", else: "[ ] "
          checkbox_color = if enabled, do: :green, else: :red

          status =
            if enabled do
              Map.get(state.statuses, p.id, :disconnected)
            else
              :disabled
            end

          status_color = Caudata.UI.ViewHelper.status_color(status)

          status_icon =
            case status do
              :connected -> "● "
              :connecting -> "◌ "
              :disabled -> "⊘ "
              _ -> "○ "
            end

          conn_info = "(#{p.user || "root"}@#{p.host_name}:#{p.port})"

          # dynamic padding based on width
          max_id_len = max(15, div(state.width, 4))
          id_padded = String.pad_trailing(p.id, max_id_len)

          Line.new([
            Span.new(cursor, style: %Style{fg: :green}),
            Span.new(checkbox, style: %Style{fg: checkbox_color}),
            Span.new(status_icon, style: %Style{fg: status_color}),
            Span.new(id_padded,
              style: %Style{fg: color, modifiers: if(selected, do: [:bold], else: [])}
            ),
            Span.new(conn_info, style: %Style{fg: :dark_gray})
          ])
        end)

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

      [Line.new([]) | rows] ++ status_lines
    end
  end

  defp render_connection_tab(_state, nil) do
    [
      Line.new([]),
      Line.new([
        Span.new("  No server selected. Go to Servers tab to select or add one.",
          style: %Style{fg: :yellow}
        )
      ])
    ]
  end

  defp render_connection_tab(state, profile) do
    is_local = Map.get(profile, :is_local, false)

    fields_config =
      if is_local do
        [
          {"password", "Password:"}
        ]
      else
        [
          {"host_name", "Host/IP (required):"},
          {"port", "Port:"},
          {"user", "User:"},
          {"identity_file", "Identity File (path):"},
          {"password", "Password:"}
        ]
      end

    form_lines =
      Enum.with_index(fields_config)
      |> Enum.flat_map(fn {{key, label}, index} ->
        active = state.settings_connection_focus_idx == index
        prefix = if active, do: "> ", else: "  "
        label_color = if active, do: :cyan, else: :white
        value_color = if active, do: :green, else: :white
        value = Map.get(state.settings_connection_fields || %{}, key, "")

        masked_value =
          if key == "password", do: String.duplicate("*", String.length(value)), else: value

        display_value = if active, do: masked_value <> "█", else: masked_value

        [
          Line.new([Span.new(prefix), Span.new(label, style: %Style{fg: label_color})]),
          Line.new([
            Span.new("    "),
            Span.new(display_value, style: %Style{fg: value_color})
          ])
        ]
      end)

    num_fields = length(fields_config)
    save_active = state.settings_connection_focus_idx == num_fields
    cancel_active = state.settings_connection_focus_idx == num_fields + 1

    buttons_line =
      Line.new([
        Span.new(
          if(save_active, do: "> [ Save Connection ]   ", else: "  [ Save Connection ]   "),
          style: %Style{fg: if(save_active, do: :green, else: :white)}
        ),
        Span.new(if(cancel_active, do: "> [ Cancel ]", else: "  [ Cancel ]"),
          style: %Style{fg: if(cancel_active, do: :red, else: :white)}
        )
      ])

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

    [Line.new([]) | form_lines] ++ [Line.new([]), buttons_line] ++ status_lines
  end

  defp render_containers_tab(_state, nil, _containers) do
    [
      Line.new([]),
      Line.new([Span.new("  No server selected.", style: %Style{fg: :yellow})])
    ]
  end

  defp render_containers_tab(state, profile, containers) do
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

  defp render_services_tab(_state, nil, _containers) do
    [
      Line.new([]),
      Line.new([Span.new("  No server selected.", style: %Style{fg: :yellow})])
    ]
  end

  defp render_services_tab(state, profile, containers) do
    info_line =
      Line.new([
        Span.new("  Server: ", style: %Style{fg: :cyan}),
        Span.new(profile.id, style: %Style{fg: :yellow})
      ])

    # Calculate actual inner width of the 80% popup to prevent horizontal text wrapping
    popup_inner_width = div(state.width * 80, 100) - 4

    # Filter only systemd and launchd services
    services =
      Enum.filter(containers, fn c ->
        c.image == "systemd" or String.starts_with?(to_string(c.id), "systemd:") or
          c.image == "launchd" or String.starts_with?(to_string(c.id), "launchd:")
      end)

    # Apply user search filter (case-insensitive match on name + id)
    filtered_services = filter_services(services, state.settings_service_search)

    # Dynamic name column width: ~1/3 of terminal width, min 20.
    max_name_len = max(20, div(state.width, 3))

    # 1. Preview line: show full name when selected service is truncated
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

    # 2. Search/Filter bar: renders a divider and input/active line at the bottom, matching Logs layout style
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

    # 3. Status messages (errors, connection alerts, etc.)
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

    # Calculate layout dimensions dynamically to pin items to the bottom.
    # The modal is rendered within main_content_area, which has a height of state.height - 3.
    popup_parent_height = state.height - 3
    outer_height = div(popup_parent_height * 90, 100)

    # Using a safety margin of -3 to account for the popup block borders (2 lines) and
    # an extra line of safety, ensuring the bottom filter bar is never clipped out of view.
    inner_height = outer_height - 1

    # Fixed upper overhead lines in SettingsModal.render/1:
    # 2 (header) + 1 (tabs line) + 1 (divider) + 1 (info_line) + 1 (empty line) = 6 lines
    upper_lines_count = 6

    # Reserve space for bottom lines (preview, search, status) to prevent modal overflow.
    # Total potential bottom lines is 6 (2 lines per section if visible).
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

    # Calculate padding lines to push bottom elements to the very bottom of the popup
    list_rows_count = length(list_rows)
    bottom_lines_count = length(preview_lines) + length(search_lines) + length(status_lines)
    used_lines = upper_lines_count + list_rows_count + bottom_lines_count

    padding_lines_count = max(0, inner_height - used_lines)
    padding_lines = List.duplicate(Line.new([]), padding_lines_count)

    [info_line, Line.new([]) | list_rows] ++
      padding_lines ++ preview_lines ++ search_lines ++ status_lines
  end

  defp render_custom_logs_tab(_state, nil, _custom_logs) do
    [
      Line.new([]),
      Line.new([Span.new("  No server selected.", style: %Style{fg: :yellow})])
    ]
  end

  defp render_custom_logs_tab(state, profile, custom_logs) do
    info_line =
      Line.new([
        Span.new("  Server: ", style: %Style{fg: :cyan}),
        Span.new(profile.id, style: %Style{fg: :yellow})
      ])

    list_rows =
      if Enum.empty?(custom_logs) do
        [
          Line.new([]),
          Line.new([
            Span.new("  No custom logs configured. Press 'a' to add a path.",
              style: %Style{fg: :dark_gray}
            )
          ])
        ]
      else
        display_rows_limit = max(2, div(state.height * 90, 100) - 11)

        start_row =
          if state.settings_custom_log_idx >= display_rows_limit,
            do: state.settings_custom_log_idx - display_rows_limit + 1,
            else: 0

        custom_logs
        |> Enum.with_index()
        |> Enum.slice(start_row, display_rows_limit)
        |> Enum.map(fn {path, idx} ->
          selected = idx == state.settings_custom_log_idx
          cursor = if selected, do: " > ", else: "   "
          color = if selected, do: :green, else: :white

          container_id = "file:#{path}"

          enabled =
            container_id not in profile.disabled_containers and
              path not in profile.disabled_containers

          checkbox = if enabled, do: "[X] ", else: "[ ] "

          Line.new([
            Span.new(cursor, style: %Style{fg: :green}),
            Span.new(checkbox, style: %Style{fg: if(enabled, do: :green, else: :red)}),
            Span.new(path,
              style: %Style{fg: color, modifiers: if(selected, do: [:bold], else: [])}
            )
          ])
        end)
      end

    input_lines =
      if state.settings_input_active do
        [
          Line.new([]),
          Line.new([
            Span.new("  ┌─ Enter new log path ─────────────────────────────────┐",
              style: %Style{fg: :cyan}
            )
          ]),
          Line.new([
            Span.new("  │ ", style: %Style{fg: :cyan}),
            Span.new(state.settings_input_value <> "█", style: %Style{fg: :green})
          ]),
          Line.new([
            Span.new("  └──────────────────────────────────────────────────────┘",
              style: %Style{fg: :cyan}
            )
          ])
        ]
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

    [info_line, Line.new([]) | list_rows] ++ input_lines ++ status_lines
  end

  @doc """
  Dispatches key events for the settings modal.
  """
  def handle_key(key, key_data, model) do
    cond do
      model.settings_input_active and key in [:escape, :esc] ->
        {%{model | settings_input_active: false, settings_status_msg: nil}, []}

      key in [:escape, :esc] ->
        {%{model | modal_visible: false, modal_error: nil}, []}

      true ->
        handle_settings_key(key, key_data, model)
    end
  end

  defp handle_settings_key(key, key_data, model) do
    profile = Enum.at(model.profiles, model.settings_selected_profile_idx)
    containers = if profile, do: Map.get(model.containers, profile.id, []), else: []
    custom_logs = if profile, do: profile.custom_logs || [], else: []

    # Filtered containers to match UI
    docker_only_containers =
      Enum.reject(containers, fn c ->
        c.image == "file" or String.starts_with?(to_string(c.id), "file:") or
          c.image == "systemd" or String.starts_with?(to_string(c.id), "systemd:") or
          c.image == "launchd" or String.starts_with?(to_string(c.id), "launchd:")
      end)

    services_only =
      containers
      |> Enum.filter(fn c ->
        c.image == "systemd" or String.starts_with?(to_string(c.id), "systemd:") or
          c.image == "launchd" or String.starts_with?(to_string(c.id), "launchd:")
      end)
      |> filter_services(model.settings_service_search)

    cond do
      model.settings_focus == :connection ->
        handle_connection_key(key, key_data, model, profile)

      model.settings_focus == :general ->
        handle_general_key(key, key_data, model)

      true ->
        cond do
          model.settings_service_search_active ->
            handle_service_search_key(key, key_data, model)

          model.settings_input_active ->
            case key do
              :paste ->
                text = Map.get(key_data, :content, "")
                {%{model | settings_input_value: model.settings_input_value <> text}, []}

              :escape ->
                {%{model | settings_input_active: false, settings_status_msg: nil}, []}

              :enter ->
                path = String.trim(model.settings_input_value)

                cond do
                  path == "" ->
                    {%{model | settings_status_msg: "Error: Path cannot be empty"}, []}

                  path in custom_logs ->
                    {%{model | settings_status_msg: "Error: Path already added"}, []}

                  true ->
                    ui_pid = self()
                    server_id = profile.id

                    Task.start(fn ->
                      result =
                        case Caudata.ServerSupervisor.lookup_worker(server_id) do
                          {:ok, pid} ->
                            try do
                              GenServer.call(pid, {:validate_path, path}, 5000)
                            catch
                              :exit, _ -> {:error, :timeout}
                            end
                          _ -> {:error, :not_connected}
                        end

                      send(ui_pid, {:validation_result, server_id, path, result})
                    end)

                    {%{
                       model
                       | settings_input_active: false,
                         settings_status_msg: "Validating path \"#{path}\"..."
                     }, []}
                end

              :backspace ->
                current = model.settings_input_value
                new_val = String.slice(current, 0..-2//1)
                {%{model | settings_input_value: new_val}, []}

              :char ->
                char = Map.get(key_data, :char, "")

                if is_binary(char) and char != "" do
                  {%{model | settings_input_value: model.settings_input_value <> char}, []}
                else
                  {model, []}
                end

              ch when is_binary(ch) and byte_size(ch) == 1 ->
                {%{model | settings_input_value: model.settings_input_value <> ch}, []}

              _ ->
                {model, []}
            end

          true ->
            norm_key = if key == :char, do: Map.get(key_data, :char), else: key

            case norm_key do
              k when k in [:tab, :right, "l"] ->
                next_focus =
                  case model.settings_focus do
                    :servers -> :connection
                    :connection -> :containers
                    :containers -> :services
                    :services -> :custom_logs
                    :custom_logs -> :general
                    :general -> :servers
                  end

                # Reset search state when leaving the services tab
                model =
                  if model.settings_focus == :services do
                    %{model | settings_service_search: "", settings_service_search_active: false}
                  else
                    model
                  end

                {%{model | settings_focus: next_focus, settings_status_msg: nil}, []}

              k when k in [:left, "h"] ->
                prev_focus =
                  case model.settings_focus do
                    :servers -> :general
                    :connection -> :servers
                    :containers -> :connection
                    :services -> :containers
                    :custom_logs -> :services
                    :general -> :custom_logs
                  end

                # Reset search state when leaving the services tab
                model =
                  if model.settings_focus == :services do
                    %{model | settings_service_search: "", settings_service_search_active: false}
                  else
                    model
                  end

                {%{model | settings_focus: prev_focus, settings_status_msg: nil}, []}

              "/" ->
                if model.settings_focus == :services do
                  {%{model | settings_service_search_active: true, settings_status_msg: nil}, []}
                else
                  {model, []}
                end

              k when k in [:up, "k"] ->
                case model.settings_focus do
                  :servers ->
                    total = length(model.profiles)

                    new_idx =
                      if total > 0,
                        do: rem(model.settings_selected_profile_idx - 1 + total, total),
                        else: 0

                    profile = Enum.at(model.profiles, new_idx)

                    connection_fields =
                      if profile do
                        if Map.get(profile, :is_local, false) do
                          %{
                            "password" => profile.password || ""
                          }
                        else
                          %{
                            "host_name" => profile.host_name || "",
                            "port" => to_string(profile.port || 22),
                            "user" => profile.user || "",
                            "identity_file" => profile.identity_file || "",
                            "password" => profile.password || ""
                          }
                        end
                      else
                        %{}
                      end

                    {%{
                       model
                       | settings_selected_profile_idx: new_idx,
                         settings_container_idx: 0,
                         settings_service_idx: 0,
                         settings_service_search: "",
                         settings_service_search_active: false,
                         settings_custom_log_idx: 0,
                         settings_connection_focus_idx: 0,
                         settings_connection_fields: connection_fields,
                         settings_status_msg: nil
                     }, []}

                  :containers ->
                    total = length(docker_only_containers)

                    new_idx =
                      if total > 0,
                        do: rem(model.settings_container_idx - 1 + total, total),
                        else: 0

                    {%{model | settings_container_idx: new_idx, settings_status_msg: nil}, []}

                  :services ->
                    total = length(services_only)

                    new_idx =
                      if total > 0,
                        do: rem(model.settings_service_idx - 1 + total, total),
                        else: 0

                    {%{model | settings_service_idx: new_idx, settings_status_msg: nil}, []}

                  :custom_logs ->
                    total = length(custom_logs)

                    new_idx =
                      if total > 0,
                        do: rem(model.settings_custom_log_idx - 1 + total, total),
                        else: 0

                    {%{model | settings_custom_log_idx: new_idx, settings_status_msg: nil}, []}
                end

              k when k in [:down, "j"] ->
                case model.settings_focus do
                  :servers ->
                    total = length(model.profiles)

                    new_idx =
                      if total > 0,
                        do: rem(model.settings_selected_profile_idx + 1, total),
                        else: 0

                    profile = Enum.at(model.profiles, new_idx)

                    connection_fields =
                      if profile do
                        if Map.get(profile, :is_local, false) do
                          %{
                            "password" => profile.password || ""
                          }
                        else
                          %{
                            "host_name" => profile.host_name || "",
                            "port" => to_string(profile.port || 22),
                            "user" => profile.user || "",
                            "identity_file" => profile.identity_file || "",
                            "password" => profile.password || ""
                          }
                        end
                      else
                        %{}
                      end

                    {%{
                       model
                       | settings_selected_profile_idx: new_idx,
                         settings_container_idx: 0,
                         settings_service_idx: 0,
                         settings_service_search: "",
                         settings_service_search_active: false,
                         settings_custom_log_idx: 0,
                         settings_connection_focus_idx: 0,
                         settings_connection_fields: connection_fields,
                         settings_status_msg: nil
                     }, []}

                  :containers ->
                    total = length(docker_only_containers)

                    new_idx =
                      if total > 0, do: rem(model.settings_container_idx + 1, total), else: 0

                    {%{model | settings_container_idx: new_idx, settings_status_msg: nil}, []}

                  :services ->
                    total = length(services_only)

                    new_idx =
                      if total > 0, do: rem(model.settings_service_idx + 1, total), else: 0

                    {%{model | settings_service_idx: new_idx, settings_status_msg: nil}, []}

                  :custom_logs ->
                    total = length(custom_logs)

                    new_idx =
                      if total > 0, do: rem(model.settings_custom_log_idx + 1, total), else: 0

                    {%{model | settings_custom_log_idx: new_idx, settings_status_msg: nil}, []}
                end

              " " ->
                cond do
                  model.settings_focus == :services ->
                    service = Enum.at(services_only, model.settings_service_idx)

                    if service do
                      enabled_services =
                        Enum.map(Map.get(profile, :enabled_services) || [], &to_string/1)

                      service_id = to_string(service.id)

                      new_enabled_services =
                        if service_id in enabled_services do
                          enabled_services -- [service_id]
                        else
                          [service_id | enabled_services]
                        end

                      case Caudata.ConfigManager.update_profile(profile.id, %{
                             enabled_services: new_enabled_services
                           }) do
                        {:ok, updated_profile} ->
                          new_profiles =
                            Enum.map(model.profiles, fn p ->
                              if p.id == profile.id, do: updated_profile, else: p
                            end)

                          {%{model | profiles: new_profiles}, []}

                        {:error, reason} ->
                          {%{
                             model
                             | settings_status_msg: "Error saving settings: #{inspect(reason)}"
                           }, []}
                      end
                    else
                      {model, []}
                    end

                  model.settings_focus == :containers ->
                    container = Enum.at(docker_only_containers, model.settings_container_idx)

                    if container do
                      disabled = Enum.map(profile.disabled_containers || [], &to_string/1)
                      container_id = to_string(container.id)
                      container_name = to_string(container.name)

                      new_disabled =
                        if container_id in disabled or container_name in disabled do
                          disabled -- [container_id, container_name]
                        else
                          [container_name | disabled]
                        end

                      case Caudata.ConfigManager.update_profile(profile.id, %{
                             disabled_containers: new_disabled
                           }) do
                        {:ok, updated_profile} ->
                          new_profiles =
                            Enum.map(model.profiles, fn p ->
                              if p.id == profile.id, do: updated_profile, else: p
                            end)

                          {%{model | profiles: new_profiles}, []}

                        {:error, reason} ->
                          {%{
                             model
                             | settings_status_msg: "Error saving settings: #{inspect(reason)}"
                           }, []}
                      end
                    else
                      {model, []}
                    end

                  model.settings_focus == :custom_logs ->
                    path = Enum.at(custom_logs, model.settings_custom_log_idx)

                    if path do
                      disabled = Enum.map(profile.disabled_containers || [], &to_string/1)
                      path_str = to_string(path)
                      container_id = "file:#{path_str}"

                      new_disabled =
                        if container_id in disabled or path_str in disabled do
                          disabled -- [container_id, path_str]
                        else
                          [container_id | disabled]
                        end

                      case Caudata.ConfigManager.update_profile(profile.id, %{
                             disabled_containers: new_disabled
                           }) do
                        {:ok, updated_profile} ->
                          new_profiles =
                            Enum.map(model.profiles, fn p ->
                              if p.id == profile.id, do: updated_profile, else: p
                            end)

                          {%{model | profiles: new_profiles}, []}

                        {:error, reason} ->
                          {%{
                             model
                             | settings_status_msg: "Error saving settings: #{inspect(reason)}"
                           }, []}
                      end
                    else
                      {model, []}
                    end

                  model.settings_focus == :servers ->
                    new_enabled = not Map.get(profile, :enabled, true)
                    updated_profile = %{profile | enabled: new_enabled}

                    new_profiles =
                      Enum.map(model.profiles, fn p ->
                        if p.id == profile.id, do: updated_profile, else: p
                      end)

                    Task.start(fn ->
                      _ =
                        Caudata.ConfigManager.update_profile(profile.id, %{
                          enabled: new_enabled
                        })
                    end)

                    {%{model | profiles: new_profiles}, []}

                  true ->
                    {model, []}
                end

              k when k in ["a", "A"] ->
                if model.settings_focus == :custom_logs and profile do
                  {%{
                     model
                     | settings_input_active: true,
                       settings_input_value: "",
                       settings_status_msg: nil
                   }, []}
                else
                  {model, []}
                end

              k when k in ["d", "D", :backspace] ->
                cond do
                  model.settings_focus == :custom_logs and profile ->
                    path_to_delete = Enum.at(custom_logs, model.settings_custom_log_idx)

                    if path_to_delete do
                      new_custom_logs = custom_logs -- [path_to_delete]

                      case Caudata.ConfigManager.update_profile(profile.id, %{
                             custom_logs: new_custom_logs
                           }) do
                        {:ok, updated_profile} ->
                          new_profiles =
                            Enum.map(model.profiles, fn p ->
                              if p.id == profile.id, do: updated_profile, else: p
                            end)

                          new_idx =
                            max(
                              0,
                              min(model.settings_custom_log_idx, length(new_custom_logs) - 1)
                            )

                          {%{
                             model
                             | profiles: new_profiles,
                               settings_custom_log_idx: new_idx,
                               settings_status_msg: "Deleted \"#{path_to_delete}\""
                           }, []}

                        {:error, reason} ->
                          {%{
                             model
                             | settings_status_msg: "Error saving settings: #{inspect(reason)}"
                           }, []}
                      end
                    else
                      {model, []}
                    end

                  model.settings_focus == :servers and profile ->
                    {%{
                       model
                       | modal_visible: true,
                         modal_type: :confirm_delete_server,
                         delete_server_id: profile.id
                     }, []}

                  true ->
                    {model, []}
                end

              _ ->
                {model, []}
            end
        end
    end
  end

  defp handle_service_search_key(key, key_data, model) do
    case key do
      :paste ->
        text = Map.get(key_data, :content, "")

        {%{
           model
           | settings_service_search: model.settings_service_search <> text,
             settings_service_idx: 0
         }, []}

      :enter ->
        # Enter applies the filter and exits search mode (keeps query)
        {%{
           model
           | settings_service_search_active: false,
             settings_service_idx: 0,
             settings_status_msg: nil
         }, []}

      :backspace ->
        current = model.settings_service_search
        new_val = String.slice(current, 0..-2//1)
        # Reset idx to avoid out-of-bounds as the list shrinks
        {%{model | settings_service_search: new_val, settings_service_idx: 0}, []}

      :char ->
        char = Map.get(key_data, :char, "")

        if is_binary(char) and char != "" do
          {%{
             model
             | settings_service_search: model.settings_service_search <> char,
               settings_service_idx: 0
           }, []}
        else
          {model, []}
        end

      ch when is_binary(ch) and byte_size(ch) == 1 ->
        {%{
           model
           | settings_service_search: model.settings_service_search <> ch,
             settings_service_idx: 0
         }, []}

      _ ->
        # Allow navigation keys to fall through so user can still move while filtering.
        # Exit search mode but keep the query, then re-dispatch to normal handler.
        case key do
          k when k in [:up, :down, "k", "j"] ->
            # Temporarily deactivate search_active to run normal navigation,
            # then reactivate it in the returned model to avoid infinite recursion.
            temp_model = %{model | settings_service_search_active: false}
            {new_model, cmds} = handle_settings_key(key, key_data, temp_model)
            {%{new_model | settings_service_search_active: true}, cmds}

          k when k in [:tab, :right, :left, "l", "h"] ->
            # Tab/arrow navigation: exit search, clear filter, switch tab
            handle_settings_key(key, key_data, %{
              model
              | settings_service_search_active: false,
                settings_service_search: ""
            })

          _ ->
            {model, []}
        end
    end
  end

  defp handle_connection_key(key, key_data, model, profile) do
    is_local = Map.get(profile, :is_local, false)

    fields =
      if is_local do
        ["password", :save, :cancel]
      else
        ["host_name", "port", "user", "identity_file", "password", :save, :cancel]
      end

    num_fields = length(fields)
    active_idx = model.settings_connection_focus_idx
    active_item = Enum.at(fields, active_idx)

    case key do
      :down ->
        new_focus = rem(active_idx + 1, num_fields)
        {%{model | settings_connection_focus_idx: new_focus, settings_status_msg: nil}, []}

      :up ->
        new_focus = rem(active_idx - 1 + num_fields, num_fields)
        {%{model | settings_connection_focus_idx: new_focus, settings_status_msg: nil}, []}

      k when k in [:tab, :right] ->
        {%{model | settings_focus: :containers, settings_status_msg: nil}, []}

      :left ->
        {%{model | settings_focus: :servers, settings_status_msg: nil}, []}

      :enter ->
        case active_item do
          :cancel ->
            # Revert fields to profile defaults and go back to :servers tab
            reverted_fields =
              if is_local do
                %{
                  "password" => profile.password || ""
                }
              else
                %{
                  "host_name" => profile.host_name || "",
                  "port" => to_string(profile.port || 22),
                  "user" => profile.user || "",
                  "identity_file" => profile.identity_file || "",
                  "password" => profile.password || ""
                }
              end

            {%{
               model
               | settings_focus: :servers,
                 settings_connection_focus_idx: 0,
                 settings_connection_fields: reverted_fields,
                 settings_status_msg: nil
             }, []}

          :save ->
            save_connection_settings(model, profile)

          _input_field ->
            # Enter key on input fields acts as Down to move to next field
            new_focus = rem(active_idx + 1, num_fields)
            {%{model | settings_connection_focus_idx: new_focus}, []}
        end

      _ ->
        if is_binary(active_item) do
          case key do
            :paste ->
              text = Map.get(key_data, :content, "")
              current_val = Map.get(model.settings_connection_fields || %{}, active_item, "")
              new_val = current_val <> text

              new_fields =
                Map.put(model.settings_connection_fields || %{}, active_item, new_val)

              {%{model | settings_connection_fields: new_fields}, []}

            :backspace ->
              current_val = Map.get(model.settings_connection_fields || %{}, active_item, "")
              new_val = String.slice(current_val, 0..-2//1)

              new_fields =
                Map.put(model.settings_connection_fields || %{}, active_item, new_val)

              {%{model | settings_connection_fields: new_fields}, []}

            :char ->
              char = Map.get(key_data, :char, "")

              if is_binary(char) and char != "" do
                current_val =
                  Map.get(model.settings_connection_fields || %{}, active_item, "")

                new_val = current_val <> char

                new_fields =
                  Map.put(model.settings_connection_fields || %{}, active_item, new_val)

                {%{model | settings_connection_fields: new_fields}, []}
              else
                {model, []}
              end

            ch when is_binary(ch) and byte_size(ch) == 1 ->
              current_val = Map.get(model.settings_connection_fields || %{}, active_item, "")
              new_val = current_val <> ch

              new_fields =
                Map.put(model.settings_connection_fields || %{}, active_item, new_val)

              {%{model | settings_connection_fields: new_fields}, []}

            _ ->
              {model, []}
          end
        else
          # On Save/Cancel buttons, we can accept character shortcuts like 'j', 'k', 'h', 'l'
          norm_key = if key == :char, do: Map.get(key_data, :char), else: key

          case norm_key do
            "j" ->
              new_focus = rem(active_idx + 1, num_fields)
              {%{model | settings_connection_focus_idx: new_focus, settings_status_msg: nil}, []}

            "k" ->
              new_focus = rem(active_idx - 1 + num_fields, num_fields)
              {%{model | settings_connection_focus_idx: new_focus, settings_status_msg: nil}, []}

            "h" ->
              {%{model | settings_focus: :servers, settings_status_msg: nil}, []}

            "l" ->
              {%{model | settings_focus: :containers, settings_status_msg: nil}, []}

            _ ->
              {model, []}
          end
        end
    end
  end

  defp save_connection_settings(model, profile) do
    if Map.get(profile, :is_local, false) do
      password = String.trim(model.settings_connection_fields["password"] || "")
      password = if password == "", do: nil, else: password

      updates = %{
        password: password
      }

      case Caudata.ConfigManager.update_profile(profile.id, updates) do
        {:ok, updated_profile} ->
          new_profiles =
            Enum.map(model.profiles, fn p ->
              if p.id == profile.id, do: updated_profile, else: p
            end)

          {%{
             model
             | profiles: new_profiles,
               settings_status_msg: "Successfully saved connection settings"
           }, []}

        {:error, reason} ->
          {%{model | settings_status_msg: "Error saving: #{inspect(reason)}"}, []}
      end
    else
      host_name = String.trim(model.settings_connection_fields["host_name"] || "")
      port_str = String.trim(model.settings_connection_fields["port"] || "")

      port =
        case Integer.parse(port_str) do
          {p, _} -> p
          _ -> 22
        end

      user = String.trim(model.settings_connection_fields["user"] || "")
      user = if user == "", do: nil, else: user

      identity_file = String.trim(model.settings_connection_fields["identity_file"] || "")
      identity_file = if identity_file == "", do: nil, else: identity_file

      password = String.trim(model.settings_connection_fields["password"] || "")
      password = if password == "", do: nil, else: password

      cond do
        host_name == "" ->
          {%{model | settings_status_msg: "Error: Host/IP is required"}, []}

        true ->
          updates = %{
            host_name: host_name,
            port: port,
            user: user,
            identity_file: identity_file,
            password: password
          }

          case Caudata.ConfigManager.update_profile(profile.id, updates) do
            {:ok, updated_profile} ->
              new_profiles =
                Enum.map(model.profiles, fn p ->
                  if p.id == profile.id, do: updated_profile, else: p
                end)

              {%{
                 model
                 | profiles: new_profiles,
                   settings_status_msg: "Successfully saved connection settings"
               }, []}

            {:error, reason} ->
              {%{model | settings_status_msg: "Error saving: #{inspect(reason)}"}, []}
          end
      end
    end
  end

  defp render_general_tab(state) do
    # Only 1 field: capacity
    active_idx = state.settings_global_focus_idx || 0

    prefix = if active_idx == 0, do: "> ", else: "  "
    label_color = if active_idx == 0, do: :cyan, else: :white
    value_color = if active_idx == 0, do: :green, else: :white

    value = state.settings_global_capacity || "1000"
    display_value = if active_idx == 0, do: value <> "█", else: value

    form_lines = [
      Line.new([
        Span.new(prefix),
        Span.new("Global Log Capacity (lines):", style: %Style{fg: label_color})
      ]),
      Line.new([
        Span.new("    "),
        Span.new(display_value, style: %Style{fg: value_color})
      ])
    ]

    save_active = active_idx == 1
    cancel_active = active_idx == 2

    buttons_line =
      Line.new([
        Span.new(
          if(save_active,
            do: "> [ Save General Settings ]   ",
            else: "  [ Save General Settings ]   "
          ),
          style: %Style{fg: if(save_active, do: :green, else: :white)}
        ),
        Span.new(if(cancel_active, do: "> [ Cancel ]", else: "  [ Cancel ]"),
          style: %Style{fg: if(cancel_active, do: :red, else: :white)}
        )
      ])

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

    [Line.new([])] ++ form_lines ++ [Line.new([]), buttons_line] ++ status_lines
  end

  defp handle_general_key(key, key_data, model) do
    # fields are: "capacity" (idx 0), :save (idx 1), :cancel (idx 2)
    active_idx = model.settings_global_focus_idx || 0
    num_fields = 3

    case key do
      :down ->
        new_focus = rem(active_idx + 1, num_fields)
        {%{model | settings_global_focus_idx: new_focus, settings_status_msg: nil}, []}

      :up ->
        new_focus = rem(active_idx - 1 + num_fields, num_fields)
        {%{model | settings_global_focus_idx: new_focus, settings_status_msg: nil}, []}

      k when k in [:tab, :right] ->
        {%{model | settings_focus: :servers, settings_status_msg: nil}, []}

      :left ->
        {%{model | settings_focus: :custom_logs, settings_status_msg: nil}, []}

      :enter ->
        case active_idx do
          # cancel
          2 ->
            # Revert capacity to config value and switch to servers
            capacity =
              if Process.whereis(Caudata.ConfigStore) do
                Caudata.ConfigStore.get_setting(Caudata.ConfigStore, :global, :capacity, 1000)
              else
                1000
              end

            {%{
               model
               | settings_focus: :servers,
                 settings_global_focus_idx: 0,
                 settings_global_capacity: to_string(capacity),
                 settings_status_msg: nil
             }, []}

          # save
          1 ->
            save_general_settings(model)

          # capacity input
          0 ->
            # Enter key on input moves down to Save
            {%{model | settings_global_focus_idx: 1}, []}
        end

      _ ->
        if active_idx == 0 do
          case key do
            :paste ->
              text = Map.get(key_data, :content, "")
              clean_digits = String.replace(text, ~r/[^\d]/, "")
              current_val = model.settings_global_capacity || ""
              new_val = current_val <> clean_digits
              {%{model | settings_global_capacity: new_val}, []}

            :backspace ->
              current_val = model.settings_global_capacity || ""
              new_val = String.slice(current_val, 0..-2//1)
              {%{model | settings_global_capacity: new_val}, []}

            :char ->
              char = Map.get(key_data, :char, "")

              if is_binary(char) and char =~ ~r/^\d$/ do
                current_val = model.settings_global_capacity || ""
                new_val = current_val <> char
                {%{model | settings_global_capacity: new_val}, []}
              else
                {model, []}
              end

            ch when is_binary(ch) and byte_size(ch) == 1 ->
              if ch =~ ~r/^\d$/ do
                current_val = model.settings_global_capacity || ""
                new_val = current_val <> ch
                {%{model | settings_global_capacity: new_val}, []}
              else
                {model, []}
              end

            _ ->
              {model, []}
          end
        else
          {model, []}
        end
    end
  end

  @doc """
  Filters a list of system services by a search query.

  Match is case-insensitive substring against both the service `name` and `id`.
  An empty query returns the list unchanged.
  """
  def filter_services(services, query) when is_binary(query) do
    query_trim = String.trim(query)

    if query_trim == "" do
      services
    else
      q_down = String.downcase(query_trim)

      Enum.filter(services, fn s ->
        name = s.name |> to_string() |> String.downcase()
        id = s.id |> to_string() |> String.downcase()
        String.contains?(name, q_down) or String.contains?(id, q_down)
      end)
    end
  end

  def filter_services(services, _query), do: services

  @doc """
  Truncates a string to `max_len`, appending an ellipsis if it was shortened.
  Shorter strings are padded to `max_len` so columns align in the list.
  """
  def truncate_name(name, max_len) when is_integer(max_len) and max_len > 1 do
    str = to_string(name)
    len = String.length(str)

    cond do
      len > max_len ->
        String.slice(str, 0, max_len - 1) <> "…"

      len < max_len ->
        String.pad_trailing(str, max_len)

      true ->
        str
    end
  end

  defp save_general_settings(model) do
    capacity_str = String.trim(model.settings_global_capacity || "")

    case Integer.parse(capacity_str) do
      {capacity, ""} when capacity > 0 ->
        # Save to ConfigStore
        if Process.whereis(Caudata.ConfigStore) do
          Caudata.ConfigStore.put_setting(Caudata.ConfigStore, :global, :capacity, capacity)
        end

        # Update LogStore capacity dynamically
        if Process.whereis(Caudata.LogStore) do
          Caudata.LogStore.set_capacity(Caudata.LogStore, capacity)
        end

        {%{
           model
           | settings_status_msg: "Successfully saved log capacity: #{capacity}"
         }, []}

      _ ->
        {%{model | settings_status_msg: "Error: Capacity must be a positive integer"}, []}
    end
  end
end
