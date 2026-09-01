defmodule Caudata.UI.Components.SettingsModalTest do
  use ExUnit.Case, async: true

  alias Caudata.UI.Components.SettingsModal

  describe "filter_services/2" do
    @services [
      %{id: "systemd:nginx.service", name: "nginx.service", image: "systemd"},
      %{id: "systemd:ssh.service", name: "ssh.service", image: "systemd"},
      %{id: "launchd:com.apple.Finder", name: "com.apple.Finder", image: "launchd"},
      %{
        id: "systemd:postgresql@14-main.service",
        name: "postgresql@14-main.service",
        image: "systemd"
      }
    ]

    test "returns the original list when query is empty" do
      assert SettingsModal.filter_services(@services, "") == @services
    end

    test "returns the original list when query is whitespace only" do
      assert SettingsModal.filter_services(@services, "   ") == @services
    end

    test "filters by substring match on name (case-insensitive)" do
      result = SettingsModal.filter_services(@services, "NGINX")
      assert length(result) == 1
      assert hd(result).id == "systemd:nginx.service"
    end

    test "filters by substring match on id" do
      result = SettingsModal.filter_services(@services, "com.apple")
      assert length(result) == 1
      assert hd(result).id == "launchd:com.apple.Finder"
    end

    test "matches multiple services when query is broad" do
      result = SettingsModal.filter_services(@services, ".service")
      assert length(result) == 3
    end

    test "matches services by partial name with special characters" do
      result = SettingsModal.filter_services(@services, "postgresql")
      assert length(result) == 1
      assert hd(result).name == "postgresql@14-main.service"
    end

    test "returns empty list when nothing matches" do
      assert SettingsModal.filter_services(@services, "nonexistent") == []
    end

    test "returns original list when query is not a binary" do
      assert SettingsModal.filter_services(@services, nil) == @services
    end
  end

  describe "truncate_name/2" do
    test "pads short names to the target length" do
      assert SettingsModal.truncate_name("nginx", 10) == "nginx     "
    end

    test "returns the name unchanged when it equals the target length" do
      assert SettingsModal.truncate_name("0123456789", 10) == "0123456789"
    end

    test "truncates with ellipsis when name exceeds target length" do
      result = SettingsModal.truncate_name("postgresql@14-main.service", 15)
      assert String.length(result) == 15
      assert String.ends_with?(result, "…")
      # slice(0, max_len - 1) keeps 14 chars, then appends ellipsis
      assert String.starts_with?(result, "postgresql@14-")
    end

    test "converts non-binary input to string" do
      assert SettingsModal.truncate_name(:foo, 10) == "foo       "
    end

    test "handles very short max_len" do
      result = SettingsModal.truncate_name("longname", 3)
      assert result == "lo…"
    end
  end

  describe "handle_key bounded navigation" do
    test "servers tab cursor bounds at top 0 and bottom total-1" do
      profiles = [
        %Caudata.Profile{id: "p1", host_pattern: "p1", host_name: "1.1.1.1"},
        %Caudata.Profile{id: "p2", host_pattern: "p2", host_name: "2.2.2.2"},
        %Caudata.Profile{id: "p3", host_pattern: "p3", host_name: "3.3.3.3"}
      ]

      state = %{
        modal_visible: true,
        modal_type: :settings,
        settings_focus: :servers,
        settings_selected_profile_idx: 0,
        profiles: profiles,
        containers: %{},
        height: 24,
        settings_input_active: false,
        settings_service_search_active: false
      }

      # Up at 0 stays at 0
      {s_up, []} = SettingsModal.handle_key(:up, %{}, state)
      assert s_up.settings_selected_profile_idx == 0

      # Down moves to 1
      {s1, []} = SettingsModal.handle_key(:down, %{}, state)
      assert s1.settings_selected_profile_idx == 1

      # End / G moves to 2 (last)
      {s_end, []} = SettingsModal.handle_key(:char, %{char: "G"}, s1)
      assert s_end.settings_selected_profile_idx == 2

      # Down at last stays at last
      {s_down_stop, []} = SettingsModal.handle_key(:down, %{}, s_end)
      assert s_down_stop.settings_selected_profile_idx == 2

      # Home / g moves to 0
      {s_home, []} = SettingsModal.handle_key(:char, %{char: "g"}, s_down_stop)
      assert s_home.settings_selected_profile_idx == 0
    end

    test "containers tab cursor bounds" do
      state = %{
        modal_visible: true,
        modal_type: :settings,
        settings_focus: :containers,
        settings_container_idx: 0,
        selected_profile_id: "p1",
        profiles: [%Caudata.Profile{id: "p1", host_pattern: "p1"}],
        containers: %{
          "p1" => [
            %{id: "c1", name: "c1", image: "img1"},
            %{id: "c2", name: "c2", image: "img2"}
          ]
        },
        height: 24,
        settings_input_active: false,
        settings_service_search_active: false
      }

      # Up at 0 stays at 0
      {s_up, []} = SettingsModal.handle_key(:up, %{}, state)
      assert s_up.settings_container_idx == 0

      # Down moves to 1
      {s1, []} = SettingsModal.handle_key(:down, %{}, state)
      assert s1.settings_container_idx == 1

      # Down at 1 stays at 1
      {s2, []} = SettingsModal.handle_key(:down, %{}, s1)
      assert s2.settings_container_idx == 1
    end
  end
end
