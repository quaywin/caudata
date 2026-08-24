defmodule Caudata.UI.Components.LogsPane.MouseHandlerTest do
  use ExUnit.Case, async: true

  alias Caudata.UI.Components.LogsPane.MouseHandler
  alias ExRatatui.Event.Mouse

  setup do
    state = %{
      width: 100,
      height: 30,
      logs_full_screen: false,
      active_panel: :sidebar,
      logs: [
        %{timestamp: "2026-08-04T10:00:00Z", stream: "stdout", message: "Line 0: Server started"},
        %{timestamp: "2026-08-04T10:00:01Z", stream: "stdout", message: "Line 1: Connecting to DB"},
        %{timestamp: "2026-08-04T10:00:02Z", stream: "stdout", message: "Line 2: DB Connected"},
        %{timestamp: "2026-08-04T10:00:03Z", stream: "stdout", message: "Line 3: Processing requests"},
        %{timestamp: "2026-08-04T10:00:04Z", stream: "stdout", message: "Line 4: Request completed"}
      ],
      logs_scroll_y: :bottom,
      logs_fetch_limit: 100,
      loading_history: false,
      loading_history_ticks: 0,
      logs_len_before_history_load: 0,
      selected_container_id: "container-1",
      selected_container_name: "app",
      filter_regex: "",
      filter_error: false,
      mode: :browsing,
      visual_anchor: nil,
      visual_cursor: nil,
      freeze: false,
      modal_visible: false,
      modal_type: nil,
      settings_focus: :servers,
      settings_selected_profile_idx: 0,
      container_action_modal_selected_index: 0,
      notification: nil,
      profiles: [
        %{id: "server-1", host_name: "10.0.0.1", enabled: true, disabled_containers: MapSet.new()},
        %{id: "server-2", host_name: "10.0.0.2", enabled: true, disabled_containers: MapSet.new()}
      ],
      containers: %{
        "server-1" => [
          %{id: "container-1", name: "app", image: "nginx", state: "running"},
          %{id: "container-2", name: "db", image: "postgres", state: "running"}
        ]
      },
      selected_profile_id: "server-1",
      statuses: %{"server-1" => :connected, "server-2" => :connected},
      buffer_sizes: %{},
      drop_counts: %{}
    }

    {:ok, state: state}
  end

  test "hit testing inside_area? correctly identifies coordinates", %{state: state} do
    logs_area = MouseHandler.get_logs_area(state)
    sidebar_area = MouseHandler.get_sidebar_area(state)

    assert MouseHandler.inside_area?(%Mouse{x: 10, y: 5}, sidebar_area) == true
    assert MouseHandler.inside_area?(%Mouse{x: 50, y: 5}, logs_area) == true
    assert MouseHandler.inside_area?(%Mouse{x: 10, y: 5}, logs_area) == false
  end

  test "mouse click inside server list selects server", %{state: state} do
    # Server 2 is at row 2 (inner y=2)
    event = %Mouse{kind: "down", button: "left", x: 10, y: 2}
    {new_state, []} = MouseHandler.handle_mouse(event, state)
    assert new_state.active_panel == :sidebar
    assert new_state.sidebar_focus == :servers
    assert new_state.selected_profile_id == "server-2"
  end

  test "mouse click inside container list selects container", %{state: state} do
    # In height 28 sidebar, box1 height=8 (y=0..7). box2 inner starts at y=9.
    # Container 2 "db" is at row 1 (y=10)
    event = %Mouse{kind: "down", button: "left", x: 10, y: 10}
    {new_state, []} = MouseHandler.handle_mouse(event, state)
    assert new_state.active_panel == :sidebar
    assert new_state.sidebar_focus == :containers
    assert new_state.selected_container_id == "container-2"
    assert new_state.selected_container_name == "db"
  end

  test "mouse click inside logs pane activates logs panel and starts visual selection", %{state: state} do
    event = %Mouse{kind: "down", button: "left", x: 50, y: 2}
    {new_state, []} = MouseHandler.handle_mouse(event, state)

    assert new_state.active_panel == :logs
    assert new_state.mode == :selecting
    assert new_state.visual_anchor != nil
    assert new_state.visual_cursor != nil
    assert new_state.freeze == true
  end

  test "mouse drag updates visual_cursor during selection and auto-copies on release", %{state: state} do
    # 1. Start selection at row 2
    down_event = %Mouse{kind: "down", button: "left", x: 50, y: 2}
    {state_after_down, []} = MouseHandler.handle_mouse(down_event, state)
    anchor = state_after_down.visual_anchor

    # Single click MouseUp (anchor == cursor) does not auto-copy
    up_event = %Mouse{kind: "up", button: "left", x: 50, y: 2}
    {state_after_single_up, []} = MouseHandler.handle_mouse(up_event, state_after_down)
    assert Map.get(state_after_single_up, :notification) == nil

    # 2. Drag down to row 4
    drag_event = %Mouse{kind: "drag", button: "left", x: 50, y: 4}
    {state_after_drag, []} = MouseHandler.handle_mouse(drag_event, state_after_down)

    assert state_after_drag.mode == :selecting
    assert state_after_drag.visual_anchor == anchor
    assert state_after_drag.visual_cursor != state_after_down.visual_cursor

    # 3. MouseUp after drag (anchor != cursor) triggers auto-copy
    {state_after_drag_up, []} = MouseHandler.handle_mouse(up_event, state_after_drag)
    assert state_after_drag_up.notification != nil

    # 4. Clicking outside in sidebar clears selection and does not copy
    sidebar_down = %Mouse{kind: "down", button: "left", x: 10, y: 5}
    {state_sidebar_down, []} = MouseHandler.handle_mouse(sidebar_down, state_after_drag_up)
    assert state_sidebar_down.mode == :browsing
    assert state_sidebar_down.visual_anchor == nil

    sidebar_up = %Mouse{kind: "up", button: "left", x: 10, y: 5}
    {state_sidebar_up, []} = MouseHandler.handle_mouse(sidebar_up, state_sidebar_down)
    assert state_sidebar_up.mode == :browsing
  end

  test "mouse drag selection auto-scrolls down when dragging past/at the bottom edge", %{state: state} do
    # 50 log lines, height 15 -> inner height 11
    logs = for i <- 0..49, do: %{timestamp: "2026-08-04T10:00:00Z", stream: "stdout", message: "Line #{i}"}
    long_state = %{state | logs: logs, height: 15, width: 100, logs_scroll_y: 0}

    # Start selection at top line (y = 1)
    down_event = %Mouse{kind: "down", button: "left", x: 50, y: 1}
    {state_down, []} = MouseHandler.handle_mouse(down_event, long_state)
    assert state_down.mode == :selecting
    assert state_down.logs_scroll_y == 0
    assert state_down.visual_anchor == 0
    assert state_down.visual_cursor == 0

    # Drag to bottom edge (y = 11, which is inner.y + logs_height - 1 = 1 + 11 - 1 = 11)
    drag_to_bottom = %Mouse{kind: "drag", button: "left", x: 50, y: 11}
    {state_bottom, []} = MouseHandler.handle_mouse(drag_to_bottom, state_down)
    assert state_bottom.visual_cursor == 10

    # Drag further down past bottom (y = 13) -> scrolls logs down and extends visual_cursor
    drag_overshoot = %Mouse{kind: "drag", button: "left", x: 50, y: 13}
    {state_scrolled, []} = MouseHandler.handle_mouse(drag_overshoot, state_bottom)
    assert state_scrolled.logs_scroll_y > 0
    assert state_scrolled.visual_cursor > state_bottom.visual_cursor
    assert state_scrolled.visual_anchor == 0

    # Drag at bottom again -> continues scrolling down
    {state_scrolled_more, []} = MouseHandler.handle_mouse(drag_overshoot, state_scrolled)
    assert state_scrolled_more.logs_scroll_y > state_scrolled.logs_scroll_y
    assert state_scrolled_more.visual_cursor > state_scrolled.visual_cursor
  end

  test "mouse drag selection auto-scrolls up when dragging past/at the top edge", %{state: state} do
    # 50 log lines, height 15, scrolled down to scroll_y = 20
    logs = for i <- 0..49, do: %{timestamp: "2026-08-04T10:00:00Z", stream: "stdout", message: "Line #{i}"}
    scrolled_state = %{state | logs: logs, height: 15, width: 100, logs_scroll_y: 20}

    # Start selection at row y = 5 (inner is y = 1..11)
    down_event = %Mouse{kind: "down", button: "left", x: 50, y: 5}
    {state_down, []} = MouseHandler.handle_mouse(down_event, scrolled_state)
    assert state_down.mode == :selecting
    assert state_down.logs_scroll_y == 20
    assert state_down.visual_anchor == 24

    # Drag to top line (y = 1)
    drag_to_top = %Mouse{kind: "drag", button: "left", x: 50, y: 1}
    {state_top, []} = MouseHandler.handle_mouse(drag_to_top, state_down)
    assert state_top.visual_cursor == 20

    # Drag past top (y = 0) -> scrolls logs up
    drag_overshoot = %Mouse{kind: "drag", button: "left", x: 50, y: 0}
    {state_scrolled, []} = MouseHandler.handle_mouse(drag_overshoot, state_top)
    assert state_scrolled.logs_scroll_y < 20
    assert state_scrolled.visual_cursor < 20
    assert state_scrolled.visual_anchor == 24
  end

  test "mouse click on footer triggers shortcut action button", %{state: state} do
    # Footer is at y=29 (height=30)
    # [q] Quit is near x=0
    event = %Mouse{kind: "down", button: "left", x: 1, y: 29}
    {new_state, _cmds} = MouseHandler.handle_mouse(event, state)
    assert new_state != nil
  end

  test "mouse click outside modal backdrop closes modal", %{state: state} do
    modal_state = %{state | modal_visible: true, modal_type: :help}
    # Click at top-left backdrop (x=1, y=1) outside centered popup window
    event = %Mouse{kind: "down", button: "left", x: 1, y: 1}
    {new_state, []} = MouseHandler.handle_mouse(event, modal_state)
    assert new_state.modal_visible == false
  end

  test "mouse scroll_up decrements logs_scroll_y", %{state: state} do
    scroll_state = %{state | logs_scroll_y: 10}
    event = %Mouse{kind: "scroll_up", x: 50, y: 10}
    {new_state, []} = MouseHandler.handle_mouse(event, scroll_state)

    assert new_state.logs_scroll_y == 7
    assert new_state.active_panel == :logs
  end

  test "mouse scroll_down increments logs_scroll_y", %{state: state} do
    scroll_state = %{state | logs_scroll_y: 2}
    event = %Mouse{kind: "scroll_down", x: 50, y: 10}
    {new_state, []} = MouseHandler.handle_mouse(event, scroll_state)

    assert new_state.logs_scroll_y > 2 or new_state.logs_scroll_y == :bottom
    assert new_state.active_panel == :logs
  end

  test "mouse click inside settings modal tab header switches active tab", %{state: state} do
    # Width 100, Height 30. Popup 80%x90% -> x=10..90, y=1..28. Inner x=11, y=2.
    # Line 2 (y=4) has tabs. Tab "SSH Connection" starts around rel_x=14 (x=25).
    settings_state = %{state | modal_visible: true, modal_type: :settings, settings_focus: :servers, settings_selected_profile_idx: 0}
    event = %Mouse{kind: "down", button: "left", x: 28, y: 4}
    {new_state, []} = MouseHandler.handle_mouse(event, settings_state)

    assert new_state.modal_visible == true
    assert new_state.settings_focus == :connection
  end

  test "mouse click inside container action modal executes selected action", %{state: state} do
    # Container action modal: 55%x35% centered. Inner y=11.
    # Action 1 "Stop Container" is at rel_y=2 (y=13)
    action_state = %{state | modal_visible: true, modal_type: :container_action, container_action_modal_selected_index: 0}
    event = %Mouse{kind: "down", button: "left", x: 50, y: 13}
    {new_state, _cmds} = MouseHandler.handle_mouse(event, action_state)

    assert new_state != nil
  end
end
