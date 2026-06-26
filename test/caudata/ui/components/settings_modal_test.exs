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
end
