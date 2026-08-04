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

  test "handle_info/2 handles regex filter compile safely and negative filter !" do
    {:ok, state} = App.mount([])

    # Invalid regex
    assert {:noreply, updated_state} = App.handle_info({:update_filter, "[invalid("}, state)
    assert updated_state.filter_regex == "[invalid("
    assert updated_state.filter_error == true

    # Valid regex
    assert {:noreply, updated_state2} = App.handle_info({:update_filter, "valid.*regex"}, state)
    assert updated_state2.filter_regex == "valid.*regex"
    assert updated_state2.filter_error == false

    # Single ! (no error)
    assert {:noreply, updated_state3} = App.handle_info({:update_filter, "!"}, state)
    assert updated_state3.filter_regex == "!"
    assert updated_state3.filter_error == false

    # Negative filter !healthz (valid)
    assert {:noreply, updated_state4} = App.handle_info({:update_filter, "!healthz"}, state)
    assert updated_state4.filter_regex == "!healthz"
    assert updated_state4.filter_error == false
  end

  test "handle_event/2 handles Ctrl+C and 'q' to quit application" do
    {:ok, state} = App.mount([])

    event_q = %ExRatatui.Event.Key{code: "q", modifiers: []}
    assert {:stop, _state} = App.handle_event(event_q, state)

    event_ctrl_c = %ExRatatui.Event.Key{code: "c", modifiers: ["ctrl"]}
    assert {:stop, _state} = App.handle_event(event_ctrl_c, state)

    event_ctrl_c_capital = %ExRatatui.Event.Key{code: "C", modifiers: ["ctrl"]}
    assert {:stop, _state} = App.handle_event(event_ctrl_c_capital, state)
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

  test "handle_event/2 handles tab and arrow navigation in 4-box layout" do
    {:ok, state} = App.mount([])

    if length(state.profiles) > 1 do
      [p1, p2 | _] = state.profiles

      state = %{
        state
        | containers: %{
            p1.id => [
              %{id: "c1", name: "container-1"},
              %{id: "c2", name: "container-2"}
            ],
            p2.id => [
              %{id: "c3", name: "container-3"}
            ]
          },
          selected_profile_id: p1.id,
          selected_container_id: "c1",
          sidebar_focus: :servers
      }

      # Pressing 'tab' switches focus to :containers
      event_tab = %ExRatatui.Event.Key{code: "tab", modifiers: []}
      assert {:noreply, state_focused_containers} = App.handle_event(event_tab, state)
      assert state_focused_containers.sidebar_focus == :containers

      # ArrowDown when in :containers focus moves to the next container
      event_down = %ExRatatui.Event.Key{code: "down", modifiers: []}

      assert {:noreply, state_next_container} =
               App.handle_event(event_down, state_focused_containers)

      assert state_next_container.selected_profile_id == p1.id
      assert state_next_container.selected_container_id == "c2"

      # Pressing 'tab' again switches back to :servers
      assert {:noreply, state_refocused_servers} =
               App.handle_event(event_tab, state_next_container)

      assert state_refocused_servers.sidebar_focus == :servers

      # ArrowDown when in :servers focus changes the active server (and selects its first container)
      assert {:noreply, state_next_server} = App.handle_event(event_down, state_refocused_servers)
      assert state_next_server.selected_profile_id == p2.id
      assert state_next_server.selected_container_id == "c3"
    end
  end

  test "handle_event/2 wrap-around navigation in servers and containers lists" do
    {:ok, state} = App.mount([])

    # Use exactly 2 mock profiles to guarantee deterministic wrap-around behavior
    p1 = %{id: "wrap-p1", host_name: "server-1", disabled_containers: []}
    p2 = %{id: "wrap-p2", host_name: "server-2", disabled_containers: []}

    state = %{
      state
      | profiles: [p1, p2],
        containers: %{
          p1.id => [
            %{id: "c1", name: "container-1"},
            %{id: "c2", name: "container-2"}
          ],
          p2.id => [
            %{id: "c3", name: "container-3"}
          ]
        },
        selected_profile_id: p2.id,
        selected_container_id: "c3",
        sidebar_focus: :servers
    }

    event_down = %ExRatatui.Event.Key{code: "down", modifiers: []}
    event_up = %ExRatatui.Event.Key{code: "up", modifiers: []}

    # 1. Servers wrap-around:
    # Currently at the last server (p2). Down should wrap around to the first server (p1).
    assert {:noreply, state_wrap_down_server} = App.handle_event(event_down, state)
    assert state_wrap_down_server.selected_profile_id == p1.id
    assert state_wrap_down_server.selected_container_id == "c1"

    # Set to the first server (p1). Up should wrap around to the last server (p2).
    state_at_first_server = %{state | selected_profile_id: p1.id, selected_container_id: "c1"}
    assert {:noreply, state_wrap_up_server} = App.handle_event(event_up, state_at_first_server)
    assert state_wrap_up_server.selected_profile_id == p2.id
    assert state_wrap_up_server.selected_container_id == "c3"

    # 2. Containers wrap-around:
    # Focus containers for p1 (which has "c1" and "c2")
    state_containers_focus = %{
      state
      | selected_profile_id: p1.id,
        selected_container_id: "c2",
        sidebar_focus: :containers
    }

    # Currently at last container (c2). Down should wrap around to the first container (c1).
    assert {:noreply, state_wrap_down_container} =
             App.handle_event(event_down, state_containers_focus)

    assert state_wrap_down_container.selected_profile_id == p1.id
    assert state_wrap_down_container.selected_container_id == "c1"

    # Set to the first container (c1). Up should wrap around to the last container (c2).
    state_containers_focus_first = %{state_containers_focus | selected_container_id: "c1"}

    assert {:noreply, state_wrap_up_container} =
             App.handle_event(event_up, state_containers_focus_first)

    assert state_wrap_up_container.selected_profile_id == p1.id
    assert state_wrap_up_container.selected_container_id == "c2"
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

    # In manual_input, pressing tab changes focus
    event_tab = %ExRatatui.Event.Key{code: "tab", modifiers: []}
    assert {:noreply, tabbed_state} = App.handle_event(event_tab, manual_state)
    assert tabbed_state.modal_focus_index == 1

    # Pressing shift+tab changes focus back
    event_shift_tab = %ExRatatui.Event.Key{code: "tab", modifiers: ["shift"]}
    assert {:noreply, shift_tabbed_state} = App.handle_event(event_shift_tab, tabbed_state)
    assert shift_tabbed_state.modal_focus_index == 0

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

    # Pressing enter with empty host_name when focused on Save button (index 6) shows error
    save_focused_state = %{manual_state | modal_focus_index: 6}
    assert {:noreply, err_state} = App.handle_event(event_enter, save_focused_state)
    assert err_state.modal_error == "Host/IP is required"

    # Testing duplicate ID error
    existing_profile = %Caudata.Profile{
      id: "duplicate-server",
      host_name: "1.1.1.1",
      host_pattern: "duplicate-server"
    }

    manual_state_with_profile = %{
      manual_state
      | profiles: [existing_profile],
        modal_fields: %{
          "id" => "duplicate-server",
          "host_name" => "2.2.2.2",
          "port" => "22",
          "user" => "",
          "identity_file" => "",
          "password" => ""
        },
        modal_focus_index: 6
    }

    assert {:noreply, dup_err_state} = App.handle_event(event_enter, manual_state_with_profile)
    assert dup_err_state.modal_error == "Connection Name/ID already exists"

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
        selected_container_id: "container-1",
        active_panel: :logs
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

  test "handle_event/2 accelerates scroll speed when holding/pressing j or k repeatedly" do
    {:ok, state} = App.mount([])

    # Setup some test logs (100 lines) and standard viewport height (24 lines)
    # Visible height is 20, max_scroll = 100 - 20 = 80.
    logs = Enum.map(1..100, &"line #{&1}")

    state = %{
      state
      | logs: logs,
        height: 24,
        selected_profile_id: "test-server",
        selected_container_id: "container-1",
        active_panel: :logs
    }

    # Start scroll position at 70 (scrolled up somewhat, so we have room to go up or down)
    state = %{state | logs_scroll_y: 70}

    event_k = %ExRatatui.Event.Key{code: "k", modifiers: []}

    # 1. First press of "k" - step size should be 3
    assert {:noreply, state_1} = App.handle_event(event_k, state)
    assert state_1.consecutive_key_count == 1
    # 70 - 3 = 67
    assert state_1.logs_scroll_y == 67

    # 2. Press "k" 4 more times (total 5 presses). All should use step size of 3.
    state_5 =
      Enum.reduce(1..4, state_1, fn _, acc_state ->
        {:noreply, next_state} = App.handle_event(event_k, acc_state)
        next_state
      end)

    assert state_5.consecutive_key_count == 5
    # 67 - (4 * 3) = 55
    assert state_5.logs_scroll_y == 55

    # 3. 6th press of "k" should trigger acceleration step size of 6
    assert {:noreply, state_6} = App.handle_event(event_k, state_5)
    assert state_6.consecutive_key_count == 6
    # 55 - 6 = 49
    assert state_6.logs_scroll_y == 49

    # 4. Press "k" 9 more times (total 15 presses).
    state_15 =
      Enum.reduce(1..9, state_6, fn _, acc_state ->
        {:noreply, next_state} = App.handle_event(event_k, acc_state)
        next_state
      end)

    assert state_15.consecutive_key_count == 15
    # To test further acceleration, let's reset scroll position in state_15 before the 16th press
    state_15 = %{state_15 | logs_scroll_y: 50}

    # 5. 16th press of "k" should trigger maximum acceleration step size of 15
    assert {:noreply, state_16} = App.handle_event(event_k, state_15)
    assert state_16.consecutive_key_count == 16
    # 50 - 15 = 35
    assert state_16.logs_scroll_y == 35

    # 6. Pressing a different key (like "j") should reset consecutive count
    event_j = %ExRatatui.Event.Key{code: "j", modifiers: []}
    assert {:noreply, state_j} = App.handle_event(event_j, state_16)
    assert state_j.consecutive_key_count == 1
    # 35 + 3 = 38
    assert state_j.logs_scroll_y == 38

    # 7. Pressing after a delay should reset consecutive count
    # Simulate a delay by setting last_key_time to 5 seconds ago
    state_delayed = %{state_j | last_key_time: System.monotonic_time(:millisecond) - 5000}
    assert {:noreply, state_j_delayed} = App.handle_event(event_j, state_delayed)
    assert state_j_delayed.consecutive_key_count == 1
    # 38 + 3 = 41
    assert state_j_delayed.logs_scroll_y == 41
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

  test "handle_info/2 logs_updated adjusts logs_scroll_y by drop count difference when scrolled up" do
    profile_id = "drop-test-server-#{System.unique_integer([:positive])}"
    source_id = profile_id
    Caudata.LogStore.clear_logs(source_id)

    initial_logs = Enum.map(1..10, &%{timestamp: nil, stream: :stdout, message: "log line #{&1}"})

    {:ok, state} = App.mount([])

    # Mock the state to have a selected profile, scroll position, and initial drop counts
    state = %{
      state
      | selected_profile_id: profile_id,
        selected_container_id: nil,
        logs: initial_logs,
        logs_scroll_y: 5,
        logs_fetch_limit: 10,
        drop_counts: %{profile_id => 0}
    }

    # Now, the LogStore gets updated with new logs, shifting the window
    new_store_logs =
      Enum.map(4..13, &%{timestamp: nil, stream: :stdout, message: "log line #{&1}"})

    Caudata.LogStore.append_logs(source_id, new_store_logs)
    :sys.get_state(Caudata.LogStore)

    # Simulate receiving logs_updated PubSub event
    msg = {:logs_updated, profile_id, %{size: 10, drop_count: 3}}
    assert {:noreply, updated_state} = App.handle_info(msg, state)

    # At this point (before tick), logs_scroll_y is still 5
    assert updated_state.logs_scroll_y == 5
    assert updated_state.drop_counts[profile_id] == 3
    assert updated_state.buffer_sizes[profile_id] == 10
    assert updated_state.logs_dirty == true

    # Now simulate the :tick event
    assert {:noreply, ticked_state} = App.handle_info(:tick, updated_state)

    # The first 3 logs are dropped from the snapshot, so scroll position is adjusted: 5 - 3 = 2
    assert ticked_state.logs_scroll_y == 2
    assert ticked_state.logs == new_store_logs
  end

  test "when scrolled up, receiving new logs does not auto-scroll and keeps viewport stable" do
    profile_id = "stable-test-server-#{System.unique_integer([:positive])}"
    container_id = "container-1"
    source_id = "#{profile_id}/#{container_id}"
    Caudata.LogStore.clear_logs(source_id)

    # Initial logs: 15 lines. Capped at 15 fetch limit.
    initial_logs = Enum.map(1..15, &%{timestamp: nil, stream: :stdout, message: "log line #{&1}"})
    Caudata.LogStore.append_logs(source_id, initial_logs)
    :sys.get_state(Caudata.LogStore)

    {:ok, state} = App.mount([])

    state = %{
      state
      | selected_profile_id: profile_id,
        selected_container_id: container_id,
        logs_fetch_limit: 15,
        logs_scroll_y: :bottom,
        active_panel: :logs
    }

    # 1. First tick to populate logs
    assert {:noreply, state1} = App.handle_info(:tick, state)
    assert state1.logs == initial_logs
    assert state1.logs_scroll_y == :bottom

    # 2. Scroll up by 3 lines (simulating pressing 'k')
    # logs_height = 10 - 4 = 6
    state1 = %{state1 | height: 10}
    event_k = %ExRatatui.Event.Key{code: "k", modifiers: []}
    assert {:noreply, state_scrolled} = App.handle_event(event_k, state1)
    # max_scroll is 15 - 6 = 9. Scrolling up by 3 steps should set it to 9 - 3 = 6.
    assert state_scrolled.logs_scroll_y == 6
    assert state_scrolled.freeze == true

    # 3. Now 5 new logs are appended to LogStore (total 20 logs).
    # Since logs_fetch_limit is 15, the new snapshot will be lines 6 to 20.
    new_store_logs =
      Enum.map(6..20, &%{timestamp: nil, stream: :stdout, message: "log line #{&1}"})

    Caudata.LogStore.clear_logs(source_id)
    Caudata.LogStore.append_logs(source_id, new_store_logs)
    :sys.get_state(Caudata.LogStore)

    # PubSub message
    msg = {:logs_updated, source_id, %{size: 15, drop_count: 5}}
    assert {:noreply, state_msg} = App.handle_info(msg, state_scrolled)
    # remains 6 before tick
    assert state_msg.logs_scroll_y == 6
    assert state_msg.freeze == true

    # 4. Handle tick (should not fetch new logs since we are frozen)
    assert {:noreply, state_ticked} = App.handle_info(:tick, state_msg)
    assert state_ticked.logs == initial_logs
    assert state_ticked.logs_scroll_y == 6

    # 5. Scroll down by 3 lines (simulating pressing 'j')
    # 6 + 3 = 9. Since max_scroll is 9, it should set scroll_y to :bottom and unfreeze.
    event_j = %ExRatatui.Event.Key{code: "j", modifiers: []}
    assert {:noreply, state_bottom} = App.handle_event(event_j, state_ticked)
    assert state_bottom.logs_scroll_y == :bottom
    assert state_bottom.freeze == false

    # 6. Now handle tick (should fetch new logs because we are unfrozen)
    assert {:noreply, state_final} = App.handle_info(:tick, state_bottom)
    assert state_final.logs == new_store_logs
    assert state_final.logs_scroll_y == :bottom
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

    # Setup initial state with 25 logs loaded (more than the viewport of 20), scroll at top
    initial_logs = Enum.take(logs_history, -25)

    state = %{
      state
      | selected_profile_id: profile_id,
        selected_container_id: "container-1",
        logs: initial_logs,
        logs_fetch_limit: 25,
        # scroll position is at the top of loaded logs
        logs_scroll_y: 0,
        # pane height is 24 - 4 = 20
        height: 24,
        active_panel: :logs
    }

    # Verify that scroll position is 0
    assert state.logs_scroll_y == 0
    assert length(state.logs) == 25

    # Pressing "k" (scroll up) when effective_scroll is 0 should trigger loading more logs
    event_k = %ExRatatui.Event.Key{code: "k", modifiers: []}
    assert {:noreply, updated_state} = App.handle_event(event_k, state)

    # Assert that fetch limit increased by 1000 (capped at 10000)
    assert updated_state.logs_fetch_limit == 1025
    # Assert logs now contain all 35 lines from LogStore
    assert length(updated_state.logs) == 35
    # Assert loading_history is reset to false
    assert updated_state.loading_history == false
    # Assert scroll is adjusted to keep the view stable (10 new lines above the original 25)
    # m = 35 - 25 = 10, displayed = 35, height = 20, max_scroll = 15, scroll = min(15, 9) = 9
    assert updated_state.logs_scroll_y == 9
  end

  test "handle_event/2 handles loading older logs when scrolling up with k in selecting mode" do
    profile_id = "test-history-server-select"
    container_id = "container-1"
    source_id = "#{profile_id}/#{container_id}"
    Caudata.LogStore.clear_logs(source_id)

    # Append 35 logs to LogStore
    logs_history = Enum.map(1..35, &"historical line #{&1}")
    Caudata.LogStore.append_logs(source_id, logs_history)

    # Let the GenServer process the cast
    Process.sleep(50)

    {:ok, state} = App.mount([])

    # Setup initial state with 25 logs loaded (more than the viewport of 20), scroll at top
    initial_logs = Enum.take(logs_history, -25)

    state = %{
      state
      | selected_profile_id: profile_id,
        selected_container_id: "container-1",
        logs: initial_logs,
        logs_fetch_limit: 25,
        # scroll position is at the top of loaded logs
        logs_scroll_y: 0,
        # pane height is 24 - 4 = 20
        height: 24,
        mode: :selecting,
        visual_cursor: 0,
        visual_anchor: nil,
        active_panel: :logs
    }

    # Verify that scroll position is 0
    assert state.logs_scroll_y == 0
    assert length(state.logs) == 25

    # Pressing "k" (scroll up) when effective_scroll is 0 should trigger loading more logs
    event_k = %ExRatatui.Event.Key{code: "k", modifiers: []}
    assert {:noreply, updated_state} = App.handle_event(event_k, state)

    # Assert logs now contain all 35 lines from LogStore
    assert length(updated_state.logs) == 35
    # Assert loading_history is reset to false
    assert updated_state.loading_history == false
    # Assert scroll is adjusted to keep the view stable (10 new lines above the original 25)
    assert updated_state.logs_scroll_y == 9
    # Assert visual_cursor shifted from 0 to 10
    assert updated_state.visual_cursor == 10
    assert updated_state.visual_anchor == nil
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

    # Tab 1: :servers -> :connection
    assert {:noreply, state_tab0} = App.handle_event(event_tab, state)
    assert state_tab0.settings_focus == :connection

    # Tab 2: :connection -> :containers
    assert {:noreply, state_tab1} = App.handle_event(event_tab, state_tab0)
    assert state_tab1.settings_focus == :containers

    # Tab 2b: :containers -> :services
    assert {:noreply, state_tab1b} = App.handle_event(event_tab, state_tab1)
    # Tab 3: :services -> :custom_logs
    assert {:noreply, state_tab2} = App.handle_event(event_tab, state_tab1b)
    assert state_tab2.settings_focus == :custom_logs

    # Tab 4: :custom_logs -> :servers
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
    assert state_delete.modal_visible == true
    assert state_delete.modal_type == :confirm_delete_server
    assert state_delete.delete_server_id == "server1"

    # 'y' key to confirm deletion
    event_y = %ExRatatui.Event.Key{code: "y", modifiers: []}
    assert {:noreply, state_confirmed} = App.handle_event(event_y, state_delete)
    refute Enum.any?(state_confirmed.profiles, &(&1.id == "server1"))
    assert state_confirmed.modal_visible == false
    assert state_confirmed.notification != nil
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

  test "handle_event/2 handles services toggling in settings modal" do
    {:ok, state} = App.mount([])

    profile = %Caudata.Profile{
      id: "toggle-logs-server",
      host_name: "4.4.4.4",
      host_pattern: "toggle-logs-server",
      enabled_services: []
    }

    _ =
      Caudata.ConfigManager.add_manual_profile(%{
        id: "toggle-logs-server",
        host_pattern: "toggle-logs-server"
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
        settings_focus: :services,
        settings_service_idx: 0,
        containers: %{
          "toggle-logs-server" => [
            %{
              id: "systemd:nginx.service",
              name: "nginx.service",
              image: "systemd",
              status: "active",
              state: "running"
            }
          ]
        }
    }

    # Space key to enable the service
    event_space = %ExRatatui.Event.Key{code: " ", modifiers: []}
    assert {:noreply, state_toggled} = App.handle_event(event_space, state)
    profile_toggled = Enum.find(state_toggled.profiles, &(&1.id == "toggle-logs-server"))
    assert "systemd:nginx.service" in profile_toggled.enabled_services

    # Space key again to disable it
    assert {:noreply, state_enabled} = App.handle_event(event_space, state_toggled)
    profile_enabled = Enum.find(state_enabled.profiles, &(&1.id == "toggle-logs-server"))
    refute "systemd:nginx.service" in profile_enabled.enabled_services
  end

  test "handle_event/2 filters system services by search query" do
    {:ok, state} = App.mount([])

    profile = %Caudata.Profile{
      id: "search-services-server",
      host_name: "5.5.5.5",
      host_pattern: "search-services-server",
      enabled_services: []
    }

    _ =
      Caudata.ConfigManager.add_manual_profile(%{
        id: "search-services-server",
        host_pattern: "search-services-server"
      })

    on_exit(fn ->
      _ = Caudata.ConfigManager.delete_profile("search-services-server")
    end)

    state = %{
      state
      | profiles: [profile],
        modal_visible: true,
        modal_type: :settings,
        settings_selected_profile_idx: 0,
        settings_focus: :services,
        settings_service_idx: 0,
        containers: %{
          "search-services-server" => [
            %{
              id: "systemd:nginx.service",
              name: "nginx.service",
              image: "systemd",
              status: "active"
            },
            %{id: "systemd:ssh.service", name: "ssh.service", image: "systemd", status: "active"},
            %{
              id: "systemd:docker.service",
              name: "docker.service",
              image: "systemd",
              status: "active"
            }
          ]
        }
    }

    # Press "/" to enter search mode
    event_slash = %ExRatatui.Event.Key{code: "/", modifiers: []}
    assert {:noreply, state_searching} = App.handle_event(event_slash, state)
    assert state_searching.settings_service_search_active

    # Type "nginx" by sending chars one at a time
    state_with_query =
      Enum.reduce(String.graphemes("nginx"), state_searching, fn ch, acc ->
        event = %ExRatatui.Event.Key{code: ch, modifiers: []}
        {:noreply, next} = App.handle_event(event, acc)
        next
      end)

    assert state_with_query.settings_service_search == "nginx"
    assert state_with_query.settings_service_search_active

    # Press Enter to apply filter and exit search mode (query retained)
    event_enter = %ExRatatui.Event.Key{code: "enter", modifiers: []}
    assert {:noreply, state_applied} = App.handle_event(event_enter, state_with_query)

    assert state_applied.settings_service_search == "nginx"
    refute state_applied.settings_service_search_active

    # To modify the filter: press "/" to re-enter search mode (keeps existing query)
    event_slash_again = %ExRatatui.Event.Key{code: "/", modifiers: []}
    assert {:noreply, state_editing} = App.handle_event(event_slash_again, state_applied)
    assert state_editing.settings_service_search_active
    assert state_editing.settings_service_search == "nginx"

    # Backspace deletes the last char one at a time
    event_bs = %ExRatatui.Event.Key{code: "backspace", modifiers: []}
    assert {:noreply, state_bs} = App.handle_event(event_bs, state_editing)
    assert state_bs.settings_service_search == "ngin"

    # Setup state with broad filter "service" matching all 3 services so we can navigate down
    state_broad = %{state_editing | settings_service_search: "service"}

    # Press down while searching: should navigate list but keep search active
    event_down = %ExRatatui.Event.Key{code: "down", modifiers: []}
    assert {:noreply, state_navigated} = App.handle_event(event_down, state_broad)
    assert state_navigated.settings_service_search_active
    assert state_navigated.settings_service_idx == 1
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

  test "LogsPane.render/2 formats log lines with color spans" do
    alias Caudata.UI.Components.LogsPane
    alias ExRatatui.Layout.Rect

    # Prepare some mock state
    profile = %Caudata.Profile{
      id: "test-server",
      host_name: "1.1.1.1",
      host_pattern: "test-server"
    }

    state = %{
      profiles: [profile],
      selected_profile_id: "test-server",
      selected_container_id: "container-1",
      containers: %{"test-server" => [%{id: "container-1", name: "c1"}]},
      logs: [
        "15:33:22.268 [info] Running Caudata",
        "2026-06-08 15:33:22 ERROR: Database error",
        "[warn] API warning",
        "Just a plain message",
        "[stderr] system error output",
        "2026-06-08 15:33:22 crit: Critical system issue",
        "fail: operation failed"
      ],
      logs_scroll_y: :bottom,
      filter_regex: "",
      filter_error: false,
      mode: :browsing,
      width: 80,
      height: 24
    }

    area = %Rect{x: 0, y: 0, width: 80, height: 20}
    {_outer_block, content} = LogsPane.render(state, area)

    # Content should be a list of tuples like {paragraph, inner_rect}
    assert [{paragraph, _} | _] = content
    assert is_list(paragraph.text)

    # We should have 7 formatted Lines in the paragraph text
    assert length(paragraph.text) == 7

    # Let's inspect the Spans of each Line to verify formatting:
    # 1. "15:33:22.268 [info] Running Caudata" -> prefix, ts, bracket_lvl, msg
    line1 = Enum.at(paragraph.text, 0)
    assert [span_pref, span_ts, span_lvl, span_msg] = line1.spans
    assert span_pref.content == "  "
    assert span_ts.content == "15:33:22.268 "
    assert span_ts.style.fg == :dark_gray
    assert span_lvl.content == "[info] "
    assert span_lvl.style.fg == :green
    assert :bold in span_lvl.style.modifiers
    assert span_msg.content == "Running Caudata"

    # 2. "2026-06-08 15:33:22 ERROR: Database error" -> prefix, ts, colon_lvl, msg
    line2 = Enum.at(paragraph.text, 1)
    assert [span_pref2, span_ts2, span_lvl2, span_msg2] = line2.spans
    assert span_pref2.content == "┃ "
    assert span_ts2.content == "2026-06-08 15:33:22 "
    assert span_ts2.style.fg == :dark_gray
    assert span_lvl2.content == "ERROR: "
    assert span_lvl2.style.fg == :red
    assert :bold in span_lvl2.style.modifiers
    assert span_msg2.content == "Database error"
    assert span_msg2.style.fg == :white

    # 3. "[warn] API warning" -> prefix, bracket_lvl, msg (no timestamp)
    line3 = Enum.at(paragraph.text, 2)
    assert [span_pref3, span_lvl3, span_msg3] = line3.spans
    assert span_pref3.content == "  "
    assert span_lvl3.content == "[warn] "
    assert span_lvl3.style.fg == :yellow
    assert :bold in span_lvl3.style.modifiers
    assert span_msg3.content == "API warning"
    assert span_msg3.style.fg == :white

    # 4. "Just a plain message" -> prefix, msg (no timestamp, no level)
    line4 = Enum.at(paragraph.text, 3)
    assert [span_pref4, span_msg4] = line4.spans
    assert span_pref4.content == "  "
    assert span_msg4.content == "Just a plain message"
    assert span_msg4.style.fg == :white

    # 5. "[stderr] system error output" -> prefix, bracket_lvl, msg
    line5 = Enum.at(paragraph.text, 4)
    assert [span_pref5, span_lvl5, span_msg5] = line5.spans
    assert span_pref5.content == "┃ "
    assert span_lvl5.content == "[stderr] "
    assert span_lvl5.style.fg == :red
    assert :bold in span_lvl5.style.modifiers
    assert span_msg5.content == "system error output"
    assert span_msg5.style.fg == :white

    # 6. "2026-06-08 15:33:22 crit: Critical system issue" -> prefix, ts, colon_lvl, msg
    line6 = Enum.at(paragraph.text, 5)
    assert [span_pref6, span_ts6, span_lvl6, span_msg6] = line6.spans
    assert span_pref6.content == "┃ "
    assert span_ts6.content == "2026-06-08 15:33:22 "
    assert span_lvl6.content == "crit: "
    assert span_lvl6.style.fg == :red
    assert :bold in span_lvl6.style.modifiers
    assert span_msg6.content == "Critical system issue"
    assert span_msg6.style.fg == :white

    # 7. "fail: operation failed" -> prefix, colon_lvl, msg
    line7 = Enum.at(paragraph.text, 6)
    assert [span_pref7, span_lvl7, span_msg7] = line7.spans
    assert span_pref7.content == "┃ "
    assert span_lvl7.content == "fail: "
    assert span_lvl7.style.fg == :red
    assert :bold in span_lvl7.style.modifiers
    assert span_msg7.content == "operation failed"
    assert span_msg7.style.fg == :white
  end

  test "LogsPane.render/2 preserves leading spaces in continuation lines and messages" do
    alias Caudata.UI.Components.LogsPane
    alias ExRatatui.Layout.Rect

    # Prepare mock state
    profile = %Caudata.Profile{
      id: "test-server",
      host_name: "1.1.1.1",
      host_pattern: "test-server"
    }

    state = %{
      profiles: [profile],
      selected_profile_id: "test-server",
      selected_container_id: "container-1",
      containers: %{"test-server" => [%{id: "container-1", name: "c1"}]},
      logs: [
        "  continuation line starting with spaces",
        "2026-06-08 12:00:00 [info]   message with leading spaces",
        "2026-06-08 12:00:00   message with leading spaces and no level",
        "[info]   message with leading spaces and level"
      ],
      logs_scroll_y: :bottom,
      filter_regex: "",
      filter_error: false,
      mode: :browsing,
      width: 80,
      height: 24
    }

    area = %Rect{x: 0, y: 0, width: 80, height: 20}
    {_outer_block, content} = LogsPane.render(state, area)

    assert [{paragraph, _} | _] = content
    assert is_list(paragraph.text)
    assert length(paragraph.text) == 4

    # 1. "  continuation line starting with spaces" -> leading spaces should be fully preserved
    line1 = Enum.at(paragraph.text, 0)
    assert [span_pref1, span1] = line1.spans
    assert span_pref1.content == "  "
    assert span1.content == "  continuation line starting with spaces"

    # 2. "2026-06-08 12:00:00 [info]   message with leading spaces" -> should keep extra spaces after the separator
    line2 = Enum.at(paragraph.text, 1)
    assert [span_pref2, _ts, _lvl, span2] = line2.spans
    assert span_pref2.content == "  "
    assert span2.content == "  message with leading spaces"

    # 3. "2026-06-08 12:00:00   message with leading spaces and no level" -> should keep extra spaces after the separator
    line3 = Enum.at(paragraph.text, 2)
    assert [span_pref3, _ts, span3] = line3.spans
    assert span_pref3.content == "  "
    assert span3.content == "  message with leading spaces and no level"

    # 4. "[info]   message with leading spaces and level" -> should keep extra spaces after the separator
    line4 = Enum.at(paragraph.text, 3)
    assert [span_pref4, _lvl, span4] = line4.spans
    assert span_pref4.content == "  "
    assert span4.content == "  message with leading spaces and level"
  end

  test "handle_event/2 toggles logs_full_screen with f/F keys and esc key" do
    {:ok, state} = App.mount([])
    assert state.logs_full_screen == false

    # Pressing "f" toggles it to true
    event_f = %ExRatatui.Event.Key{code: "f", modifiers: []}
    assert {:noreply, state_f1} = App.handle_event(event_f, state)
    assert state_f1.logs_full_screen == true

    # Pressing "f" again toggles it back to false
    assert {:noreply, state_f2} = App.handle_event(event_f, state_f1)
    assert state_f2.logs_full_screen == false

    # Pressing "F" (uppercase) also toggles it to true
    event_F = %ExRatatui.Event.Key{code: "F", modifiers: []}
    assert {:noreply, state_F1} = App.handle_event(event_F, state)
    assert state_F1.logs_full_screen == true

    # Pressing "escape" when logs_full_screen is true toggles it back to false
    event_esc = %ExRatatui.Event.Key{code: "escape", modifiers: []}
    assert {:noreply, state_esc} = App.handle_event(event_esc, state_F1)
    assert state_esc.logs_full_screen == false
  end

  test "handle_info/2 logs_updated stores stats under correct container source_id" do
    u_id = System.unique_integer([:positive])
    profile_id = "test-server-#{u_id}"
    container_id = "test-container-#{u_id}"
    source_id = "#{profile_id}/#{container_id}"
    Caudata.LogStore.clear_logs(source_id)

    initial_logs = Enum.map(1..15, &%{timestamp: nil, stream: :stdout, message: "log line #{&1}"})

    {:ok, state} = App.mount([])

    state = %{
      state
      | selected_profile_id: profile_id,
        selected_container_id: container_id,
        logs: initial_logs,
        logs_scroll_y: 10,
        logs_fetch_limit: 15,
        drop_counts: %{source_id => 0}
    }

    # Append new logs shifting the window by 5
    new_store_logs =
      Enum.map(6..20, &%{timestamp: nil, stream: :stdout, message: "log line #{&1}"})

    Caudata.LogStore.append_logs(source_id, new_store_logs)
    :sys.get_state(Caudata.LogStore)

    # Simulate receiving logs_updated PubSub event for the container source
    msg = {:logs_updated, source_id, %{size: 250, drop_count: 5}}
    assert {:noreply, updated_state} = App.handle_info(msg, state)

    # Scroll remains 10 before tick
    assert updated_state.logs_scroll_y == 10
    assert updated_state.drop_counts[source_id] == 5
    assert updated_state.buffer_sizes[source_id] == 250
    assert updated_state.logs_dirty == true

    # Simulate :tick
    assert {:noreply, ticked_state} = App.handle_info(:tick, updated_state)

    # Scroll is adjusted by 5: 10 - 5 = 5
    assert ticked_state.logs_scroll_y == 5
    assert ticked_state.logs == new_store_logs
  end

  test "handle_info/2 container_rebuilt updates selected container ID and log subscription" do
    server_id = "test-server-rebuilt"
    old_id = "container-old"
    new_id = "container-new"
    container_name = "test-container"
    source_id = "#{server_id}/#{new_id}"

    Caudata.LogStore.clear_logs(source_id)

    new_logs = [
      %{timestamp: nil, stream: :stdout, message: "new log 1"},
      %{timestamp: nil, stream: :stdout, message: "new log 2"}
    ]

    Caudata.LogStore.append_logs(source_id, new_logs)
    :sys.get_state(Caudata.LogStore)

    {:ok, state} = App.mount([])

    state = %{
      state
      | selected_profile_id: server_id,
        selected_container_id: old_id,
        selected_container_name: container_name,
        logs: [
          %{timestamp: nil, stream: :stdout, message: "old log line 1"},
          %{timestamp: nil, stream: :stdout, message: "old log line 2"}
        ]
    }

    # Simulate container rebuild event
    msg = {:container_rebuilt, server_id, container_name, old_id, new_id}
    assert {:noreply, updated_state} = App.handle_info(msg, state)

    assert updated_state.selected_container_id == new_id
    assert updated_state.selected_container_name == container_name
    assert updated_state.logs_dirty == true
    assert updated_state.logs == new_logs

    # Simulate container rebuild event matching by name (when old_id is nil)
    state_with_nil_id = %{state | selected_container_id: "some-other-old-id"}
    msg_with_nil = {:container_rebuilt, server_id, container_name, nil, new_id}
    assert {:noreply, updated_state_nil} = App.handle_info(msg_with_nil, state_with_nil_id)

    assert updated_state_nil.selected_container_id == new_id
    assert updated_state_nil.selected_container_name == container_name
    assert updated_state_nil.logs_dirty == true
    assert updated_state_nil.logs == new_logs
  end

  describe "visual select & copy all" do
    test "pressing 'v' enters visual select mode" do
      {:ok, state} = App.mount([])

      state = %{
        state
        | selected_profile_id: "test-server",
          selected_container_id: "container-1",
          logs: ["line 1", "line 2", "line 3"]
      }

      event_v = %ExRatatui.Event.Key{code: "v", modifiers: []}
      assert {:noreply, visual_state} = App.handle_event(event_v, state)
      assert visual_state.mode == :selecting
      assert visual_state.visual_anchor == nil
      assert visual_state.visual_cursor == 2
    end

    test "entering visual select mode when scroll is at bottom keeps logs_scroll_y as integer, freezes logs, and does not auto-scroll on new logs tick" do
      u_id = System.unique_integer([:positive])
      profile_id = "test-server-#{u_id}"
      container_id = "container-1"
      source_id = "#{profile_id}/#{container_id}"
      Caudata.LogStore.clear_logs(source_id)

      initial_logs = Enum.map(1..10, &%{timestamp: nil, stream: :stdout, message: "log #{&1}"})
      Caudata.LogStore.append_logs(source_id, initial_logs)
      :sys.get_state(Caudata.LogStore)

      {:ok, state} = App.mount([])

      state = %{
        state
        | selected_profile_id: profile_id,
          selected_container_id: container_id,
          logs: initial_logs,
          logs_fetch_limit: 10,
          height: 10,
          logs_scroll_y: :bottom
      }

      event_v = %ExRatatui.Event.Key{code: "v", modifiers: []}
      assert {:noreply, visual_state} = App.handle_event(event_v, state)
      assert visual_state.mode == :selecting
      assert is_integer(visual_state.logs_scroll_y)
      assert visual_state.logs_scroll_y == 4
      assert visual_state.freeze == true

      # Now, new logs are appended to LogStore (total 12 logs, first 2 are dropped in 10-limit snapshot)
      new_store_logs = Enum.map(3..12, &%{timestamp: nil, stream: :stdout, message: "log #{&1}"})
      Caudata.LogStore.clear_logs(source_id)
      Caudata.LogStore.append_logs(source_id, new_store_logs)
      :sys.get_state(Caudata.LogStore)

      # Simulate receiving logs_updated PubSub event
      msg = {:logs_updated, source_id, %{size: 10, drop_count: 2}}
      assert {:noreply, updated_state} = App.handle_info(msg, visual_state)

      # Tick
      assert {:noreply, ticked_state} = App.handle_info(:tick, updated_state)
      assert ticked_state.logs_scroll_y == 4
      assert ticked_state.logs == initial_logs
      assert ticked_state.freeze == true
      assert ticked_state.mode == :selecting
    end

    test "pressing 'y' in normal mode copies all logs and sets notification" do
      {:ok, state} = App.mount([])

      state = %{
        state
        | selected_profile_id: "test-server",
          selected_container_id: "container-1",
          logs: ["line 1", "line 2", "line 3"]
      }

      event_y = %ExRatatui.Event.Key{code: "y", modifiers: []}
      assert {:noreply, copy_state} = App.handle_event(event_y, state)

      {msg, ticks} = copy_state.notification
      assert msg =~ "Copied 3 log lines"
      assert ticks == 25
    end

    test "pressing 'y' with no logs shows 'no logs' notification" do
      {:ok, state} = App.mount([])

      state = %{state | selected_profile_id: "test-server", selected_container_id: nil}

      event_y = %ExRatatui.Event.Key{code: "y", modifiers: []}
      assert {:noreply, copy_state} = App.handle_event(event_y, state)

      {msg, _ticks} = copy_state.notification
      assert msg =~ "No logs to copy"
    end

    test "escape exits visual select mode" do
      {:ok, state} = App.mount([])

      state = %{
        state
        | selected_profile_id: "test-server",
          selected_container_id: "container-1",
          logs: ["line 1", "line 2"],
          mode: :selecting,
          visual_anchor: 1,
          visual_cursor: 0
      }

      event_esc = %ExRatatui.Event.Key{code: "escape", modifiers: []}
      assert {:noreply, escaped_state} = App.handle_event(event_esc, state)
      assert escaped_state.mode == :browsing
      assert escaped_state.visual_anchor == nil
      assert escaped_state.visual_cursor == nil
    end

    test "pressing 'v' with no logs shows 'no logs to select' notification" do
      {:ok, state} = App.mount([])

      state = %{state | selected_profile_id: "test-server", selected_container_id: nil}

      event_v = %ExRatatui.Event.Key{code: "v", modifiers: []}
      assert {:noreply, nope_state} = App.handle_event(event_v, state)

      {msg, _ticks} = nope_state.notification
      assert msg =~ "No logs to select"
      assert nope_state.mode == :browsing
    end

    test "notification decrements on tick" do
      {:ok, state} = App.mount([])

      state = %{state | notification: {"Test message", 3}}
      assert {:noreply, tick1} = App.handle_info(:tick, state)
      assert tick1.notification == {"Test message", 2}

      assert {:noreply, tick2} = App.handle_info(:tick, tick1)
      assert tick2.notification == {"Test message", 1}

      assert {:noreply, tick3} = App.handle_info(:tick, tick2)
      assert tick3.notification == nil
    end
  end

  test "handle_info/2 containers_updated auto-selects the first container if none is selected" do
    server_id = "test-server-auto-select"
    {:ok, state} = App.mount([])

    profile =
      Caudata.Profile.new(%{
        id: server_id,
        host_pattern: "local-server",
        host_name: "local",
        user: "",
        port: 0,
        is_local: true
      })

    containers = [
      %{
        id: "container1",
        name: "test-container1",
        image: "nginx",
        status: "Up",
        state: "running"
      },
      %{
        id: "container2",
        name: "test-container2",
        image: "alpine",
        status: "Up",
        state: "running"
      }
    ]

    state = %{
      state
      | profiles: [profile],
        selected_profile_id: server_id,
        selected_container_id: nil
    }

    msg = {:containers_updated, server_id, containers}
    assert {:noreply, updated_state} = App.handle_info(msg, state)

    assert updated_state.selected_container_id == "container1"
    assert updated_state.logs_dirty == true
  end

  test "handle_event/2 handles Ctrl+V, 'P' key, and ExRatatui.Event.Paste in various input modes" do
    {:ok, state} = App.mount([])

    # 1. AddServerModal (Manual input) - Test paste with Ctrl+V
    manual_state = %{
      state
      | modal_visible: true,
        modal_type: :manual_input,
        # "host_name"
        modal_focus_index: 1,
        modal_fields: %{"host_name" => "myhost-"}
    }

    event_paste_ctrl = %ExRatatui.Event.Key{code: "v", modifiers: ["ctrl"]}
    assert {:noreply, pasted_manual_ctrl} = App.handle_event(event_paste_ctrl, manual_state)
    assert pasted_manual_ctrl.modal_fields["host_name"] == "myhost-mocked_paste_data"

    # Test paste with 'P' key
    event_paste_p = %ExRatatui.Event.Key{code: "P", modifiers: []}
    assert {:noreply, pasted_manual_p} = App.handle_event(event_paste_p, manual_state)
    assert pasted_manual_p.modal_fields["host_name"] == "myhost-mocked_paste_data"

    # Test paste with ExRatatui.Event.Paste
    event_paste_struct = %ExRatatui.Event.Paste{content: "bracketed_data"}
    assert {:noreply, pasted_manual_struct} = App.handle_event(event_paste_struct, manual_state)
    assert pasted_manual_struct.modal_fields["host_name"] == "myhost-bracketed_data"

    # 2. SettingsModal (Connection fields)
    profile1 = %Caudata.Profile{id: "server1", host_name: "1.1.1.1", host_pattern: "server1"}

    settings_state = %{
      state
      | profiles: [profile1],
        modal_visible: true,
        modal_type: :settings,
        settings_focus: :connection,
        # "host_name"
        settings_connection_focus_idx: 0,
        settings_connection_fields: %{"host_name" => "host-"}
    }

    assert {:noreply, pasted_settings} = App.handle_event(event_paste_p, settings_state)
    assert pasted_settings.settings_connection_fields["host_name"] == "host-mocked_paste_data"

    # 3. Search log regex input
    searching_state = %{
      state
      | mode: :searching,
        active_field: :filter_regex,
        filter_regex: "pattern_"
    }

    assert {:noreply, pasted_search} = App.handle_event(event_paste_p, searching_state)
    assert pasted_search.filter_regex == "pattern_mocked_paste_data"
  end

  test "ViewHelper.get_displayed_logs filters logs positively and negatively with !" do
    logs = [
      %{timestamp: "12:00:01", stream: "stdout", message: "GET /healthz 200 OK"},
      %{timestamp: "12:00:02", stream: "stderr", message: "ERROR Database connection failed"},
      %{timestamp: "12:00:03", stream: "stdout", message: "GET /ping 200 OK"}
    ]

    base_model = %{
      filter_regex: "",
      filter_error: false,
      selected_container_id: "c1",
      logs: logs,
      mode: :browsing
    }

    # No filter returns all
    assert length(Caudata.UI.ViewHelper.get_displayed_logs(base_model)) == 3

    # Positive filter "ERROR"
    pos_model = %{base_model | filter_regex: "ERROR"}
    pos_logs = Caudata.UI.ViewHelper.get_displayed_logs(pos_model)
    assert length(pos_logs) == 1
    assert hd(pos_logs).message =~ "ERROR"

    # Negative filter "!healthz"
    neg_model = %{base_model | filter_regex: "!healthz"}
    neg_logs = Caudata.UI.ViewHelper.get_displayed_logs(neg_model)
    assert length(neg_logs) == 2
    refute Enum.any?(neg_logs, &(&1.message =~ "healthz"))

    # Negative regex filter "!(healthz|ping)"
    neg_re_model = %{base_model | filter_regex: "!(healthz|ping)"}
    neg_re_logs = Caudata.UI.ViewHelper.get_displayed_logs(neg_re_model)
    assert length(neg_re_logs) == 1
    assert hd(neg_re_logs).message =~ "ERROR"
  end
end
