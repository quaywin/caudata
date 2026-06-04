defmodule Caudata.ConfigManagerTest do
  use ExUnit.Case, async: false
  alias Caudata.ConfigManager

  test "parse_ssh_config parses supported directives correctly" do
    content = """
    # SSH Configuration Example
    Host my-server
        HostName 192.168.1.100
        User deploy
        Port 2222
        IdentityFile ~/.ssh/id_rsa
        UnsupportedDirective yes

    Host another-server
        HostName example.com
        User admin
        # Default port 22
        IdentityFile "/etc/keys/admin_key"
    """

    temp_path = "test/caudata_temp_config"
    File.write!(temp_path, content)

    on_exit(fn ->
      File.rm(temp_path)
    end)

    assert {:ok, profiles} = ConfigManager.parse_ssh_config(temp_path)
    assert length(profiles) == 2

    [p1, p2] = profiles

    assert p1.id == "my-server"
    assert p1.host_pattern == "my-server"
    assert p1.host_name == "192.168.1.100"
    assert p1.user == "deploy"
    assert p1.port == 2222
    assert p1.identity_file == Path.expand("~/.ssh/id_rsa")

    assert p2.id == "another-server"
    assert p2.host_pattern == "another-server"
    assert p2.host_name == "example.com"
    assert p2.user == "admin"
    assert p2.port == 22
    assert p2.identity_file == Path.expand("/etc/keys/admin_key")
  end

  test "ConfigManager loads config on start and manages manual profiles" do
    content = """
    Host boot-server
        HostName 10.0.0.1
        User root
    """

    temp_path = "test/caudata_temp_boot_config"
    File.write!(temp_path, content)

    # Use a unique ETS config path for this test
    old_path = System.get_env("CAUDATA_CONFIG_PATH")
    temp_config = "test/fixtures/config_manager_boot_test.db"
    System.put_env("CAUDATA_CONFIG_PATH", temp_config)

    on_exit(fn ->
      File.rm(temp_path)

      if old_path do
        System.put_env("CAUDATA_CONFIG_PATH", old_path)
      else
        System.delete_env("CAUDATA_CONFIG_PATH")
      end

      File.rm_rf(temp_config)
    end)

    # Start a uniquely named ConfigManager for testing to avoid name conflict with global one
    {:ok, _pid} =
      start_supervised({ConfigManager, name: TestConfigManager, ssh_config_path: temp_path})

    # Initial profiles list should be empty because we don't load from ssh config at boot anymore
    profiles = ConfigManager.list_profiles(TestConfigManager)
    assert length(profiles) == 0

    # Discovering profiles on demand should work
    discovered = ConfigManager.discover_ssh_profiles(TestConfigManager)
    assert length(discovered) == 1
    p = List.first(discovered)
    assert p.id == "boot-server"
    assert p.user == "root"

    # Add manual profile
    assert {:ok, added} =
             ConfigManager.add_manual_profile(TestConfigManager, %{
               host_pattern: "manual-host",
               host_name: "10.0.0.2",
               user: "ubuntu",
               port: 2200
             })

    assert added.id == "manual-host"
    assert added.user == "ubuntu"
    assert added.port == 2200

    # Ensure listed
    all = ConfigManager.list_profiles(TestConfigManager)
    assert length(all) == 1
    assert Enum.any?(all, fn p -> p.id == "manual-host" end)

    # Get specific profile
    assert ConfigManager.get_profile(TestConfigManager, "manual-host").user == "ubuntu"
    assert is_nil(ConfigManager.get_profile(TestConfigManager, "nonexistent"))
  end

  test "parse_ssh_config handles Include directive and filters wildcards" do
    # Create temp config.d folder for testing includes
    File.mkdir_p!("test/config.d")

    main_content = """
    Host main-server
        HostName 1.1.1.1

    Include config.d/*

    Host *
        IdentityFile ~/.ssh/id_rsa
    """

    include_content = """
    Host included-server
        HostName 2.2.2.2
    """

    File.write!("test/caudata_main_config", main_content)
    File.write!("test/config.d/included_config", include_content)

    on_exit(fn ->
      File.rm("test/caudata_main_config")
      File.rm_rf!("test/config.d")
    end)

    assert {:ok, profiles} = ConfigManager.parse_ssh_config("test/caudata_main_config")

    # Should only contain main-server and included-server, wildcards like * must be filtered out
    assert length(profiles) == 2
    ids = Enum.map(profiles, & &1.id)
    assert "main-server" in ids
    assert "included-server" in ids
    refute "*" in ids
  end

  test "ConfigManager updates profile settings and persists them" do
    old_path = System.get_env("CAUDATA_CONFIG_PATH")
    temp_config = "test/fixtures/config_manager_update_test.db"
    System.put_env("CAUDATA_CONFIG_PATH", temp_config)

    on_exit(fn ->
      if old_path do
        System.put_env("CAUDATA_CONFIG_PATH", old_path)
      else
        System.delete_env("CAUDATA_CONFIG_PATH")
      end

      File.rm_rf(temp_config)
    end)

    # Start a uniquely named ConfigManager
    {:ok, _pid} =
      start_supervised(
        {ConfigManager, name: UpdateTestConfigManager, ssh_config_path: "nonexistent"}
      )

    # Add a profile first
    assert {:ok, _added} =
             ConfigManager.add_manual_profile(UpdateTestConfigManager, %{
               host_pattern: "update-server",
               host_name: "10.0.0.10",
               user: "root",
               port: 22
             })

    # Update profile settings
    assert {:ok, updated} =
             ConfigManager.update_profile(UpdateTestConfigManager, "update-server", %{
               disabled_containers: ["container1"],
               custom_logs: ["/var/log/syslog"]
             })

    assert updated.disabled_containers == ["container1"]
    assert updated.custom_logs == ["/var/log/syslog"]

    # Verify lists reflect the update
    profiles = ConfigManager.list_profiles(UpdateTestConfigManager)
    updated_profile = Enum.find(profiles, &(&1.id == "update-server"))
    assert updated_profile.disabled_containers == ["container1"]
    assert updated_profile.custom_logs == ["/var/log/syslog"]

    # Load from file to verify persistence
    assert {:ok, loaded_config} = Caudata.Config.load()
    assert [p] = Caudata.Config.custom_profiles(loaded_config)
    assert p.id == "update-server"
    assert p.disabled_containers == ["container1"]
    assert p.custom_logs == ["/var/log/syslog"]
  end

  test "ConfigManager deletes a profile and terminates worker" do
    old_path = System.get_env("CAUDATA_CONFIG_PATH")
    temp_config = "test/fixtures/config_manager_delete_test.db"
    System.put_env("CAUDATA_CONFIG_PATH", temp_config)

    on_exit(fn ->
      if old_path do
        System.put_env("CAUDATA_CONFIG_PATH", old_path)
      else
        System.delete_env("CAUDATA_CONFIG_PATH")
      end

      File.rm_rf(temp_config)
    end)

    # Start a uniquely named ConfigManager
    {:ok, _pid} =
      start_supervised(
        {ConfigManager, name: DeleteTestConfigManager, ssh_config_path: "nonexistent"}
      )

    # Add profile
    assert {:ok, _added} =
             ConfigManager.add_manual_profile(DeleteTestConfigManager, %{
               host_pattern: "delete-server",
               host_name: "10.0.0.20",
               port: 22
             })

    assert length(ConfigManager.list_profiles(DeleteTestConfigManager)) == 1

    # Delete profile
    assert :ok = ConfigManager.delete_profile(DeleteTestConfigManager, "delete-server")
    assert length(ConfigManager.list_profiles(DeleteTestConfigManager)) == 0

    # Load from file to verify persistence (should be empty)
    assert {:ok, loaded_config} = Caudata.Config.load()
    assert Caudata.Config.custom_profiles(loaded_config) == []
  end
end
