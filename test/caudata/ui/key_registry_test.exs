defmodule Caudata.UI.KeyRegistryTest do
  use ExUnit.Case, async: true

  alias Caudata.UI.KeyRegistry

  setup do
    initial_model = %{
      profiles: [
        %{
          id: "server-1",
          host_name: "1.2.3.4",
          user: "root",
          port: 22,
          enabled: true,
          disabled_containers: []
        }
      ],
      selected_profile_id: "server-1",
      selected_container_id: nil,
      selected_container_name: nil,
      containers: %{},
      buffer_sizes: %{},
      drop_counts: %{},
      logs: [],
      sidebar_focus: :servers,
      mode: :browsing,
      modal_visible: false,
      modal_type: :select_ssh,
      modal_selected_index: 0,
      modal_error: nil,
      logs_full_screen: false,
      show_timestamps: false,
      filter_regex: "",
      filter_error: false,
      active_field: nil,
      visual_cursor: nil,
      visual_anchor: nil,
      settings_input_active: false,
      settings_service_search_active: false,
      settings_focus: :servers,
      settings_selected_profile_idx: 0
    }

    {:ok, model: initial_model}
  end

  describe "determine_context/1" do
    test "returns :normal for default browsing mode", %{model: model} do
      assert KeyRegistry.determine_context(model) == :normal
    end

    test "returns :searching when in search mode", %{model: model} do
      searching_model = %{model | mode: :searching}
      assert KeyRegistry.determine_context(searching_model) == :searching
    end

    test "returns :selecting when in visual select mode", %{model: model} do
      selecting_model = %{model | mode: :selecting}
      assert KeyRegistry.determine_context(selecting_model) == :selecting
    end

    test "returns :select_ssh for SSH profile selection modal", %{model: model} do
      modal_model = %{model | modal_visible: true, modal_type: :select_ssh}
      assert KeyRegistry.determine_context(modal_model) == :select_ssh
    end

    test "returns :settings_tab for settings modal", %{model: model} do
      modal_model = %{model | modal_visible: true, modal_type: :settings}
      assert KeyRegistry.determine_context(modal_model) == :settings_tab
    end

    test "returns :settings_input when settings input is active", %{model: model} do
      modal_model = %{
        model
        | modal_visible: true,
          modal_type: :settings,
          settings_input_active: true
      }

      assert KeyRegistry.determine_context(modal_model) == :settings_input
    end

    test "returns :container_action for container action modal", %{model: model} do
      modal_model = %{model | modal_visible: true, modal_type: :container_action}
      assert KeyRegistry.determine_context(modal_model) == :container_action
    end

    test "returns :confirm_docker_action for confirmation modal", %{model: model} do
      modal_model = %{model | modal_visible: true, modal_type: :confirm_docker_action}
      assert KeyRegistry.determine_context(modal_model) == :confirm_docker_action
    end
  end

  describe "get_shortcuts/1" do
    test "returns shortcuts list for normal mode", %{model: model} do
      shortcuts = KeyRegistry.get_shortcuts(model)
      assert is_list(shortcuts)
      assert Enum.any?(shortcuts, fn s -> s.key == "[q]" end)
      assert Enum.any?(shortcuts, fn s -> s.key == "[a]" end)
    end

    test "returns shortcuts list for search mode", %{model: model} do
      searching_model = %{model | mode: :searching}
      shortcuts = KeyRegistry.get_shortcuts(searching_model)
      assert Enum.any?(shortcuts, fn s -> s.key == "[Enter]" and s.label == "Apply " end)
    end

    test "returns shortcuts list for visual select mode", %{model: model} do
      selecting_model = %{model | mode: :selecting}
      shortcuts = KeyRegistry.get_shortcuts(selecting_model)
      assert Enum.any?(shortcuts, fn s -> s.key == "[y]" and s.label =~ "Copy" end)
    end
  end

  describe "dispatch_key/2" do
    test "triggers quit command on Ctrl+C", %{model: model} do
      key_data = %{key: :char, char: "c", modifiers: ["ctrl"]}
      assert {^model, [{:command, :quit}]} = KeyRegistry.dispatch_key(key_data, model)
    end

    test "toggles fullscreen mode on 'f'", %{model: model} do
      key_data = %{key: :char, char: "f", modifiers: []}

      {new_model, _cmds} = KeyRegistry.dispatch_key(key_data, model)
      assert new_model.logs_full_screen == true

      {toggled_model, _cmds} = KeyRegistry.dispatch_key(key_data, new_model)
      assert toggled_model.logs_full_screen == false
    end

    test "toggles timestamps on 't'", %{model: model} do
      key_data = %{key: :char, char: "t", modifiers: []}

      {new_model, _cmds} = KeyRegistry.dispatch_key(key_data, model)
      assert new_model.show_timestamps == true
    end

    test "resets mode to browsing on Escape from searching mode", %{model: model} do
      searching_model = %{model | mode: :searching, filter_regex: "foo"}
      key_data = %{key: :escape, modifiers: []}

      {new_model, _cmds} = KeyRegistry.dispatch_key(key_data, searching_model)
      assert new_model.mode == :browsing
      assert new_model.filter_regex == ""
    end

    test "cycles panels 1 -> 2 -> 3 -> 1 on Tab", %{model: model} do
      tab_key = %{key: :tab, modifiers: []}

      # Start at Panel 1 (servers)
      assert KeyRegistry.current_panel_number(model) == 1

      # Tab -> Panel 2 (containers)
      {m2, _} = KeyRegistry.dispatch_key(tab_key, model)
      assert KeyRegistry.current_panel_number(m2) == 2

      # Tab -> Panel 3 (logs)
      {m3, _} = KeyRegistry.dispatch_key(tab_key, m2)
      assert KeyRegistry.current_panel_number(m3) == 3

      # Tab -> Panel 1 (servers)
      {m1_again, _} = KeyRegistry.dispatch_key(tab_key, m3)
      assert KeyRegistry.current_panel_number(m1_again) == 1
    end

    test "jumps directly to panel using 1, 2, 3 keys", %{model: model} do
      key1 = %{key: :char, char: "1", modifiers: []}
      key2 = %{key: :char, char: "2", modifiers: []}
      key3 = %{key: :char, char: "3", modifiers: []}

      {m3, _} = KeyRegistry.dispatch_key(key3, model)
      assert KeyRegistry.current_panel_number(m3) == 3

      {m1, _} = KeyRegistry.dispatch_key(key1, m3)
      assert KeyRegistry.current_panel_number(m1) == 1

      {m2, _} = KeyRegistry.dispatch_key(key2, m1)
      assert KeyRegistry.current_panel_number(m2) == 2
    end

    test "navigates right (1 -> 2 -> 3 -> 1) and left (3 -> 2 -> 1 -> 3) using arrows / vim keys", %{model: model} do
      right_key = %{key: :right, modifiers: []}
      left_key = %{key: :left, modifiers: []}

      # Right: 1 -> 2 -> 3 -> 1
      {m2, _} = KeyRegistry.dispatch_key(right_key, model)
      assert KeyRegistry.current_panel_number(m2) == 2

      {m3, _} = KeyRegistry.dispatch_key(right_key, m2)
      assert KeyRegistry.current_panel_number(m3) == 3

      {m1, _} = KeyRegistry.dispatch_key(right_key, m3)
      assert KeyRegistry.current_panel_number(m1) == 1

      # Left: 1 -> 3 -> 2 -> 1
      {m3_left, _} = KeyRegistry.dispatch_key(left_key, m1)
      assert KeyRegistry.current_panel_number(m3_left) == 3

      {m2_left, _} = KeyRegistry.dispatch_key(left_key, m3_left)
      assert KeyRegistry.current_panel_number(m2_left) == 2

      {m1_left, _} = KeyRegistry.dispatch_key(left_key, m2_left)
      assert KeyRegistry.current_panel_number(m1_left) == 1
    end
  end
end
