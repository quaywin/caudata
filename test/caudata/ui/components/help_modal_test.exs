defmodule Caudata.UI.Components.HelpModalTest do
  use ExUnit.Case, async: true

  alias Caudata.UI.Components.HelpModal
  alias ExRatatui.Widgets.Popup

  test "HelpModal renders popup with standardized width" do
    state = %{
      modal_visible: true,
      modal_type: :help,
      help_modal_scroll_y: 0,
      width: 100,
      height: 30
    }

    [popup] = HelpModal.render(state)
    assert %Popup{} = popup
    assert popup.block.title =~ "Keybinding Help Reference"
  end

  test "HelpModal bounded scrolling and fast navigation" do
    state = %{
      modal_visible: true,
      modal_type: :help,
      help_modal_scroll_y: 0,
      height: 24
    }

    # Up at 0 stays at 0
    {s_up, []} = HelpModal.handle_key(:up, %{}, state)
    assert s_up.help_modal_scroll_y == 0

    # Down moves to 1
    {s1, []} = HelpModal.handle_key(:down, %{}, state)
    assert s1.help_modal_scroll_y == 1

    # End / G moves to max_scroll
    {s_end, []} = HelpModal.handle_key(:char, %{char: "G"}, s1)
    assert s_end.help_modal_scroll_y > 10

    # Down at max_scroll stays at max_scroll
    {s_down_stop, []} = HelpModal.handle_key(:down, %{}, s_end)
    assert s_down_stop.help_modal_scroll_y == s_end.help_modal_scroll_y

    # Home / g moves to 0
    {s_home, []} = HelpModal.handle_key(:char, %{char: "g"}, s_down_stop)
    assert s_home.help_modal_scroll_y == 0
  end
end
