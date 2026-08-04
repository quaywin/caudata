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

  alias Caudata.UI.Components.SettingsModal.{
    ServersTab,
    ConnectionTab,
    ContainersTab,
    ServicesTab,
    CustomLogsTab
  }

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

    tabs_line = Line.new(tab_spans)

    divider_line =
      Line.new([
        Span.new(String.duplicate("─", popup_inner_width), style: %Style{fg: :dark_gray})
      ])

    tab_content =
      case state.settings_focus do
        :servers ->
          ServersTab.render(state)

        :connection ->
          ConnectionTab.render(state, profile)

        :containers ->
          ContainersTab.render(state, profile, containers)

        :services ->
          ServicesTab.render(state, profile, containers)

        :custom_logs ->
          CustomLogsTab.render(state, profile, custom_logs)
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
      |> ServicesTab.filter_services(model.settings_service_search)

    cond do
      model.settings_focus == :connection ->
        handle_connection_key(key, key_data, model, profile)

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
                    :custom_logs -> :servers
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
                    :servers -> :custom_logs
                    :connection -> :servers
                    :containers -> :connection
                    :services -> :containers
                    :custom_logs -> :services
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



  @doc """
  Delegates service filtering to ServicesTab.
  """
  defdelegate filter_services(services, query), to: ServicesTab

  @doc """
  Delegates name truncation to ServicesTab.
  """
  defdelegate truncate_name(name, max_len), to: ServicesTab
end
