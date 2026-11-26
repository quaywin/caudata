defmodule Caudata.UI.ViewHelperTest do
  use ExUnit.Case, async: true

  alias Caudata.UI.ViewHelper

  describe "container category helpers" do
    test "docker_container? correctly identifies docker containers" do
      assert ViewHelper.docker_container?(%{id: "abc", name: "nginx", image: "nginx:latest"})

      refute ViewHelper.docker_container?(%{
               id: "file:/var/log/app.log",
               name: "app.log",
               image: "file"
             })

      refute ViewHelper.docker_container?(%{id: "systemd:nginx", name: "nginx", image: "systemd"})

      refute ViewHelper.docker_container?(%{
               id: "launchd:brew.mysql",
               name: "mysql",
               image: "launchd"
             })
    end

    test "service_container? correctly identifies system services" do
      assert ViewHelper.service_container?(%{
               id: "systemd:nginx",
               name: "nginx",
               image: "systemd"
             })

      assert ViewHelper.service_container?(%{
               id: "launchd:brew.mysql",
               name: "mysql",
               image: "launchd"
             })

      refute ViewHelper.service_container?(%{id: "abc", name: "nginx", image: "nginx:latest"})

      refute ViewHelper.service_container?(%{
               id: "file:/var/log/app.log",
               name: "app.log",
               image: "file"
             })
    end

    test "file_container? correctly identifies file logs" do
      assert ViewHelper.file_container?(%{
               id: "file:/var/log/app.log",
               name: "app.log",
               image: "file"
             })

      assert ViewHelper.file_container?(%{id: "file:/etc/hosts", name: "hosts", image: "custom"})
      refute ViewHelper.file_container?(%{id: "abc", name: "nginx", image: "nginx:latest"})
      refute ViewHelper.file_container?(%{id: "systemd:nginx", name: "nginx", image: "systemd"})
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

    test "centered_scroll_y centers the selected row" do
      # When total <= inner_height
      assert ViewHelper.centered_scroll_y(2, 5, 10) == 0
      # When selected_idx is nil
      assert ViewHelper.centered_scroll_y(nil, 20, 10) == 0
      # When selected is near top
      assert ViewHelper.centered_scroll_y(2, 20, 10) == 0
      # When selected is in middle
      assert ViewHelper.centered_scroll_y(10, 20, 10) == 5
      # When selected is near bottom
      assert ViewHelper.centered_scroll_y(19, 20, 10) == 10
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

  describe "form and input helpers" do
    test "render_form_fields and render_action_buttons" do
      fields_config = [{"name", "Name:"}, {"password", "Password:"}]
      fields_map = %{"name" => "alice", "password" => "secret"}

      lines = ViewHelper.render_form_fields(fields_config, fields_map, 0)
      assert length(lines) == 4

      btn_line = ViewHelper.render_action_buttons(true, false)
      assert %ExRatatui.Text.Line{} = btn_line
    end

    test "handle_text_input handles paste, backspace, and chars" do
      assert {:ok, "hello world"} =
               ViewHelper.handle_text_input(:paste, %{content: " world"}, "hello")

      assert {:ok, "hell"} = ViewHelper.handle_text_input(:backspace, %{}, "hello")
      assert {:ok, "hell"} = ViewHelper.handle_text_input(:delete, %{}, "hello")

      assert {:ok, ""} =
               ViewHelper.handle_text_input(:char, %{char: "u", modifiers: ["ctrl"]}, "hello")

      assert {:ok, "hello "} =
               ViewHelper.handle_text_input(
                 :char,
                 %{char: "w", modifiers: ["ctrl"]},
                 "hello world"
               )

      assert {:ok, "hello!"} = ViewHelper.handle_text_input(:char, %{char: "!"}, "hello")
      assert {:ok, "hello?"} = ViewHelper.handle_text_input("?", %{}, "hello")
      assert :ignore = ViewHelper.handle_text_input(:up, %{}, "hello")
    end

    test "cycle_focus_index wraps around bounds" do
      assert {:ok, 1} = ViewHelper.cycle_focus_index(0, :down, false, 3)
      assert {:ok, 2} = ViewHelper.cycle_focus_index(1, :tab, false, 3)
      assert {:ok, 0} = ViewHelper.cycle_focus_index(2, :down, false, 3)
      assert {:ok, 2} = ViewHelper.cycle_focus_index(0, :up, false, 3)
      assert {:ok, 0} = ViewHelper.cycle_focus_index(1, :tab, true, 3)
      assert :ignore = ViewHelper.cycle_focus_index(1, :enter, false, 3)
    end
  end

  describe "line wrapping helpers" do
    test "visual_line_count returns 1 for short lines and scales with width" do
      assert ViewHelper.visual_line_count("short", 10) == 1
      assert ViewHelper.visual_line_count("exactly10!", 10) == 1
      assert ViewHelper.visual_line_count("eleven chars", 10) == 2
      assert ViewHelper.visual_line_count("twenty-one characters!", 10) == 3
      assert ViewHelper.visual_line_count(%{message: "short"}, 10) == 1
      assert ViewHelper.visual_line_count(%{message: "eleven chars"}, 10) == 2
      assert ViewHelper.visual_line_count(nil, 10) == 1
    end

    test "count_wrapped_lines aggregates line counts correctly" do
      lines = [
        %{message: "first line"},
        %{message: "second line that is quite long"},
        %{message: "third"}
      ]

      assert ViewHelper.count_wrapped_lines(lines, 50) == 3
      assert ViewHelper.count_wrapped_lines(lines, 10) == 1 + 3 + 1
      assert ViewHelper.count_wrapped_lines([], 10) == 0
    end

    test "chunked count_wrapped_lines matches unchunked across sliding and negative seq ranges" do
      Process.delete(:cached_wrapped_lines_count)
      Process.delete(:wrap_chunk_cache)

      make_line = fn seq ->
        msg =
          if rem(abs(seq), 7) == 0,
            do: "wrap-line-#{seq} " <> String.duplicate("x", 25),
            else: "ok-#{seq}"

        %{timestamp: nil, stream: :stdout, message: msg}
      end

      scope = {"srv1", "c1", 1}
      width = 20

      # 1. Contiguous 0..600 slice (crosses 0, 256, 512 chunk boundaries)
      lines_a = Enum.map(0..600, make_line)
      expected_a = ViewHelper.count_wrapped_lines(lines_a, width)

      Process.delete(:cached_wrapped_lines_count)
      tag_a = {0, 600, "", :all, scope}
      assert ViewHelper.count_wrapped_lines(lines_a, width, 601, tag_a) == expected_a

      # 2. Sliding append window 5..615 (reuses block 1: 256..511 from cache)
      lines_b = Enum.map(5..615, make_line)
      expected_b = ViewHelper.count_wrapped_lines(lines_b, width)
      tag_b = {5, 615, "", :all, scope}
      assert ViewHelper.count_wrapped_lines(lines_b, width, 611, tag_b) == expected_b

      # 3. Prepended negative seq window -300..615 (covers -256..-1 negative chunk boundary)
      lines_c = Enum.map(-300..615, make_line)
      expected_c = ViewHelper.count_wrapped_lines(lines_c, width)
      tag_c = {-300, 615, "", :all, scope}
      assert ViewHelper.count_wrapped_lines(lines_c, width, 916, tag_c) == expected_c

      # 4. Different gen invalidates chunk cache even for identical seq/width
      alt_lines =
        Enum.map(0..600, fn _ -> %{timestamp: nil, stream: :stdout, message: "short"} end)

      tag_gen2 = {0, 600, "", :all, {"srv1", "c1", 2}}
      assert ViewHelper.count_wrapped_lines(alt_lines, width, 601, tag_gen2) == 601
    end

    test "find_wrapped_line_offset chunked matches linear scan across boundaries" do
      Process.delete(:cached_wrapped_lines_count)
      Process.delete(:wrap_chunk_cache)

      lines =
        Enum.map(-50..600, fn seq ->
          msg =
            if rem(abs(seq), 5) == 0,
              do: "line-#{seq} " <> String.duplicate("x", 35),
              else: "short-#{seq}"

          %{timestamp: nil, stream: :stdout, message: msg}
        end)

      width = 20
      tag = {-50, 600, "", :all, {"srv1", "c1", 1}}
      total_wrapped = ViewHelper.count_wrapped_lines(lines, width, 651, tag)

      for target <- [0, 1, 15, 250, 420, total_wrapped - 1, total_wrapped + 5] do
        linear = ViewHelper.find_wrapped_line_offset(lines, target, width)
        chunked = ViewHelper.find_wrapped_line_offset(lines, target, width, 651, tag)
        assert chunked == linear
      end

      assert ViewHelper.find_wrapped_line_offset([], 10, width) == {0, 0}
    end
  end
end
