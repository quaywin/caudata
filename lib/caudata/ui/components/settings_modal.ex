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

    # Header lines
    header_lines = [
      Line.new([
        Span.new("Configure Server Settings", style: %Style{fg: :cyan, modifiers: [:bold]})
      ]),
      Line.new([
        Span.new(String.duplicate("─", state.width - 4), style: %Style{fg: :dark_gray})
      ])
    ]

    # Tabs definition
    tabs = [
      {:servers, "Servers"},
      {:connection, "SSH Connection"},
      {:containers, "Docker Containers"},
      {:custom_logs, "Custom Logs"}
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

    tabs_line = Line.new([Span.new("  Tab: ") | tab_spans])

    divider_line =
      Line.new([
        Span.new(String.duplicate("─", state.width - 4), style: %Style{fg: :dark_gray})
      ])

    tab_content =
      case state.settings_focus do
        :servers ->
          render_servers_tab(state)

        :connection ->
          render_connection_tab(state, profile)

        :containers ->
          render_containers_tab(state, profile, containers)

        :custom_logs ->
          render_custom_logs_tab(state, profile, custom_logs)
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
      percent_height: 80
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
      display_rows_limit = 10

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

  defp render_connection_tab(state, _profile) do
    fields_config = [
      {"host_name", "Host/IP (required):"},
      {"port", "Port:"},
      {"user", "User:"},
      {"identity_file", "Identity File (path):"},
      {"password", "Password:"}
    ]

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

    save_active = state.settings_connection_focus_idx == 5
    cancel_active = state.settings_connection_focus_idx == 6

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

    # Filter out virtual file containers representing custom logs
    docker_only_containers =
      Enum.reject(containers, fn c ->
        c.image == "file" or String.starts_with?(to_string(c.id), "file:")
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
        display_rows_limit = 10

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
        display_rows_limit = 8

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
    if model.settings_input_active and key in [:escape, :esc] do
      {%{model | settings_input_active: false, settings_status_msg: nil}, []}
    else
      case key do
        k when k in [:escape, :esc] ->
          {%{model | modal_visible: false, modal_error: nil}, []}

        _ ->
          handle_settings_key(key, key_data, model)
      end
    end
  end

  defp handle_settings_key(key, key_data, model) do
    profile = Enum.at(model.profiles, model.settings_selected_profile_idx)
    containers = if profile, do: Map.get(model.containers, profile.id, []), else: []
    custom_logs = if profile, do: profile.custom_logs || [], else: []

    # Filtered containers to match UI
    docker_only_containers =
      Enum.reject(containers, fn c ->
        c.image == "file" or String.starts_with?(to_string(c.id), "file:")
      end)

    if model.settings_focus == :connection do
      handle_connection_key(key, key_data, model, profile)
    else
      if model.settings_input_active do
        case key do
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
                      {:ok, pid} -> GenServer.call(pid, {:validate_path, path}, 5000)
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
      else
        norm_key = if key == :char, do: Map.get(key_data, :char), else: key

        case norm_key do
          k when k in [:tab, :right, "l"] ->
            next_focus =
              case model.settings_focus do
                :servers -> :connection
                :connection -> :containers
                :containers -> :custom_logs
                :custom_logs -> :servers
              end

            {%{model | settings_focus: next_focus, settings_status_msg: nil}, []}

          k when k in [:left, "h"] ->
            prev_focus =
              case model.settings_focus do
                :servers -> :custom_logs
                :connection -> :servers
                :containers -> :connection
                :custom_logs -> :containers
              end

            {%{model | settings_focus: prev_focus, settings_status_msg: nil}, []}

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
                    %{
                      "host_name" => profile.host_name || "",
                      "port" => to_string(profile.port || 22),
                      "user" => profile.user || "",
                      "identity_file" => profile.identity_file || "",
                      "password" => profile.password || ""
                    }
                  else
                    %{}
                  end

                {%{
                   model
                   | settings_selected_profile_idx: new_idx,
                     settings_container_idx: 0,
                     settings_custom_log_idx: 0,
                     settings_connection_focus_idx: 0,
                     settings_connection_fields: connection_fields,
                     settings_status_msg: nil
                 }, []}

              :containers ->
                total = length(docker_only_containers)

                new_idx =
                  if total > 0, do: rem(model.settings_container_idx - 1 + total, total), else: 0

                {%{model | settings_container_idx: new_idx, settings_status_msg: nil}, []}

              :custom_logs ->
                total = length(custom_logs)

                new_idx =
                  if total > 0, do: rem(model.settings_custom_log_idx - 1 + total, total), else: 0

                {%{model | settings_custom_log_idx: new_idx, settings_status_msg: nil}, []}
            end

          k when k in [:down, "j"] ->
            case model.settings_focus do
              :servers ->
                total = length(model.profiles)

                new_idx =
                  if total > 0, do: rem(model.settings_selected_profile_idx + 1, total), else: 0

                profile = Enum.at(model.profiles, new_idx)

                connection_fields =
                  if profile do
                    %{
                      "host_name" => profile.host_name || "",
                      "port" => to_string(profile.port || 22),
                      "user" => profile.user || "",
                      "identity_file" => profile.identity_file || "",
                      "password" => profile.password || ""
                    }
                  else
                    %{}
                  end

                {%{
                   model
                   | settings_selected_profile_idx: new_idx,
                     settings_container_idx: 0,
                     settings_custom_log_idx: 0,
                     settings_connection_focus_idx: 0,
                     settings_connection_fields: connection_fields,
                     settings_status_msg: nil
                 }, []}

              :containers ->
                total = length(docker_only_containers)
                new_idx = if total > 0, do: rem(model.settings_container_idx + 1, total), else: 0
                {%{model | settings_container_idx: new_idx, settings_status_msg: nil}, []}

              :custom_logs ->
                total = length(custom_logs)
                new_idx = if total > 0, do: rem(model.settings_custom_log_idx + 1, total), else: 0
                {%{model | settings_custom_log_idx: new_idx, settings_status_msg: nil}, []}
            end

          " " ->
            cond do
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
                        max(0, min(model.settings_custom_log_idx, length(new_custom_logs) - 1))

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
                server_id_to_delete = profile.id

                case Caudata.ConfigManager.delete_profile(server_id_to_delete) do
                  :ok ->
                    new_profiles = Enum.reject(model.profiles, &(&1.id == server_id_to_delete))

                    if length(new_profiles) == 0 do
                      {%{
                         model
                         | profiles: [],
                           selected_profile_id: nil,
                           selected_container_id: nil,
                           modal_visible: false,
                           settings_selected_profile_idx: 0,
                           settings_container_idx: 0,
                           settings_custom_log_idx: 0
                       }, []}
                    else
                      new_idx =
                        max(0, min(model.settings_selected_profile_idx, length(new_profiles) - 1))

                      next_profile = Enum.at(new_profiles, new_idx)

                      new_selected_profile_id =
                        if model.selected_profile_id == server_id_to_delete do
                          next_profile.id
                        else
                          model.selected_profile_id
                        end

                      new_selected_container_id =
                        if model.selected_profile_id == server_id_to_delete do
                          nil
                        else
                          model.selected_container_id
                        end

                      connection_fields =
                        if next_profile do
                          %{
                            "host_name" => next_profile.host_name || "",
                            "port" => to_string(next_profile.port || 22),
                            "user" => next_profile.user || "",
                            "identity_file" => next_profile.identity_file || "",
                            "password" => next_profile.password || ""
                          }
                        else
                          %{}
                        end

                      {%{
                         model
                         | profiles: new_profiles,
                           selected_profile_id: new_selected_profile_id,
                           selected_container_id: new_selected_container_id,
                           settings_selected_profile_idx: new_idx,
                           settings_container_idx: 0,
                           settings_custom_log_idx: 0,
                           settings_connection_focus_idx: 0,
                           settings_connection_fields: connection_fields,
                           settings_status_msg: "Deleted server \"#{server_id_to_delete}\""
                       }, []}
                    end

                  {:error, reason} ->
                    {%{model | settings_status_msg: "Error deleting server: #{inspect(reason)}"},
                     []}
                end

              true ->
                {model, []}
            end

          _ ->
            {model, []}
        end
      end
    end
  end

  defp handle_connection_key(key, key_data, model, profile) do
    fields = ["host_name", "port", "user", "identity_file", "password", :save, :cancel]
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
            reverted_fields = %{
              "host_name" => profile.host_name || "",
              "port" => to_string(profile.port || 22),
              "user" => profile.user || "",
              "identity_file" => profile.identity_file || "",
              "password" => profile.password || ""
            }

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
            :backspace ->
              current_val = Map.get(model.settings_connection_fields || %{}, active_item, "")
              new_val = String.slice(current_val, 0..-2//1)
              new_fields = Map.put(model.settings_connection_fields || %{}, active_item, new_val)
              {%{model | settings_connection_fields: new_fields}, []}

            :char ->
              char = Map.get(key_data, :char, "")

              if is_binary(char) and char != "" do
                current_val = Map.get(model.settings_connection_fields || %{}, active_item, "")
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
              new_fields = Map.put(model.settings_connection_fields || %{}, active_item, new_val)
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
