defmodule Caudata.UI.LevelFilterTest do
  use ExUnit.Case, async: true

  alias Caudata.UI.Components.LevelFilterModal
  alias Caudata.UI.KeyRegistry
  alias Caudata.UI.ViewHelper

  test "LevelFilterModal renders all 4 severity options" do
    state = %{
      modal_visible: true,
      modal_type: :level_filter,
      level_filter_modal_selected_index: 2,
      log_level_filter: :warn,
      width: 100,
      height: 30
    }

    [popup] = LevelFilterModal.render(state)
    assert popup.block.title =~ "Filter by Log Level"

    lines = popup.content.text
    text_contents = Enum.map(lines, fn line -> Enum.map_join(line.spans, "", & &1.content) end)

    assert Enum.any?(text_contents, &String.contains?(&1, "[0] All Logs"))
    assert Enum.any?(text_contents, &String.contains?(&1, "[1] Info and above"))
    assert Enum.any?(text_contents, &String.contains?(&1, "[2] Warnings and above"))
    assert Enum.any?(text_contents, &String.contains?(&1, "[3] Errors only"))
    assert Enum.any?(text_contents, &String.contains?(&1, "[ACTIVE] ✓"))
  end

  test "KeyRegistry opens level filter modal and applies selection" do
    state = %{
      active_panel: :logs,
      modal_visible: false,
      modal_type: nil,
      log_level_filter: :all,
      mode: :browsing
    }

    # Pressing 'l' in logs panel opens modal
    {new_state, _cmds} = KeyRegistry.dispatch_key(%{key: :char, char: "l"}, state)
    assert new_state.modal_visible == true
    assert new_state.modal_type == :level_filter

    # Pressing '2' applies WARN+ filter
    {filtered_state, _cmds} = KeyRegistry.dispatch_key(%{key: :char, char: "2"}, new_state)
    assert filtered_state.modal_visible == false
    assert filtered_state.log_level_filter == :warn

    # Pressing '0' clears filter
    {cleared_state, _cmds} = KeyRegistry.dispatch_key(%{key: :char, char: "0"}, %{filtered_state | modal_visible: true, modal_type: :level_filter})
    assert cleared_state.log_level_filter == :all
  end

  test "ViewHelper filters logs by severity level according to hl standard" do
    logs = [
      %{timestamp: "2026-08-21T06:00:00Z", stream: :stdout, message: ~s({"level":"debug","msg":"connecting"})},
      %{timestamp: "2026-08-21T06:00:01Z", stream: :stdout, message: ~s({"level":"info","msg":"connected"})},
      %{timestamp: "2026-08-21T06:00:02Z", stream: :stdout, message: ~s({"level":"warn","msg":"high latency"})},
      %{timestamp: "2026-08-21T06:00:03Z", stream: :stderr, message: ~s({"level":"error","msg":"database timeout"})},
      %{timestamp: "2026-08-21T06:00:04Z", stream: :stderr, message: ~s({"level":"fatal","msg":"kernel panic"})}
    ]

    base_model = %{
      logs: logs,
      filter_regex: "",
      filter_error: false,
      selected_container_id: "test",
      log_level_filter: :all
    }

    # All logs (5)
    assert length(ViewHelper.get_displayed_logs(base_model)) == 5

    # INFO+ (4 logs: info, warn, error, fatal)
    assert length(ViewHelper.get_displayed_logs(%{base_model | log_level_filter: :info})) == 4

    # WARN+ (3 logs: warn, error, fatal)
    assert length(ViewHelper.get_displayed_logs(%{base_model | log_level_filter: :warn})) == 3

    # ERROR+ (2 logs: error, fatal)
    assert length(ViewHelper.get_displayed_logs(%{base_model | log_level_filter: :error})) == 2

    # FATAL (1 log: fatal)
    assert length(ViewHelper.get_displayed_logs(%{base_model | log_level_filter: :fatal})) == 1
  end
end
