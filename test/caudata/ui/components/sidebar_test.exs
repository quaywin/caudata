defmodule Caudata.UI.Components.SidebarTest do
  use ExUnit.Case, async: true

  alias Caudata.UI.Components.Sidebar
  alias ExRatatui.Layout.Rect

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
      sidebar_focus: :servers,
      containers: %{},
      statuses: %{},
      metrics: %{}
    }

    {:ok, state: state}
  end

  test "renders all 4 components when height is large (>= 18)", %{state: state} do
    sidebar_area = %Rect{x: 0, y: 0, width: 38, height: 20}
    widgets = Sidebar.render(state, sidebar_area)

    assert length(widgets) == 4
    # Check that widgets have correct area layouts
    assert Enum.all?(widgets, fn {_, area} -> area.width == 38 end)
  end

  test "renders only 2 components (ServerList & ContainerList) when height is small (< 18)", %{
    state: state
  } do
    sidebar_area = %Rect{x: 0, y: 0, width: 38, height: 14}
    widgets = Sidebar.render(state, sidebar_area)

    assert length(widgets) == 2
    # Verify that the two returned widgets are for ServerList and ContainerList
    # which is indicated by their respective box areas totaling the overall height.
    [{_, area1}, {_, area2}] = widgets
    assert area1.width == 38
    assert area2.width == 38
    assert area1.height + area2.height == 14
  end

  test "server list scrolls when active server index exceeds inner height", %{state: state} do
    # Create 10 profiles
    profiles =
      Enum.map(1..10, fn i ->
        %Caudata.Profile{
          id: "server-#{i}",
          host_pattern: "server-#{i}",
          disabled_containers: []
        }
      end)

    # Select the 6th profile (index 5)
    state = %{state | profiles: profiles, selected_profile_id: "server-6"}

    # Box area height is 5, inner height is 5 - 2 = 3.
    # Selected index is 5.
    # div(3, 2) = 1.
    # Expected scroll = max(0, min(5 - 1, 10 - 3)) = 4.
    sidebar_area = %Rect{x: 0, y: 0, width: 38, height: 10}

    widgets = Sidebar.render(state, sidebar_area)
    assert [{server_widget, _}, _] = widgets
    assert server_widget.scroll == {4, 0}
  end

  test "container list scrolls when active container index exceeds inner height", %{state: state} do
    # Setup profiles
    profile = %Caudata.Profile{
      id: "test-server",
      host_pattern: "test-server",
      disabled_containers: []
    }

    # Create 10 containers
    containers =
      Enum.map(1..10, fn i ->
        %{id: "container-#{i}", name: "container-#{i}", image: "ubuntu"}
      end)

    # Select the 6th container (index 5)
    state = %{
      state
      | profiles: [profile],
        selected_profile_id: "test-server",
        selected_container_id: "container-6",
        containers: %{"test-server" => containers}
    }

    # Box area height for containers:
    # sidebar_area height = 10, h < 18.
    # servers_h = 5. box2_area height = 10 - 5 = 5.
    # inner height = 5 - 2 = 3.
    # Selected index is 5.
    # Expected scroll = max(0, min(5 - 1, 10 - 3)) = 4.
    sidebar_area = %Rect{x: 0, y: 0, width: 38, height: 10}

    widgets = Sidebar.render(state, sidebar_area)
    assert [_, {container_widget, _}] = widgets
    assert container_widget.scroll == {4, 0}
  end
end
