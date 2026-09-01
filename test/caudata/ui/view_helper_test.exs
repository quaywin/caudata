defmodule Caudata.UI.ViewHelperTest do
  use ExUnit.Case, async: true

  alias Caudata.UI.ViewHelper

  describe "container category helpers" do
    test "docker_container? correctly identifies docker containers" do
      assert ViewHelper.docker_container?(%{id: "abc", name: "nginx", image: "nginx:latest"})
      refute ViewHelper.docker_container?(%{id: "file:/var/log/app.log", name: "app.log", image: "file"})
      refute ViewHelper.docker_container?(%{id: "systemd:nginx", name: "nginx", image: "systemd"})
      refute ViewHelper.docker_container?(%{id: "launchd:brew.mysql", name: "mysql", image: "launchd"})
    end

    test "service_container? correctly identifies system services" do
      assert ViewHelper.service_container?(%{id: "systemd:nginx", name: "nginx", image: "systemd"})
      assert ViewHelper.service_container?(%{id: "launchd:brew.mysql", name: "mysql", image: "launchd"})
      refute ViewHelper.service_container?(%{id: "abc", name: "nginx", image: "nginx:latest"})
      refute ViewHelper.service_container?(%{id: "file:/var/log/app.log", name: "app.log", image: "file"})
    end

    test "filter_docker_containers and filter_system_services" do
      containers = [
        %{id: "c1", name: "c1", image: "img1"},
        %{id: "file:/log", name: "log", image: "file"},
        %{id: "systemd:sys", name: "sys", image: "systemd"}
      ]

      assert [%{id: "c1"}] = ViewHelper.filter_docker_containers(containers)
      assert [%{id: "systemd:sys"}] = ViewHelper.filter_system_services(containers)
    end
  end

  describe "windowed scroll and slicing helpers" do
    test "scroll_start_row calculates correct offset" do
      assert ViewHelper.scroll_start_row(0, 10) == 0
      assert ViewHelper.scroll_start_row(9, 10) == 0
      assert ViewHelper.scroll_start_row(10, 10) == 1
      assert ViewHelper.scroll_start_row(15, 10) == 6
    end

    test "window_slice extracts correct window" do
      items = Enum.to_list(1..20)
      assert ViewHelper.window_slice(items, 0, 5) == [1, 2, 3, 4, 5]
      assert ViewHelper.window_slice(items, 4, 5) == [1, 2, 3, 4, 5]
      assert ViewHelper.window_slice(items, 5, 5) == [2, 3, 4, 5, 6]
      assert ViewHelper.window_slice(items, 19, 5) == [16, 17, 18, 19, 20]
    end
  end

  describe "bounded index navigation" do
    test "navigate_bounded_index respects boundaries and fast navigation" do
      total = 10

      # Up at 0 stays at 0
      assert ViewHelper.navigate_bounded_index(0, :up, total) == 0
      assert ViewHelper.navigate_bounded_index(0, "k", total) == 0
      assert ViewHelper.navigate_bounded_index(0, "scroll_up", total) == 0

      # Down moves forward
      assert ViewHelper.navigate_bounded_index(0, :down, total) == 1
      assert ViewHelper.navigate_bounded_index(0, "j", total) == 1
      assert ViewHelper.navigate_bounded_index(0, "scroll_down", total) == 1

      # Down at max stays at max
      assert ViewHelper.navigate_bounded_index(9, :down, total) == 9

      # Home / g moves to 0
      assert ViewHelper.navigate_bounded_index(7, :home, total) == 0
      assert ViewHelper.navigate_bounded_index(7, "g", total) == 0

      # End / G moves to max
      assert ViewHelper.navigate_bounded_index(2, :end, total) == 9
      assert ViewHelper.navigate_bounded_index(2, "G", total) == 9

      # Page down / up
      assert ViewHelper.navigate_bounded_index(0, :page_down, total, 4) == 4
      assert ViewHelper.navigate_bounded_index(8, :page_down, total, 4) == 9
      assert ViewHelper.navigate_bounded_index(8, :page_up, total, 4) == 4
      assert ViewHelper.navigate_bounded_index(2, :page_up, total, 4) == 0
    end
  end

  describe "popup sizing" do
    test "popup_inner_width calculates safe inner width" do
      assert ViewHelper.popup_inner_width(100, 80) == 76
      assert ViewHelper.popup_inner_width(20, 50) == 10
    end
  end
end
