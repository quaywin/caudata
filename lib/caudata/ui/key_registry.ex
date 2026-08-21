defmodule Caudata.UI.KeyRegistry do
  @moduledoc """
  Single Source of Truth for keyboard event routing, active UI context resolution,
  and dynamic footer shortcut hints.
  """
  require Logger

  alias Caudata.UI.Components.{
    Sidebar,
    LogsPane,
    AddServerModal,
    SettingsModal,
    ContainerActionModal,
    ContainerInspectModal,
    HelpModal,
    LevelFilterModal
  }

  alias Caudata.UI.ViewHelper

  @doc """
  Determines the active UI context atom for the given model state.
  """
  def determine_context(model) do
    modal_visible = Map.get(model, :modal_visible, false)
    modal_type = Map.get(model, :modal_type)
    mode = Map.get(model, :mode, :browsing)

    cond do
      # 1. Active Modals
      modal_visible ->
        case modal_type do
          :help ->
            :help

          :settings ->
            cond do
              Map.get(model, :settings_input_active, false) -> :settings_input
              Map.get(model, :settings_service_search_active, false) -> :settings_service_search
              true -> :settings_tab
            end

          :container_action ->
            :container_action

          :confirm_docker_action ->
            :confirm_docker_action

          :confirm_delete_server ->
            :confirm_delete_server

          :container_inspect ->
            :container_inspect

          :level_filter ->
            :level_filter

          :select_ssh ->
            :select_ssh

          type when type in [:manual_input, :local_input] ->
            :modal_text_input

          _other ->
            :modal_generic
        end

      # 2. Interactive Modes
      mode == :searching ->
        :searching

      mode == :selecting ->
        :selecting

      # 3. Base Browsing Mode
      true ->
        :normal
    end
  end

  @doc """
  Returns a list of `%{key: string, label: string, color: atom}` maps for rendering footer hints.
  """
  def get_shortcuts(state) do
    context = determine_context(state)

    case context do
      :help ->
        [
          shortcut("[⇅]", "Scroll ", :cyan),
          shortcut("[Esc/q/?]", "Close ", :red)
        ]

      :select_ssh ->
        [
          shortcut("[⇅]", "Navigate ", :yellow),
          shortcut("[Enter]", "Select ", :green),
          shortcut("[Esc]", "Cancel ", :red)
        ]

      :modal_text_input ->
        [
          shortcut("[⇅]", "Navigate fields  ", :yellow),
          shortcut("[Type]", "Edit text ", :cyan),
          shortcut("[Enter]", "Submit/Action ", :green),
          shortcut("[Esc]", "Close ", :red)
        ]

      :settings_input ->
        [
          shortcut("[Type]", "Input path ", :cyan),
          shortcut("[Enter]", "Validate & Save ", :green),
          shortcut("[Esc]", "Cancel ", :red)
        ]

      :settings_service_search ->
        [
          shortcut("[Type]", "Filter ", :cyan),
          shortcut("[Enter]", "Apply ", :green),
          shortcut("[Esc]", "Close ", :red)
        ]

      :settings_tab ->
        settings_focus = Map.get(state, :settings_focus, :servers)

        tab_specific =
          case settings_focus do
            :servers ->
              [
                shortcut("[⇅]", "Select Server ", :cyan),
                shortcut("[Space]", "Toggle Server ", :green),
                shortcut("[d/Backspace]", "Delete Server ", :red)
              ]

            :connection ->
              [
                shortcut("[⇅]", "Navigate fields ", :cyan),
                shortcut("[Type]", "Edit text ", :green)
              ]

            :containers ->
              [
                shortcut("[⇅]", "Select Container ", :cyan),
                shortcut("[Space]", "Toggle Container ", :green)
              ]

            :services ->
              [
                shortcut("[⇅]", "Select Service ", :cyan),
                shortcut("[Space]", "Toggle Service ", :green),
                shortcut("[/]", "Search/Filter ", :yellow)
              ]

            :custom_logs ->
              [
                shortcut("[⇅]", "Select Path ", :cyan),
                shortcut("[a]", "Add Path ", :green),
                shortcut("[d/Backspace]", "Delete Path ", :red)
              ]
          end

        [shortcut("[Tab/⇅/⇄]", "Switch Tab ", :yellow)] ++
          tab_specific ++ [shortcut("[Esc]", "Close ", :red)]

      :container_action ->
        actions = ContainerActionModal.get_available_actions(state)
        total = length(actions)

        [
          shortcut("[⇅]", "Navigate ", :cyan),
          shortcut("[Enter/1-#{total}]", "Confirm ", :green),
          shortcut("[Esc]", "Cancel ", :red)
        ]

      :container_inspect ->
        [
          shortcut("[⇅]", "Scroll ", :cyan),
          shortcut("[r]", "Toggle Raw/Summary ", :yellow),
          shortcut("[Esc/q]", "Close ", :red)
        ]

      :confirm_docker_action ->
        [
          shortcut("[y/Enter]", "Confirm & Execute ", :red, bold: true),
          shortcut("[n/Esc]", "Cancel ", :yellow)
        ]

      :level_filter ->
        [
          shortcut("[⇅/j/k]", "Navigate ", :cyan),
          shortcut("[0-3/Enter]", "Select Level ", :green),
          shortcut("[Esc/q]", "Close ", :red)
        ]

      :searching ->
        [
          shortcut("[Esc]", "Cancel ", :yellow),
          shortcut("[Enter]", "Apply ", :green)
        ]

      :selecting ->
        if Map.get(state, :visual_anchor) == nil do
          [
            shortcut("[⇅]", "Move Cursor ", :cyan),
            shortcut("[v/Space]", "Start Selection ", :yellow),
            shortcut("[y]", "Copy Line ", :green),
            shortcut("[Esc]", "Exit ", :red)
          ]
        else
          count =
            case ViewHelper.get_selection_range(state) do
              nil -> 1
              range -> Enum.count(range)
            end

          [
            shortcut("[⇅]", "Extend Selection (#{count}L) ", :cyan),
            shortcut("[v/Space]", "Stop Selection ", :yellow),
            shortcut("[o]", "Swap Ends ", :magenta),
            shortcut("[y]", "Copy Range ", :green),
            shortcut("[Esc]", "Cancel Anchor ", :red)
          ]
        end

      :normal ->
        get_normal_shortcuts(state)

      _ ->
        [shortcut("[Esc]", "Close ", :red)]
    end
  end

  defp get_normal_shortcuts(state) do
    if Map.get(state, :logs_full_screen, false) do
      [
        shortcut("[q]", "Quit ", :white),
        shortcut("[f/Esc]", "Normal ", :yellow),
        shortcut("[s]", "Settings ", :yellow),
        shortcut("[l]", "Level ", :yellow),
        shortcut("[t]", "Time ", :magenta),
        shortcut("[/]", "Filter ", :white),
        shortcut("[y]", "Copy All ", :green),
        shortcut("[v]", "Select ", :cyan),
        shortcut("[⇅]", "Scroll ", :white),
        shortcut("[g/G]", "Top/Bot ", :white)
      ]
    else
      active_panel = Map.get(state, :active_panel, :sidebar)

      case active_panel do
        :logs ->
          [
            shortcut("[q]", "Quit ", :white),
            shortcut("[1-3/Tab]", "Panel ", :yellow),
            shortcut("[s]", "Settings ", :yellow),
            shortcut("[l]", "Level ", :yellow),
            shortcut("[f]", "Full ", :yellow),
            shortcut("[t]", "Time ", :magenta),
            shortcut("[/]", "Filter ", :white),
            shortcut("[y]", "Copy ", :green),
            shortcut("[v]", "Select ", :cyan),
            shortcut("[⇅]", "Scroll ", :white),
            shortcut("[g/G]", "Top/Bot ", :white),
            shortcut("[?]", "Help ", :cyan)
          ]

        _sidebar ->
          action_hint =
            if Map.get(state, :sidebar_focus) == :containers do
              if selected_container_is_docker?(state) do
                [shortcut("[m/Enter]", "Actions ", :cyan)]
              else
                [shortcut("[Enter]", "Select ", :cyan)]
              end
            else
              [shortcut("[Enter]", "Connect ", :white)]
            end

          [
            shortcut("[q]", "Quit ", :white),
            shortcut("[1-3/Tab]", "Panel ", :yellow)
          ] ++
            action_hint ++
            [
              shortcut("[a]", "Add ", :white),
              shortcut("[s]", "Settings ", :yellow),
              shortcut("[l]", "Level ", :yellow),
              shortcut("[f]", "Full ", :yellow),
              shortcut("[t]", "Time ", :magenta),
              shortcut("[/]", "Filter ", :white),
              shortcut("[y]", "Copy ", :green),
              shortcut("[v]", "Select ", :cyan),
              shortcut("[⇅]", "Nav ", :white),
              shortcut("[?]", "Help ", :cyan)
            ]
      end
    end
  end

  @doc """
  Main dispatch function for key events.
  Routes events cleanly based on key type and active context.
  """
  def dispatch_key(key_data, model) do
    Logger.debug("Dispatching key event: #{inspect(key_data)}")

    modal_visible = Map.get(model, :modal_visible, false)
    mode = Map.get(model, :mode, :browsing)

    is_input_active =
      modal_visible or
        mode == :searching or
        Map.get(model, :settings_input_active, false) or
        Map.get(model, :settings_service_search_active, false)

    # Intercept paste hotkey when input is active
    key_data =
      if is_input_active and ViewHelper.paste_key?(key_data) do
        case Map.get(key_data, :key) do
          :paste ->
            key_data

          _ ->
            case ViewHelper.paste_from_clipboard() do
              {:ok, text} -> %{key: :paste, content: text}
              _ -> key_data
            end
        end
      else
        key_data
      end

    key = Map.get(key_data, :key)

    cond do
      # 0. Global Ctrl+C quit command
      ViewHelper.ctrl_c_key?(key_data) ->
        {model, [{:command, :quit}]}

      # 1. Active modal intercepts all keys
      modal_visible ->
        dispatch_modal_key(key, key_data, model)

      # 2. Escape key in search/visual mode returns to browsing
      key in [:escape, :esc] ->
        cond do
          mode == :searching or Map.get(model, :active_field) != nil ->
            {%{model | mode: :browsing, active_field: nil, filter_regex: "", filter_error: false},
             []}

          mode == :selecting ->
            {%{model | mode: :browsing, visual_anchor: nil, visual_cursor: nil}, []}

          Map.get(model, :logs_full_screen, false) ->
            {%{model | logs_full_screen: false}, []}

          true ->
            {model, []}
        end

      # 3. Active regex search or visual select mode
      mode == :searching ->
        LogsPane.handle_key(key, key_data, model)

      mode == :selecting ->
        LogsPane.handle_key(key, key_data, model)

      # 4. Normal Mode routing
      true ->
        handle_normal_key(key, key_data, model)
    end
  end

  defp dispatch_modal_key(key, key_data, model) do
    case Map.get(model, :modal_type) do
      :help ->
        HelpModal.handle_key(key, key_data, model)

      :settings ->
        SettingsModal.handle_key(key, key_data, model)

      :container_action ->
        ContainerActionModal.handle_key(key, key_data, model)

      :confirm_docker_action ->
        ContainerActionModal.handle_key_confirm(key, key_data, model)

      :confirm_delete_server ->
        ContainerActionModal.handle_key_confirm(key, key_data, model)

      :container_inspect ->
        ContainerInspectModal.handle_key(key, key_data, model)

      :level_filter ->
        handle_level_filter_modal_key(key, key_data, model)

      _ ->
        AddServerModal.handle_key(key, key_data, model)
    end
  end

  # Helper to resolve current panel number (1: Server, 2: Container, 3: Logs)
  def current_panel_number(model) do
    active_panel = Map.get(model, :active_panel, :sidebar)
    sidebar_focus = Map.get(model, :sidebar_focus, :servers)

    case {active_panel, sidebar_focus} do
      {:sidebar, :servers} -> 1
      {:sidebar, :containers} -> 2
      {:logs, _} -> 3
      _ -> 1
    end
  end

  # Helper to switch to panel 1, 2, or 3
  def switch_to_panel(panel_num, model) do
    case panel_num do
      1 -> Sidebar.focus_servers(model)
      2 -> Sidebar.focus_containers(model)
      3 -> {Map.put(model, :active_panel, :logs), []}
      _ -> {model, []}
    end
  end

  def open_level_filter_modal(model) do
    current_level = Map.get(model, :log_level_filter, :all)
    current_idx = LevelFilterModal.get_index_for_level(current_level)

    new_model =
      model
      |> Map.put(:modal_visible, true)
      |> Map.put(:modal_type, :level_filter)
      |> Map.put(:level_filter_modal_selected_index, current_idx)

    {new_model, []}
  end

  def handle_level_filter_modal_key(key, key_data, model) do
    char = if key == :char, do: Map.get(key_data, :char), else: nil
    idx = Map.get(model, :level_filter_modal_selected_index, 0)
    total = length(LevelFilterModal.levels())

    cond do
      key in [:escape, :esc] or char in ["q", "Q"] ->
        {%{model | modal_visible: false}, []}

      key in [:up, "k", "K"] or char in ["k", "K"] ->
        new_idx = if idx > 0, do: idx - 1, else: total - 1
        {%{model | level_filter_modal_selected_index: new_idx}, []}

      key in [:down, "j", "J"] or char in ["j", "J"] ->
        new_idx = if idx < total - 1, do: idx + 1, else: 0
        {%{model | level_filter_modal_selected_index: new_idx}, []}

      key in [:enter, " "] or char == " " ->
        chosen_level = LevelFilterModal.get_level_by_index(idx)
        apply_level_filter(chosen_level, model)

      char in ["0", "1", "2", "3"] ->
        chosen_level = LevelFilterModal.get_level_by_key(char)
        apply_level_filter(chosen_level, model)

      true ->
        {model, []}
    end
  end

  defp apply_level_filter(level, model) do
    level_name = Atom.to_string(level) |> String.upcase()
    notif = if level == :all, do: "Log level filter cleared (All logs)", else: "Log level filter: #{level_name}+"

    new_model =
      model
      |> Map.put(:modal_visible, false)
      |> Map.put(:log_level_filter, level)
      |> Map.put(:logs_scroll_y, :bottom)
      |> Map.put(:notification, {notif, 25})

    {new_model, []}
  end

  defp handle_normal_key(key, key_data, model) do
    norm_key = if key == :char, do: Map.get(key_data, :char), else: key

    case norm_key do
      "?" ->
        {%{model | modal_visible: true, modal_type: :help, help_modal_scroll_y: 0}, []}

      "1" ->
        switch_to_panel(1, model)

      "2" ->
        switch_to_panel(2, model)

      "3" ->
        switch_to_panel(3, model)

      :tab ->
        next_panel =
          case current_panel_number(model) do
            1 -> 2
            2 -> 3
            3 -> 1
          end

        switch_to_panel(next_panel, model)

      :right ->
        next_panel =
          case current_panel_number(model) do
            1 -> 2
            2 -> 3
            3 -> 1
          end

        switch_to_panel(next_panel, model)

      :left ->
        prev_panel =
          case current_panel_number(model) do
            1 -> 3
            2 -> 1
            3 -> 2
          end

        switch_to_panel(prev_panel, model)

      k when k in ["l", "L"] ->
        open_level_filter_modal(model)

      k when k in ["j", "k", :up, :down] ->
        active_panel = Map.get(model, :active_panel, :sidebar)

        if active_panel == :sidebar do
          dir = if k in ["k", :up], do: :up, else: :down
          Sidebar.handle_key(dir, key_data, model)
        else
          logs_key_data =
            if k in ["k", :up] do
              %{key: :char, char: "k"}
            else
              %{key: :char, char: "j"}
            end

          LogsPane.handle_key(:char, logs_key_data, model)
        end

      k when k in ["m", "M"] ->
        open_container_action_modal(model)

      :enter ->
        if Map.get(model, :sidebar_focus, :servers) == :containers and Map.get(model, :selected_container_id) do
          open_container_action_modal(model)
        else
          Sidebar.handle_key(:enter, key_data, model)
        end

      k when k in ["g", "G", "/", "y", "Y", "v", "V"] ->
        LogsPane.handle_key(key, key_data, model)

      k when k in [:page_up, :pageup, :page_down, :pagedown] ->
        LogsPane.handle_key(key, key_data, model)

      k when k in ["f", "F"] ->
        {%{model | logs_full_screen: not Map.get(model, :logs_full_screen, false)}, []}

      k when k in ["t", "T"] ->
        {%{model | show_timestamps: not Map.get(model, :show_timestamps, false)}, []}

      k when k in ["a", "A"] ->
        ssh_config_profiles = Caudata.ConfigManager.discover_ssh_profiles()

        {%{
           model
           | modal_visible: true,
             modal_type: :select_ssh,
             ssh_config_profiles: ssh_config_profiles,
             modal_selected_index: 0,
             modal_error: nil
         }, []}

      k when k in ["s", "S"] ->
        open_settings_modal(model)

      k when k in ["q", "Q"] ->
        {model, [{:command, :quit}]}

      _ ->
        {model, []}
    end
  end

  def open_container_action_modal(model) do
    profiles = Map.get(model, :profiles, [])
    selected_profile_id = Map.get(model, :selected_profile_id)
    selected_container_id = Map.get(model, :selected_container_id)
    containers_map = Map.get(model, :containers, %{})

    selected_profile = Enum.find(profiles, &(&1.id == selected_profile_id))

    enabled_containers =
      if selected_profile do
        ViewHelper.get_enabled_containers(
          selected_profile,
          Map.get(containers_map, selected_profile.id, [])
        )
      else
        []
      end

    selected_container =
      if selected_profile && selected_container_id do
        Enum.find(
          enabled_containers,
          &(to_string(&1.id) == to_string(selected_container_id))
        )
      end

    if selected_container && docker_container?(selected_container) do
      new_model =
        %{model | modal_visible: true, modal_type: :container_action}
        |> Map.put(:container_action_modal_selected_index, 0)

      {new_model, []}
    else
      {model, []}
    end
  end

  def open_settings_modal(model) do
    profiles = Map.get(model, :profiles, [])
    selected_profile_id = Map.get(model, :selected_profile_id)

    if length(profiles) > 0 do
      selected_idx =
        Enum.find_index(profiles, &(&1.id == selected_profile_id)) || 0

      profile = Enum.at(profiles, selected_idx)

      connection_fields =
        if Map.get(profile, :is_local, false) do
          %{"password" => profile.password || ""}
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
         | modal_visible: true,
           modal_type: :settings,
           settings_selected_profile_idx: selected_idx,
           settings_focus: :servers,
           settings_container_idx: 0,
           settings_custom_log_idx: 0,
           settings_connection_focus_idx: 0,
           settings_connection_fields: connection_fields,
           settings_input_active: false,
           settings_input_value: "",
           settings_service_search: "",
           settings_service_search_active: false,
           settings_status_msg: nil
       }, []}
    else
      {model, []}
    end
  end

  defp shortcut(key, label, color, opts \\ []) do
    %{
      key: key,
      label: label,
      color: color,
      bold: Keyword.get(opts, :bold, false)
    }
  end

  defp selected_container_is_docker?(state), do: ViewHelper.selected_container_is_docker?(state)
  defp docker_container?(container), do: ViewHelper.docker_container?(container)
end
