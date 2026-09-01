defmodule Caudata.UI.Components.ContainerInspectModalTest do
  use ExUnit.Case, async: true

  alias Caudata.UI.Components.ContainerInspectModal
  alias ExRatatui.Widgets.Popup

  test "ContainerInspectModal renders popup with standardized width" do
    state = %{
      modal_visible: true,
      modal_type: :container_inspect,
      container_inspect_scroll_y: 0,
      container_inspect_mode: :summary,
      container_inspect_data: ~s([{"Id":"1234567890123456","Name":"/my-container","State":{"Running":true,"Status":"running"}}]),
      selected_container_name: "my-container",
      width: 100,
      height: 30
    }

    [popup] = ContainerInspectModal.render(state)
    assert %Popup{} = popup
    assert popup.block.title =~ "Docker Inspect"
  end

  test "ContainerInspectModal bounded scrolling and fast navigation" do
    state = %{
      modal_visible: true,
      modal_type: :container_inspect,
      container_inspect_scroll_y: 0,
      container_inspect_mode: :summary,
      container_inspect_data: ~s([{"Id":"1234567890123456","Name":"/my-container","Config":{"Env":["A=1","B=2","C=3","D=4","E=5","F=6","G=7","H=8","I=9","J=10","K=11","L=12","M=13","N=14","O=15"]}}]),
      selected_container_name: "my-container",
      height: 20
    }

    # Up at 0 stays at 0
    {s_up, []} = ContainerInspectModal.handle_key(:up, %{}, state)
    assert s_up.container_inspect_scroll_y == 0

    # Down moves to 1
    {s1, []} = ContainerInspectModal.handle_key(:down, %{}, state)
    assert s1.container_inspect_scroll_y == 1

    # End / G moves to max_scroll
    {s_end, []} = ContainerInspectModal.handle_key(:char, %{char: "G"}, s1)
    assert s_end.container_inspect_scroll_y > 1

    # Down at max_scroll stays at max_scroll
    {s_down_stop, []} = ContainerInspectModal.handle_key(:down, %{}, s_end)
    assert s_down_stop.container_inspect_scroll_y == s_end.container_inspect_scroll_y

    # Home / g moves to 0
    {s_home, []} = ContainerInspectModal.handle_key(:char, %{char: "g"}, s_down_stop)
    assert s_home.container_inspect_scroll_y == 0
  end
end
