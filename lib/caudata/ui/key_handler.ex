defmodule Caudata.UI.KeyHandler do
  @moduledoc """
  Event router that intercepts global keypresses and dispatches them to specific
  component key handlers (Modal, LogsPane, Sidebar) depending on the active state.
  """
  require Logger

  alias Caudata.UI.Components.{Sidebar, LogsPane, AddServerModal, SettingsModal}

  @doc """
  Main dispatch function for key events.
  Routes events based on modal visibility, active mode, and key type.
  """
  def handle_key_event(key_data, model) do
    Logger.debug("Received key event: #{inspect(key_data)}")
    key = Map.get(key_data, :key)
    modifiers = Map.get(key_data, :modifiers, [])
    _ctrl = Map.get(key_data, :ctrl, false) or :ctrl in modifiers

    cond do
      # 1. Active modal intercepts all keys
      model.modal_visible ->
        if model.modal_type == :settings do
          SettingsModal.handle_key(key, key_data, model)
        else
          AddServerModal.handle_key(key, key_data, model)
        end

      # 2. Escape key in search mode returns to browsing
      key in [:escape, :esc] ->
        if model.mode == :searching or model.active_field != nil do
          {%{model | mode: :browsing, active_field: nil, filter_regex: "", filter_error: false},
           []}
        else
          {model, []}
        end

      # 3. Active regex search intercepts text keys
      model.mode == :searching ->
        LogsPane.handle_key(key, key_data, model)

      # 4. Normal Mode routing
      true ->
        handle_normal_key(key, key_data, model)
    end
  end

  defp handle_normal_key(key, key_data, model) do
    norm_key = if key == :char, do: Map.get(key_data, :char), else: key

    case norm_key do
      # Sidebar navigation
      k when k in [:up, :down, :enter] ->
        Sidebar.handle_key(key, key_data, model)

      # Log display navigation
      k when k in ["j", "k", "/"] ->
        LogsPane.handle_key(key, key_data, model)

      # Global Add Connection Modal
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

      # Global Settings Modal
      k when k in ["s", "S"] ->
        if length(model.profiles) > 0 do
          selected_idx =
            Enum.find_index(model.profiles, &(&1.id == model.selected_profile_id)) || 0

          {%{
             model
             | modal_visible: true,
               modal_type: :settings,
               settings_selected_profile_idx: selected_idx,
               settings_focus: :servers,
               settings_container_idx: 0,
               settings_custom_log_idx: 0,
               settings_input_active: false,
               settings_input_value: "",
               settings_status_msg: nil
           }, []}
        else
          {model, []}
        end

      # Global Quit commands
      k when k in ["q", "Q"] ->
        {model, [{:command, :quit}]}

      # Fallback for unhandled keys
      _ ->
        {model, []}
    end
  end

  # Backwards compatibility delegators for App module/tests
  def select_item(item, model), do: Sidebar.select_item(item, model)
  def select_next_item(model), do: Sidebar.select_next_item(model)
  def select_prev_item(model), do: Sidebar.select_prev_item(model)
  def list_visible_items(model), do: Sidebar.list_visible_items(model)
end
