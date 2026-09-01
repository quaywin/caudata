defmodule Caudata.UI.Components.AddServerModalTest do
  use ExUnit.Case, async: true

  alias Caudata.UI.Components.AddServerModal
  alias ExRatatui.Widgets.Popup

  describe "render/1 for :select_ssh" do
    test "renders popup with default title when options fit in display limit" do
      state = %{
        modal_type: :select_ssh,
        ssh_config_profiles: [
          %Caudata.Profile{id: "server1", host_pattern: "server1", host_name: "10.0.0.1", port: 22, user: "root"}
        ],
        modal_selected_index: 0,
        modal_error: nil,
        width: 80,
        height: 24
      }

      [popup] = AddServerModal.render(state)
      assert %Popup{} = popup
      assert popup.block.title == " Add Connection "
      assert length(popup.content.text) > 0
    end

    test "renders scrolled window and progress indicator when options exceed display limit" do
      profiles =
        for i <- 1..25 do
          %Caudata.Profile{id: "server#{i}", host_pattern: "server#{i}", host_name: "10.0.0.#{i}", port: 22, user: "admin"}
        end

      state = %{
        modal_type: :select_ssh,
        ssh_config_profiles: profiles,
        modal_selected_index: 15,
        modal_error: nil,
        width: 80,
        height: 20
      }

      [popup] = AddServerModal.render(state)
      assert %Popup{} = popup
      assert popup.block.title == " Add Connection [16/27] "
    end

    test "renders error lines when modal_error is set" do
      state = %{
        modal_type: :select_ssh,
        ssh_config_profiles: [],
        modal_selected_index: 0,
        modal_error: "Connection refused",
        width: 80,
        height: 24
      }

      [popup] = AddServerModal.render(state)
      assert %Popup{} = popup
      lines_text = Enum.map(popup.content.text, fn line ->
        Enum.map(line.spans, & &1.content) |> Enum.join()
      end)

      assert Enum.any?(lines_text, &String.contains?(&1, "Error: Connection refused"))
    end
  end

  describe "handle_key/3 for :select_ssh navigation bounds" do
    setup do
      profiles = [
        %Caudata.Profile{id: "srv1", host_pattern: "srv1", host_name: "1.1.1.1", port: 22},
        %Caudata.Profile{id: "srv2", host_pattern: "srv2", host_name: "1.1.1.2", port: 22},
        %Caudata.Profile{id: "srv3", host_pattern: "srv3", host_name: "1.1.1.3", port: 22}
      ]

      state = %{
        modal_visible: true,
        modal_type: :select_ssh,
        ssh_config_profiles: profiles,
        modal_selected_index: 0,
        modal_focus_index: 0,
        modal_error: nil,
        modal_fields: %{},
        profiles: [],
        height: 24,
        width: 80
      }

      # Total options: 2 (manual, local) + 3 profiles = 5 (indices 0..4)
      {:ok, state: state}
    end

    test "down key moves cursor down and stops at lower bound without wrapping", %{state: state} do
      {s1, _} = AddServerModal.handle_key(:down, %{}, state)
      assert s1.modal_selected_index == 1

      {s2, _} = AddServerModal.handle_key("j", %{}, s1)
      assert s2.modal_selected_index == 2

      {s3, _} = AddServerModal.handle_key("j", %{}, s2)
      assert s3.modal_selected_index == 3

      {s4, _} = AddServerModal.handle_key(:down, %{}, s3)
      assert s4.modal_selected_index == 4

      # At index 4 (last option), pressing down stays at 4
      {s5, _} = AddServerModal.handle_key(:down, %{}, s4)
      assert s5.modal_selected_index == 4

      {s6, _} = AddServerModal.handle_key("j", %{}, s5)
      assert s6.modal_selected_index == 4
    end

    test "up key moves cursor up and stops at upper bound (0) without wrapping", %{state: state} do
      # Start at index 0, pressing up stays at 0
      {s0, _} = AddServerModal.handle_key(:up, %{}, state)
      assert s0.modal_selected_index == 0

      {s0_k, _} = AddServerModal.handle_key("k", %{}, state)
      assert s0_k.modal_selected_index == 0

      # Move down to 2 then back up
      state_at_2 = %{state | modal_selected_index: 2}
      {s1, _} = AddServerModal.handle_key(:up, %{}, state_at_2)
      assert s1.modal_selected_index == 1

      {s0_again, _} = AddServerModal.handle_key("k", %{}, s1)
      assert s0_again.modal_selected_index == 0

      # Moving up from 0 stays at 0
      {s0_stop, _} = AddServerModal.handle_key(:up, %{}, s0_again)
      assert s0_stop.modal_selected_index == 0
    end

    test "home and end keys jump to bounds", %{state: state} do
      {s_end, _} = AddServerModal.handle_key(:end, %{}, state)
      assert s_end.modal_selected_index == 4

      {s_home, _} = AddServerModal.handle_key(:home, %{}, s_end)
      assert s_home.modal_selected_index == 0

      {s_G, _} = AddServerModal.handle_key("G", %{}, state)
      assert s_G.modal_selected_index == 4

      {s_g, _} = AddServerModal.handle_key("g", %{}, s_G)
      assert s_g.modal_selected_index == 0
    end

    test "page_down and page_up jump with bounds", %{state: state} do
      {s_pgdn, _} = AddServerModal.handle_key(:page_down, %{}, state)
      assert s_pgdn.modal_selected_index == 4

      {s_pgup, _} = AddServerModal.handle_key(:page_up, %{}, s_pgdn)
      assert s_pgup.modal_selected_index == 0
    end

    test "enter on index 0 switches to manual_input", %{state: state} do
      {new_state, _} = AddServerModal.handle_key(:enter, %{}, %{state | modal_selected_index: 0})
      assert new_state.modal_type == :manual_input
      assert new_state.modal_focus_index == 0
      assert is_map(new_state.modal_fields)
    end

    test "enter on index 1 switches to local_input", %{state: state} do
      {new_state, _} = AddServerModal.handle_key(:enter, %{}, %{state | modal_selected_index: 1})
      assert new_state.modal_type == :local_input
      assert new_state.modal_focus_index == 0
      assert is_map(new_state.modal_fields)
    end

    test "escape key closes modal", %{state: state} do
      {new_state, _} = AddServerModal.handle_key(:escape, %{}, state)
      assert new_state.modal_visible == false
    end
  end
end
