defmodule Caudata.UI.Components.ContainerActionModalTest do
  use ExUnit.Case, async: true

  alias Caudata.UI.Components.ContainerActionModal
  alias ExRatatui.Widgets.Popup

  describe "render_confirm/1" do
    test "renders popup for confirm_delete_server modal_type" do
      state = %{
        modal_type: :confirm_delete_server,
        delete_server_id: "test-server-123"
      }

      [popup] = ContainerActionModal.render_confirm(state)
      assert %Popup{} = popup
      assert popup.block.title == " ⚠️ Confirm DELETE SERVER "
    end

    test "renders popup for confirm_docker_action modal_type" do
      state = %{
        modal_type: :confirm_docker_action,
        pending_docker_action: :kill,
        selected_container_name: "my_container"
      }

      [popup] = ContainerActionModal.render_confirm(state)
      assert %Popup{} = popup
      assert popup.block.title == " ⚠️ Confirm FORCE KILL (SIGKILL) "
    end
  end

  describe "handle_key_confirm/3 for confirm_delete_server" do
    setup do
      server_id = "test-delete-server"
      _ = Caudata.ConfigManager.add_manual_profile(%{id: server_id, host_pattern: "test-delete"})

      on_exit(fn ->
        _ = Caudata.ConfigManager.delete_profile(server_id)
      end)

      state = %{
        modal_type: :confirm_delete_server,
        modal_visible: true,
        delete_server_id: server_id,
        profiles: [
          %Caudata.Profile{id: server_id, host_pattern: "test-delete"},
          %Caudata.Profile{id: "other-server", host_pattern: "other"}
        ],
        selected_profile_id: server_id,
        settings_selected_profile_idx: 0
      }

      {:ok, state: state, server_id: server_id}
    end

    test "on 'y' key deletes profile, removes from profiles, updates selected_profile_id, and sets notification", %{state: state, server_id: server_id} do
      {new_state, cmds} = ContainerActionModal.handle_key_confirm("y", %{}, state)

      assert cmds == []
      assert new_state.modal_visible == false
      assert new_state.delete_server_id == nil
      refute Enum.any?(new_state.profiles, &(&1.id == server_id))
      assert new_state.selected_profile_id == "other-server"
      assert new_state.notification == {"Server #{server_id} deleted", 30}
    end

    test "on 'Enter' key deletes profile", %{state: state, server_id: server_id} do
      {new_state, cmds} = ContainerActionModal.handle_key_confirm(:enter, %{}, state)

      assert cmds == []
      assert new_state.modal_visible == false
      refute Enum.any?(new_state.profiles, &(&1.id == server_id))
    end

    test "on 'n' or 'Esc' key cancels deletion and restores state", %{state: state, server_id: server_id} do
      {new_state, cmds} = ContainerActionModal.handle_key_confirm("n", %{}, state)

      assert cmds == []
      assert new_state.modal_visible == false
      assert new_state.delete_server_id == nil
      assert Enum.any?(new_state.profiles, &(&1.id == server_id))
      assert new_state.selected_profile_id == server_id

      {new_state_esc, _} = ContainerActionModal.handle_key_confirm(:escape, %{}, state)
      assert new_state_esc.modal_visible == false
      assert new_state_esc.delete_server_id == nil
    end
  end
end
