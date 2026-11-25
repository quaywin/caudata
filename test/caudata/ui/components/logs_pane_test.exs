defmodule Caudata.UI.Components.LogsPaneTest do
  use ExUnit.Case, async: true

  alias Caudata.UI.Components.LogsPane
  alias ExRatatui.Layout.Rect
  alias ExRatatui.Style

  setup do
    profile = %Caudata.Profile{
      id: "test-server",
      host_pattern: "test-server",
      disabled_containers: []
    }

    state = %{
      profiles: [profile],
      selected_profile_id: "test-server",
      selected_container_id: nil,
      active_panel: :sidebar,
      logs_full_screen: false,
      mode: :browsing,
      logs: [],
      logs_scroll_y: :bottom,
      logs_fetch_limit: 1000,
      loading_history: false,
      containers: %{},
      show_timestamps: false,
      filter_regex: "",
      filter_error: false,
      width: 80,
      height: 24
    }

    {:ok, state: state, profile: profile}
  end

  describe "render/2" do
    test "renders empty pane with dark_gray border when inactive", %{state: state} do
      empty_state = %{state | profiles: [], selected_profile_id: nil}
      area = %Rect{x: 0, y: 0, width: 80, height: 24}

      {outer_block, _content} = LogsPane.render(empty_state, area)

      assert outer_block.title == " Caudata Logs "
      assert outer_block.border_style == %Style{fg: :dark_gray}
    end

    test "renders empty pane with cyan border and [2] title when active", %{state: state} do
      empty_state = %{state | profiles: [], selected_profile_id: nil, active_panel: :logs}
      area = %Rect{x: 0, y: 0, width: 80, height: 24}

      {outer_block, _content} = LogsPane.render(empty_state, area)

      assert outer_block.title == " [3]Caudata Logs "
      assert outer_block.border_style == %Style{fg: :cyan}
    end

    test "renders disabled pane with dark_gray border when inactive", %{
      state: state,
      profile: profile
    } do
      disabled_profile = %{profile | enabled: false}
      disabled_state = %{state | profiles: [disabled_profile]}
      area = %Rect{x: 0, y: 0, width: 80, height: 24}

      {outer_block, _content} = LogsPane.render(disabled_state, area)

      assert outer_block.title == " Logs: test-server (disabled) "
      assert outer_block.border_style == %Style{fg: :dark_gray}
    end

    test "renders disabled pane with cyan border when logs_full_screen is true", %{
      state: state,
      profile: profile
    } do
      disabled_profile = %{profile | enabled: false}
      disabled_state = %{state | profiles: [disabled_profile], logs_full_screen: true}
      area = %Rect{x: 0, y: 0, width: 80, height: 24}

      {outer_block, _content} = LogsPane.render(disabled_state, area)

      assert outer_block.title == " [3]Logs: test-server (disabled) "
      assert outer_block.border_style == %Style{fg: :cyan}
    end

    test "renders active pane with title and border reflecting active_panel", %{state: state} do
      area = %Rect{x: 0, y: 0, width: 80, height: 24}

      {inactive_block, _} = LogsPane.render(state, area)
      assert inactive_block.title == " Logs: test-server "
      assert inactive_block.border_style == %Style{fg: :dark_gray}

      active_state = %{state | active_panel: :logs}
      {active_block, _} = LogsPane.render(active_state, area)
      assert active_block.title == " [3]Logs: test-server "
      assert active_block.border_style == %Style{fg: :cyan}
    end

    test "clamps scroll_y to max_scroll when scrolling up so frame does not jump up leaving blank lines",
         %{state: state} do
      area = %Rect{x: 0, y: 0, width: 80, height: 24}

      logs =
        Enum.map(1..50, fn i -> %{timestamp: nil, stream: :stdout, message: "Log line #{i}"} end)

      # 1. State at :bottom
      bottom_state = %{
        state
        | width: 80,
          height: 24,
          active_panel: :logs,
          logs: logs,
          logs_scroll_y: :bottom,
          selected_container_id: "c1"
      }

      {_, [{logs_widget, _} | _]} = LogsPane.render(bottom_state, area)
      assert logs_widget.scroll == {10, 0}

      # 2. State when scrolling up with an integer scroll_y value
      # Press 'k' from :bottom
      {scrolled_state, _} = LogsPane.handle_key(:char, %{key: :char, char: "k"}, bottom_state)
      assert is_integer(scrolled_state.logs_scroll_y)

      {_, [{scrolled_widget, _} | _]} = LogsPane.render(scrolled_state, area)
      # Should render smoothly with paragraph scroll matching valid index
      assert scrolled_widget.scroll == {0, 0}

      # 3. State with an out-of-bounds large scroll_y integer
      oob_state = %{
        state
        | width: 80,
          height: 24,
          active_panel: :logs,
          logs: logs,
          logs_scroll_y: 999,
          selected_container_id: "c1"
      }

      {_, [{oob_widget, _} | _]} = LogsPane.render(oob_state, area)
      # Target line gets clamped so it doesn't overshoot
      assert oob_widget.scroll == {0, 0}
    end

    test "handles scaling / resizing of log pane area without empty space or error", %{
      state: state
    } do
      logs =
        Enum.map(1..50, fn i -> %{timestamp: nil, stream: :stdout, message: "Log line #{i}"} end)

      initial_state = %{
        state
        | width: 80,
          height: 24,
          active_panel: :logs,
          logs: logs,
          logs_scroll_y: 28,
          selected_container_id: "c1"
      }

      # Small window (height: 15)
      small_area = %Rect{x: 0, y: 0, width: 80, height: 15}
      {_, [{small_widget, _} | _]} = LogsPane.render(initial_state, small_area)

      # Large window (height: 50) - max_scroll is now 50 - 46 = 4
      large_area = %Rect{x: 0, y: 0, width: 80, height: 50}
      {_, [{large_widget, _} | _]} = LogsPane.render(initial_state, large_area)

      # Fullscreen mode
      fullscreen_state = %{initial_state | logs_full_screen: true}
      fs_area = %Rect{x: 0, y: 0, width: 120, height: 40}
      {_, [{fs_widget, _} | _]} = LogsPane.render(fullscreen_state, fs_area)

      assert is_tuple(small_widget.scroll)
      assert is_tuple(large_widget.scroll)
      assert is_tuple(fs_widget.scroll)
    end
  end

  describe "handle_key navigation with history backfill" do
    test "pressing 'g' dispatches load_history 10000 and scrolls to top", %{state: state} do
      logs = Enum.map(1..50, fn i -> %{timestamp: nil, stream: :stdout, message: "Log #{i}"} end)

      initial_state = %{
        state
        | active_panel: :logs,
          logs: logs,
          logs_scroll_y: :bottom,
          logs_fetch_limit: 1000,
          loading_history: false,
          selected_profile_id: "test-server",
          selected_container_id: "c1"
      }

      {new_model, commands} =
        LogsPane.handle_key(:char, %{key: :char, char: "g"}, initial_state)

      assert new_model.logs_scroll_y == 0
      assert new_model.logs_fetch_limit == 10000
      assert new_model.loading_history == true
      assert commands == [{:command, {:load_history, 10000, 0}}]
    end

    test "pressing page_up at top triggers history fetch when logs_fetch_limit < 10000", %{
      state: state
    } do
      logs =
        Enum.map(1..100, fn i -> %{timestamp: nil, stream: :stdout, message: "Log line #{i}"} end)

      initial_state = %{
        state
        | active_panel: :logs,
          logs: logs,
          logs_scroll_y: 0,
          logs_fetch_limit: 1000,
          loading_history: false,
          selected_profile_id: "test-server",
          selected_container_id: "c1",
          width: 80,
          height: 24
      }

      {new_model, commands} =
        LogsPane.handle_key(:page_up, %{key: :page_up}, initial_state)

      assert new_model.logs_fetch_limit == 2000
      assert new_model.loading_history == true
      assert commands == [{:command, {:load_history, 2000}}]
    end
  end

  describe "visual mode, copy, and freeze edge cases" do
    test "does not select or copy placeholder text when filter reduces logs to empty", %{
      state: state
    } do
      logs = [%{timestamp: nil, stream: :stdout, message: "hello world"}]

      filtered_state = %{
        state
        | active_panel: :logs,
          selected_container_id: "c1",
          logs: logs,
          filter_regex: "nonexistent_match"
      }

      {v_model, []} = LogsPane.handle_key(:char, %{key: :char, char: "v"}, filtered_state)
      assert v_model.mode == :browsing
      assert v_model.notification == {"No logs to select", 25}

      {y_model, []} = LogsPane.handle_key(:char, %{key: :char, char: "y"}, filtered_state)
      assert y_model.notification == {"No logs to copy", 25}
    end

    test "Space toggles freeze in normal mode when logs pane is active", %{state: state} do
      logs_active_state = state |> Map.put(:active_panel, :logs) |> Map.put(:freeze, false)

      {frozen_model, []} =
        Caudata.UI.KeyRegistry.dispatch_key(
          %{key: :char, char: " ", modifiers: []},
          logs_active_state
        )

      assert frozen_model.freeze == true

      {unfrozen_model, []} =
        Caudata.UI.KeyRegistry.dispatch_key(%{key: :char, char: " ", modifiers: []}, frozen_model)

      assert unfrozen_model.freeze == false
    end

    test "search mode regex updates displayed logs accurately after :update_filter", %{
      state: state
    } do
      logs = [
        %{timestamp: nil, stream: :stdout, message: "error one"},
        %{timestamp: nil, stream: :stdout, message: "warn two"}
      ]

      base_state = %{state | selected_container_id: "c1", logs: logs, active_panel: :logs}
      {:noreply, via_info} = Caudata.UI.App.handle_info({:update_filter, "err.*"}, base_state)

      assert Enum.map(Caudata.UI.ViewHelper.get_displayed_logs(via_info), & &1.message) == [
               "error one"
             ]

      {search_state, []} =
        LogsPane.handle_key(:char, %{key: :char, char: "/"}, %{via_info | filter_regex: ""})

      {typed_state, []} =
        Enum.reduce(["w", "a", "r", "n", ".", "*"], {search_state, []}, fn ch, {acc, _} ->
          LogsPane.handle_key(:char, %{key: :char, char: ch}, acc)
        end)

      assert typed_state.filter_regex == "warn.*"
      assert typed_state.filter_error == false

      assert Enum.map(Caudata.UI.ViewHelper.get_displayed_logs(typed_state), & &1.message) == [
               "warn two"
             ]
    end
  end
end
