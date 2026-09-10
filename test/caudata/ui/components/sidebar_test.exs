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

    # Verify fixed height 6 for ContainerInfo (box 3) and ServerMetrics (box 4)
    [{_, _area1}, {_, _area2}, {_, area3}, {_, area4}] = widgets
    assert area3.height == 6
    assert area4.height == 6
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

    # Box area height is 6, inner height is 6 - 2 = 4.
    # Selected index is 5.
    # div(4, 2) = 2.
    # Expected scroll = max(0, min(5 - 2, 10 - 4)) = 3.
    sidebar_area = %Rect{x: 0, y: 0, width: 38, height: 10}

    widgets = Sidebar.render(state, sidebar_area)
    assert [{server_widget, _} | _] = widgets
    assert server_widget.scroll == {3, 0}
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
    {container_widget, _} = Enum.find(widgets, fn {%ExRatatui.Widgets.Paragraph{block: block}, _} -> String.contains?(to_string(block.title), "Containers") end)
    assert container_widget.scroll == {4, 0}
  end

  test "ServerList border color and title update based on active_panel and focus", %{state: state} do
    box_area = %Rect{x: 0, y: 0, width: 38, height: 10}

    # active_panel: :sidebar, focus: :servers -> cyan border, [ACTIVE] title
    state1 = Map.merge(state, %{active_panel: :sidebar, sidebar_focus: :servers})
    {widget1, _} = Caudata.UI.Components.Sidebar.ServerList.render(state1, box_area)
    assert widget1.block.border_style.fg == :cyan
    assert widget1.block.title == " [1] Servers [ACTIVE] "

    # active_panel: :sidebar, focus: :containers -> dark_gray border, non-[ACTIVE] title
    state2 = Map.merge(state, %{active_panel: :sidebar, sidebar_focus: :containers})
    {widget2, _} = Caudata.UI.Components.Sidebar.ServerList.render(state2, box_area)
    assert widget2.block.border_style.fg == :dark_gray
    assert widget2.block.title == " [1] Servers "

    # active_panel: :main -> dark_gray border, non-[ACTIVE] title
    state3 = Map.merge(state, %{active_panel: :main, sidebar_focus: :servers})
    {widget3, _} = Caudata.UI.Components.Sidebar.ServerList.render(state3, box_area)
    assert widget3.block.border_style.fg == :dark_gray
    assert widget3.block.title == " [1] Servers "
  end

  test "ContainerInfo renders Status, CPU, RAM, Net without Name and Image", %{state: state} do
    box_area = %Rect{x: 0, y: 0, width: 38, height: 6}

    container = %{
      id: "container-1",
      name: "app",
      image: "nginx:latest",
      state: "running",
      status: "Up 2 hours",
      cpu_text: "12.5%",
      ram_text: "256MiB / 2GiB"
    }

    state = %{
      state
      | selected_container_id: "container-1",
        containers: %{"test-server" => [container]}
    }

    {widget, _} = Caudata.UI.Components.Sidebar.ContainerInfo.render(state, box_area)
    rendered_text = Enum.map_join(widget.text, "\n", fn line ->
      Enum.map_join(line.spans, "", & &1.content)
    end)

    # Status, CPU, RAM, Net must be present
    assert String.contains?(rendered_text, "Status:")
    assert String.contains?(rendered_text, "Up 2 hours")
    assert String.contains?(rendered_text, "CPU:")
    assert String.contains?(rendered_text, "12.5%")
    assert String.contains?(rendered_text, "RAM:")
    assert String.contains?(rendered_text, "256MiB / 2GiB")
    assert String.contains?(rendered_text, "Net:")
    assert String.contains?(rendered_text, "--")

    # Name and Image must NOT be present
    refute String.contains?(rendered_text, "Name:")
    refute String.contains?(rendered_text, "Image:")
  end

  test "ContainerInfo renders real-time network speed with arrows when available", %{state: state} do
    box_area = %Rect{x: 0, y: 0, width: 38, height: 6}

    container = %{
      id: "container-1",
      name: "app",
      image: "nginx:latest",
      state: "running",
      status: "Up 2 hours",
      cpu_text: "12.5%",
      ram_text: "256MiB / 2GiB",
      net_rx_speed: 15 * 1024,
      net_tx_speed: 3 * 1024
    }

    state = %{
      state
      | selected_container_id: "container-1",
        containers: %{"test-server" => [container]}
    }

    {widget, _} = Caudata.UI.Components.Sidebar.ContainerInfo.render(state, box_area)
    rendered_text = Enum.map_join(widget.text, "\n", fn line ->
      Enum.map_join(line.spans, "", & &1.content)
    end)

    assert String.contains?(rendered_text, "Net:")
    assert String.contains?(rendered_text, "▼")
    assert String.contains?(rendered_text, "15.0 KB/s")
    assert String.contains?(rendered_text, "▲")
    assert String.contains?(rendered_text, "3.0 KB/s")
  end

  test "ServerMetrics renders CPU, RAM, Disk, and Net rows", %{state: state} do
    box_area = %Rect{x: 0, y: 0, width: 38, height: 6}

    metrics = {25, 40, 6.4, 16.0, 50, 50.0, 100, 120 * 1024, 45 * 1024}
    state = %{
      state
      | statuses: %{"test-server" => :connected},
        metrics: %{"test-server" => metrics}
    }

    {widget, _} = Caudata.UI.Components.Sidebar.ServerMetrics.render(state, box_area)
    rendered_text = Enum.map_join(widget.text, "\n", fn line ->
      Enum.map_join(line.spans, "", & &1.content)
    end)

    assert String.contains?(rendered_text, "CPU:")
    assert String.contains?(rendered_text, "25%")
    assert String.contains?(rendered_text, "RAM:")
    assert String.contains?(rendered_text, "6.4G / 16.0G")
    assert String.contains?(rendered_text, "Disk:")
    assert String.contains?(rendered_text, "50.0G / 100G")
    assert String.contains?(rendered_text, "Net:")
    assert String.contains?(rendered_text, "120.0 KB/s")
    assert String.contains?(rendered_text, "45.0 KB/s")
  end
end
