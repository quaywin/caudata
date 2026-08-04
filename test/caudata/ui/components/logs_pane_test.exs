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
      containers: %{},
      show_timestamps: false,
      filter_regex: "",
      filter_error: false
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

      assert outer_block.title == " [2]Caudata Logs "
      assert outer_block.border_style == %Style{fg: :cyan}
    end

    test "renders disabled pane with dark_gray border when inactive", %{state: state, profile: profile} do
      disabled_profile = %{profile | enabled: false}
      disabled_state = %{state | profiles: [disabled_profile]}
      area = %Rect{x: 0, y: 0, width: 80, height: 24}

      {outer_block, _content} = LogsPane.render(disabled_state, area)

      assert outer_block.title == " Logs: test-server (disabled) "
      assert outer_block.border_style == %Style{fg: :dark_gray}
    end

    test "renders disabled pane with cyan border when logs_full_screen is true", %{state: state, profile: profile} do
      disabled_profile = %{profile | enabled: false}
      disabled_state = %{state | profiles: [disabled_profile], logs_full_screen: true}
      area = %Rect{x: 0, y: 0, width: 80, height: 24}

      {outer_block, _content} = LogsPane.render(disabled_state, area)

      assert outer_block.title == " [2]Logs: test-server (disabled) "
      assert outer_block.border_style == %Style{fg: :cyan}
    end

    test "renders active pane with title and border reflecting active_panel", %{state: state} do
      area = %Rect{x: 0, y: 0, width: 80, height: 24}

      {inactive_block, _} = LogsPane.render(state, area)
      assert inactive_block.title == " Logs: test-server "
      assert inactive_block.border_style == %Style{fg: :dark_gray}

      active_state = %{state | active_panel: :logs}
      {active_block, _} = LogsPane.render(active_state, area)
      assert active_block.title == " [2]Logs: test-server "
      assert active_block.border_style == %Style{fg: :cyan}
    end
  end
end
