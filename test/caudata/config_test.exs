defmodule Caudata.ConfigTest do
  # async: false because it modifies the config file path env var
  use ExUnit.Case, async: false

  @temp_config_path "test/fixtures/temp_config.toml"

  setup do
    old_path = System.get_env("CAUDATA_CONFIG_PATH")
    System.put_env("CAUDATA_CONFIG_PATH", @temp_config_path)

    on_exit(fn ->
      if old_path do
        System.put_env("CAUDATA_CONFIG_PATH", old_path)
      else
        System.delete_env("CAUDATA_CONFIG_PATH")
      end

      File.rm_rf(@temp_config_path)
    end)

    :ok
  end

  test "load/0 creates a default config if it doesn't exist" do
    refute File.exists?(@temp_config_path)

    assert {:ok, config} = Caudata.Config.load()
    assert File.exists?(@temp_config_path)

    assert Caudata.Config.global_capacity(config) == 1000
    assert Caudata.Config.global_log_command(config) == "tail -F /var/log/messages"
    assert Caudata.Config.discover_ssh_config?(config) == true

    assert Caudata.Config.ssh_server_settings(config) == %{
             enabled: false,
             ip: "127.0.0.1",
             port: 2222,
             host_keys_dir: "~/.caudata/ssh_keys"
           }

    assert Caudata.Config.custom_profiles(config) == []
  end

  test "load/0 loads existing config from file" do
    content = """
    [global]
    capacity = 5000
    log_command = "journalctl -f"
    discover_ssh_config = false

    [ssh_server]
    enabled = true
    ip = "0.0.0.0"
    port = 2223
    host_keys_dir = "/tmp/keys"

    [[profiles]]
    id = "custom-server"
    host_name = "10.0.0.5"
    user = "deploy"
    port = 2222
    identity_file = "/tmp/id_rsa"
    log_command = "tail -f log"
    """

    File.mkdir_p!(Path.dirname(@temp_config_path))
    File.write!(@temp_config_path, content)

    assert {:ok, config} = Caudata.Config.load()

    assert Caudata.Config.global_capacity(config) == 5000
    assert Caudata.Config.global_log_command(config) == "journalctl -f"
    assert Caudata.Config.discover_ssh_config?(config) == false

    assert Caudata.Config.ssh_server_settings(config) == %{
             enabled: true,
             ip: "0.0.0.0",
             port: 2223,
             host_keys_dir: "/tmp/keys"
           }

    assert [profile] = Caudata.Config.custom_profiles(config)
    assert profile.id == "custom-server"
    assert profile.host_name == "10.0.0.5"
    assert profile.user == "deploy"
    assert profile.port == 2222
    assert profile.identity_file == "/tmp/id_rsa"
    assert profile.log_command == "tail -f log"
  end

  test "append_profile/1 persists a profile to the config file" do
    assert {:ok, _config} = Caudata.Config.load()

    profile_attrs = %{
      id: "appended-server",
      host_name: "10.0.0.6",
      user: "admin",
      port: 22,
      identity_file: "/tmp/id_rsa",
      log_command: "tail -F /var/log/app.log"
    }

    assert :ok = Caudata.Config.append_profile(profile_attrs)

    assert {:ok, reloaded_config} = Caudata.Config.load()
    assert [profile] = Caudata.Config.custom_profiles(reloaded_config)
    assert profile.id == "appended-server"
    assert profile.host_name == "10.0.0.6"
    assert profile.user == "admin"
    assert profile.port == 22
    assert profile.identity_file == "/tmp/id_rsa"
    assert profile.log_command == "tail -F /var/log/app.log"
  end

  test "append_profile/1 handles nil fields gracefully" do
    assert {:ok, _config} = Caudata.Config.load()

    profile_attrs = %{
      id: "minimal-server",
      host_name: "10.0.0.7",
      port: 22,
      user: nil,
      identity_file: nil,
      log_command: nil
    }

    assert :ok = Caudata.Config.append_profile(profile_attrs)

    assert {:ok, reloaded_config} = Caudata.Config.load()
    assert [profile] = Caudata.Config.custom_profiles(reloaded_config)
    assert profile.id == "minimal-server"
    assert profile.host_name == "10.0.0.7"
    assert profile.port == 22
    assert is_nil(profile.user)
    assert is_nil(profile.identity_file)
    # falls back to global default
    assert profile.log_command == "tail -F /var/log/messages"
  end
end
