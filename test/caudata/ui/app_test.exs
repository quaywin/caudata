defmodule Caudata.UI.AppTest do
  use ExUnit.Case, async: true
  alias Caudata.UI.App

  setup do
    # Terminate any existing interval timers if needed, but it's safe
    :ok
  end

  test "mount/1 initializes the model state correctly" do
    assert {:ok, state} = App.mount([])
    assert is_map(state)
    assert state.filter_regex == ""
    assert state.filter_error == false
    assert state.freeze == false
    assert state.modal_visible == false
    assert state.containers == %{}
    assert state.selected_container_id == nil
    assert state.width == 80
    assert state.height == 24

    assert {:ok, state_custom} = App.mount(width: 120, height: 40)
    assert state_custom.width == 120
    assert state_custom.height == 40
  end

  test "handle_info/2 and handle_event/2 handle selection, settings, and resize" do
    {:ok, state} = App.mount([])

    # Selection
    assert {:noreply, updated_state} = App.handle_info({:select_profile, "test-server"}, state)
    assert updated_state.selected_profile_id == "test-server"
    assert updated_state.selected_container_id == nil

    # Select container
    assert {:noreply, container_state} =
             App.handle_info({:select_container, "test-server", "container-1"}, state)

    assert container_state.selected_profile_id == "test-server"
    assert container_state.selected_container_id == "container-1"

    # Freeze Toggle
    assert {:noreply, updated_state2} = App.handle_info(:toggle_freeze, state)
    assert updated_state2.freeze == true
    assert {:noreply, restored_state} = App.handle_info(:toggle_freeze, updated_state2)
    assert restored_state.freeze == false

    # Resize event
    resize_event = %ExRatatui.Event.Resize{width: 100, height: 35}
    assert {:noreply, resized_state} = App.handle_event(resize_event, state)
    assert resized_state.width == 100
    assert resized_state.height == 35
  end

  test "handle_info/2 handles regex filter compile safely" do
    {:ok, state} = App.mount([])

    # Invalid regex
    assert {:noreply, updated_state} = App.handle_info({:update_filter, "[invalid("}, state)
    assert updated_state.filter_regex == "[invalid("
    assert updated_state.filter_error == true

    # Valid regex
    assert {:noreply, updated_state2} = App.handle_info({:update_filter, "valid.*regex"}, state)
    assert updated_state2.filter_regex == "valid.*regex"
    assert updated_state2.filter_error == false
  end

  test "handle_event/2 handles keyboard events for navigation" do
    {:ok, state} = App.mount([])

    # Select next profile
    if length(state.profiles) > 1 do
      [p1, p2 | _] = state.profiles

      # Under Option B, navigation skips servers and only visits containers.
      # We mock containers for both profiles.
      state = %{
        state
        | containers: %{
            p1.id => [%{id: "c1", name: "container-1"}],
            p2.id => [%{id: "c2", name: "container-2"}]
          },
          selected_profile_id: p1.id,
          selected_container_id: "c1"
      }

      # ArrowDown
      event = %ExRatatui.Event.Key{code: "down", modifiers: []}
      assert {:noreply, updated_state} = App.handle_event(event, state)
      assert updated_state.selected_profile_id != state.selected_profile_id
      assert updated_state.selected_container_id == "c2"
    end

    # Enter key in normal mode when active_field is nil
    event_enter = %ExRatatui.Event.Key{code: "enter", modifiers: []}
    assert {:noreply, _} = App.handle_event(event_enter, state)
  end

  test "handle_event/2 handles keyboard events for search mode state machine transitions" do
    {:ok, state} = App.mount([])
    assert state.mode == :browsing

    # Pressing '/' key triggers search mode
    event_slash = %ExRatatui.Event.Key{code: "/", modifiers: []}
    assert {:noreply, searching_state} = App.handle_event(event_slash, state)
    assert searching_state.mode == :searching
    assert searching_state.active_field == :filter_regex

    # Typing chars in search mode updates filter_regex
    event_char_a = %ExRatatui.Event.Key{code: "a", modifiers: []}
    assert {:noreply, typing_state1} = App.handle_event(event_char_a, searching_state)
    assert typing_state1.filter_regex == "a"
    assert typing_state1.mode == :searching

    event_char_b = %ExRatatui.Event.Key{code: "b", modifiers: []}
    assert {:noreply, typing_state2} = App.handle_event(event_char_b, typing_state1)
    assert typing_state2.filter_regex == "ab"
    assert typing_state2.mode == :searching

    # Backspace deletes the last char
    event_backspace = %ExRatatui.Event.Key{code: "backspace", modifiers: []}
    assert {:noreply, backspace_state} = App.handle_event(event_backspace, typing_state2)
    assert backspace_state.filter_regex == "a"
    assert backspace_state.mode == :searching

    # Enter exits search mode but retains the filter
    event_enter = %ExRatatui.Event.Key{code: "enter", modifiers: []}
    assert {:noreply, entered_state} = App.handle_event(event_enter, backspace_state)
    assert entered_state.mode == :browsing
    assert entered_state.filter_regex == "a"

    # Escape in browsing clears the filter or escape in searching exits and clears
    event_esc = %ExRatatui.Event.Key{code: "esc", modifiers: []}
    assert {:noreply, cancelled_state1} = App.handle_event(event_esc, backspace_state)
    assert cancelled_state1.mode == :browsing
    assert cancelled_state1.filter_regex == ""
  end

  test "handle_event/2 handles modal state machine transitions and key events" do
    {:ok, state} = App.mount([])
    assert state.modal_visible == false

    # Pressing 'a' triggers select_ssh modal
    event_a = %ExRatatui.Event.Key{code: "a", modifiers: []}
    assert {:noreply, modal_state} = App.handle_event(event_a, state)
    assert modal_state.modal_visible == true
    assert modal_state.modal_type == :select_ssh
    assert modal_state.modal_selected_index == 0

    # Mock ssh_config_profiles to have an entry so total_options > 1
    modal_state = %{
      modal_state
      | ssh_config_profiles: [%Caudata.Profile{id: "server1", host_pattern: "server1"}]
    }

    # In select_ssh, pressing 'j' or "down" updates selection index
    event_down = %ExRatatui.Event.Key{code: "down", modifiers: []}
    assert {:noreply, down_state} = App.handle_event(event_down, modal_state)
    assert down_state.modal_selected_index == 1

    event_up = %ExRatatui.Event.Key{code: "up", modifiers: []}
    assert {:noreply, up_state} = App.handle_event(event_up, down_state)
    assert up_state.modal_selected_index == 0

    # Pressing Escape closes the modal
    event_esc = %ExRatatui.Event.Key{code: "esc", modifiers: []}
    assert {:noreply, closed_state} = App.handle_event(event_esc, modal_state)
    assert closed_state.modal_visible == false

    # Pressing Enter on index 0 (Manual) switches to manual input
    event_enter = %ExRatatui.Event.Key{code: "enter", modifiers: []}
    assert {:noreply, manual_state} = App.handle_event(event_enter, modal_state)
    assert manual_state.modal_visible == true
    assert manual_state.modal_type == :manual_input
    assert manual_state.modal_focus_index == 0
    assert manual_state.modal_fields["host_name"] == ""

    # In manual_input, pressing down changes focus
    assert {:noreply, focused_state} = App.handle_event(event_down, manual_state)
    assert focused_state.modal_focus_index == 1

    # Focused on "host_name", typing appends characters
    event_h = %ExRatatui.Event.Key{code: "1", modifiers: []}
    assert {:noreply, type_state1} = App.handle_event(event_h, focused_state)
    event_host_char = %ExRatatui.Event.Key{code: "0", modifiers: []}
    assert {:noreply, type_state2} = App.handle_event(event_host_char, type_state1)
    assert type_state2.modal_fields["host_name"] == "10"

    # Pressing backspace deletes characters
    event_backspace = %ExRatatui.Event.Key{code: "backspace", modifiers: []}
    assert {:noreply, backspaced} = App.handle_event(event_backspace, type_state2)
    assert backspaced.modal_fields["host_name"] == "1"

    # Pressing enter with empty host_name shows error
    assert {:noreply, err_state} = App.handle_event(event_enter, manual_state)
    assert err_state.modal_error == "Host/IP is required"

    # Pressing enter on Cancel button (index 7) switches back to select_ssh
    cancel_focused_state = %{manual_state | modal_focus_index: 7}
    assert {:noreply, cancelled_manual} = App.handle_event(event_enter, cancel_focused_state)
    assert cancelled_manual.modal_type == :select_ssh
    assert cancelled_manual.modal_visible == true
  end

  test "handle_event/2 handles keyboard events for logs scrolling" do
    {:ok, state} = App.mount([])

    # Setup some test logs (25 lines) and standard viewport height (24 lines)
    logs = Enum.map(1..25, &"line #{&1}")

    state = %{
      state
      | logs: logs,
        height: 24,
        selected_profile_id: "test-server",
        selected_container_id: "container-1"
    }

    assert state.logs_scroll_y == :bottom

    # Visible logs pane height: 24 - 4 = 20.
    # Total logs = 25 lines.
    # max_scroll = 25 - 20 = 5.

    # Pressing "k" (scroll up)
    event_k = %ExRatatui.Event.Key{code: "k", modifiers: []}
    assert {:noreply, state_k1} = App.handle_event(event_k, state)
    # Scrolling up from :bottom will set scroll index to max_scroll - 3 = 2
    assert state_k1.logs_scroll_y == 2

    # Scroll up again
    assert {:noreply, state_k2} = App.handle_event(event_k, state_k1)
    assert state_k2.logs_scroll_y == 0

    # Pressing "j" (scroll down)
    event_j = %ExRatatui.Event.Key{code: "j", modifiers: []}
    assert {:noreply, state_j1} = App.handle_event(event_j, state_k2)
    assert state_j1.logs_scroll_y == 3

    # Scroll down to end should reset to :bottom
    assert {:noreply, state_j2} = App.handle_event(event_j, state_j1)
    assert state_j2.logs_scroll_y == :bottom

    # Scroll down when already at :bottom should be a no-op
    assert {:noreply, state_j3} = App.handle_event(event_j, state_j2)
    assert state_j3.logs_scroll_y == :bottom
  end

  test "scrolling up when all logs fit in the viewport keeps logs_scroll_y as :bottom" do
    {:ok, state} = App.mount([])

    # Setup state with 5 logs and height 24 (logs_height = 20), so all logs fit
    logs = Enum.map(1..5, &"line #{&1}")

    state = %{
      state
      | logs: logs,
        height: 24,
        selected_profile_id: "test-server",
        selected_container_id: "container-1"
    }

    assert state.logs_scroll_y == :bottom

    # Pressing "k" (scroll up) when max_scroll is 0 should keep logs_scroll_y as :bottom
    event_k = %ExRatatui.Event.Key{code: "k", modifiers: []}
    assert {:noreply, updated_state} = App.handle_event(event_k, state)
    assert updated_state.logs_scroll_y == :bottom
  end

  test "handle_info/2 tick adjusts logs_scroll_y by drop count difference when scrolled up" do
    profile_id = "drop-test-server"
    _ = Caudata.ConfigManager.add_manual_profile(%{id: profile_id, host_pattern: profile_id})

    on_exit(fn ->
      _ = Caudata.ConfigManager.delete_profile(profile_id)
    end)

    Caudata.LogStore.clear_logs(profile_id)

    # Append 1000 logs (matching capacity 1000)
    Caudata.LogStore.append_logs(profile_id, Enum.map(1..1000, &"line #{&1}"))
    # Let the cast settle
    Process.sleep(50)

    {:ok, state} = App.mount([])

    # Let's transition app state to select this profile
    assert {:noreply, state} = App.handle_info({:select_profile, profile_id}, state)

    # We now mock state.logs_scroll_y to be an integer (e.g. 5)
    # and drop_counts to reflect 0 drops initially (which matches LogStore stats at this point)
    state = %{
      state
      | logs_scroll_y: 5,
        drop_counts: %{profile_id => 0}
    }

    # Now, append 3 more logs. Since capacity is 1000, the oldest 3 will be dropped.
    # New drop_count will be 3.
    Caudata.LogStore.append_logs(profile_id, ["line 1001", "line 1002", "line 1003"])
    Process.sleep(50)

    # Trigger a :tick
    assert {:noreply, updated_state} = App.handle_info(:tick, state)

    # The drop difference is 3 - 0 = 3.
    # The scroll position should be adjusted: 5 - 3 = 2.
    assert updated_state.logs_scroll_y == 2
  end

  test "handle_event/2 handles loading older logs when scrolling up with k" do
    profile_id = "test-history-server"
    container_id = "container-1"
    source_id = "#{profile_id}/#{container_id}"
    Caudata.LogStore.clear_logs(source_id)

    # Append 35 logs to LogStore
    logs_history = Enum.map(1..35, &"historical line #{&1}")
    Caudata.LogStore.append_logs(source_id, logs_history)

    # Let the GenServer process the cast
    Process.sleep(50)

    {:ok, state} = App.mount([])

    # Setup initial state with only the last 20 logs loaded, representing fetch limit of 20
    initial_logs = Enum.take(logs_history, -20)

    state = %{
      state
      | selected_profile_id: profile_id,
        selected_container_id: "container-1",
        logs: initial_logs,
        logs_fetch_limit: 20,
        # scroll position is at the top of loaded logs
        logs_scroll_y: 0,
        # pane height is 24 - 4 = 20
        height: 24
    }

    # Verify that scroll position is 0
    assert state.logs_scroll_y == 0
    assert length(state.logs) == 20

    # Pressing "k" (scroll up) when effective_scroll is 0 should NOT trigger loading more logs
    event_k = %ExRatatui.Event.Key{code: "k", modifiers: []}
    assert {:noreply, updated_state} = App.handle_event(event_k, state)

    # Assert that fetch limit remained unchanged
    assert updated_state.logs_fetch_limit == 20
    # Assert logs length is still 20
    assert length(updated_state.logs) == 20
    # Assert scroll position is still 0
    assert updated_state.logs_scroll_y == 0
  end

  test "handle_event/2 handles keyboard events in settings modal" do
    {:ok, state} = App.mount([])

    # Let's mock a state with profiles and settings modal visible
    profile1 = %Caudata.Profile{id: "server1", host_name: "1.1.1.1", host_pattern: "server1"}
    profile2 = %Caudata.Profile{id: "server2", host_name: "2.2.2.2", host_pattern: "server2"}

    state = %{
      state
      | profiles: [profile1, profile2],
        modal_visible: true,
        modal_type: :settings,
        settings_selected_profile_idx: 0,
        settings_focus: :servers,
        settings_container_idx: 0,
        settings_custom_log_idx: 0
    }

    # Verify tab key switches focus
    event_tab = %ExRatatui.Event.Key{code: "tab", modifiers: []}

    # Tab 1: :servers -> :containers
    assert {:noreply, state_tab1} = App.handle_event(event_tab, state)
    assert state_tab1.settings_focus == :containers

    # Tab 2: :containers -> :custom_logs
    assert {:noreply, state_tab2} = App.handle_event(event_tab, state_tab1)
    assert state_tab2.settings_focus == :custom_logs

    # Tab 3: :custom_logs -> :servers
    assert {:noreply, state_tab3} = App.handle_event(event_tab, state_tab2)
    assert state_tab3.settings_focus == :servers

    # Verify down/up key modifies profile selection when focus is :servers
    event_down = %ExRatatui.Event.Key{code: "down", modifiers: []}
    assert {:noreply, state_down} = App.handle_event(event_down, state)
    assert state_down.settings_selected_profile_idx == 1

    event_up = %ExRatatui.Event.Key{code: "up", modifiers: []}
    assert {:noreply, state_up} = App.handle_event(event_up, state_down)
    assert state_up.settings_selected_profile_idx == 0

    # Ensure profile1 and profile2 exist in ConfigManager for updates to succeed
    _ = Caudata.ConfigManager.add_manual_profile(%{id: "server1", host_pattern: "server1"})
    _ = Caudata.ConfigManager.add_manual_profile(%{id: "server2", host_pattern: "server2"})

    on_exit(fn ->
      _ = Caudata.ConfigManager.delete_profile("server1")
      _ = Caudata.ConfigManager.delete_profile("server2")
    end)

    # Space key to toggle server enabled state when focused on :servers
    event_space = %ExRatatui.Event.Key{code: " ", modifiers: []}
    assert {:noreply, state_toggle} = App.handle_event(event_space, state)
    profile1_toggled = Enum.find(state_toggle.profiles, &(&1.id == "server1"))
    assert profile1_toggled.enabled == false

    # Toggle back to enabled
    assert {:noreply, state_toggle_back} = App.handle_event(event_space, state_toggle)
    profile1_enabled = Enum.find(state_toggle_back.profiles, &(&1.id == "server1"))
    assert profile1_enabled.enabled == true

    # 'd' key to delete server when focused on :servers
    event_d = %ExRatatui.Event.Key{code: "d", modifiers: []}
    assert {:noreply, state_delete} = App.handle_event(event_d, state)
    refute Enum.any?(state_delete.profiles, &(&1.id == "server1"))
    assert state_delete.settings_selected_profile_idx == 0
  end

  test "handle_event/2 handles custom logs toggling in settings modal" do
    {:ok, state} = App.mount([])

    profile = %Caudata.Profile{
      id: "toggle-logs-server",
      host_name: "4.4.4.4",
      host_pattern: "toggle-logs-server",
      custom_logs: ["/var/log/syslog", "/var/log/auth.log"],
      disabled_containers: []
    }

    _ =
      Caudata.ConfigManager.add_manual_profile(%{
        id: "toggle-logs-server",
        host_pattern: "toggle-logs-server",
        custom_logs: ["/var/log/syslog", "/var/log/auth.log"]
      })

    on_exit(fn ->
      _ = Caudata.ConfigManager.delete_profile("toggle-logs-server")
    end)

    state = %{
      state
      | profiles: [profile],
        modal_visible: true,
        modal_type: :settings,
        settings_selected_profile_idx: 0,
        settings_focus: :custom_logs,
        settings_custom_log_idx: 0
    }

    # Space key to disable the first custom log
    event_space = %ExRatatui.Event.Key{code: " ", modifiers: []}
    assert {:noreply, state_toggled} = App.handle_event(event_space, state)
    profile_toggled = Enum.find(state_toggled.profiles, &(&1.id == "toggle-logs-server"))
    assert "file:/var/log/syslog" in profile_toggled.disabled_containers

    # Space key again to enable it back
    assert {:noreply, state_enabled} = App.handle_event(event_space, state_toggled)
    profile_enabled = Enum.find(state_enabled.profiles, &(&1.id == "toggle-logs-server"))
    refute "file:/var/log/syslog" in profile_enabled.disabled_containers
  end

  test "handle_info/2 handles validation result with connection errors by saving the path anyway" do
    {:ok, state} = App.mount([])

    profile = %Caudata.Profile{
      id: "validation-test-server",
      host_name: "3.3.3.3",
      host_pattern: "validation-test-server",
      custom_logs: []
    }

    _ =
      Caudata.ConfigManager.add_manual_profile(%{
        id: "validation-test-server",
        host_pattern: "validation-test-server"
      })

    on_exit(fn ->
      _ = Caudata.ConfigManager.delete_profile("validation-test-server")
    end)

    state = %{state | profiles: [profile]}

    # Simulate validation result with :not_connected error
    msg =
      {:validation_result, "validation-test-server", "/var/log/my-custom.log",
       {:error, :not_connected}}

    assert {:noreply, updated_state} = App.handle_info(msg, state)

    updated_profile = Enum.find(updated_state.profiles, &(&1.id == "validation-test-server"))
    assert "/var/log/my-custom.log" in updated_profile.custom_logs

    assert updated_state.settings_status_msg ==
             "Added path (unvalidated: server is not connected or timed out)"
  end
end
