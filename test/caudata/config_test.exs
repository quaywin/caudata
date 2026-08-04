defmodule Caudata.ConfigTest do
  # async: false because it modifies the config file path env var
  use ExUnit.Case, async: false

  @temp_config_path "test/fixtures/temp_config.db"

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

    assert Caudata.Config.global_capacity(config) == 10000
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
    # Create an ETS table and write it
    tab = :ets.new(:caudata_config, [:set, :public])
    :ets.insert(tab, {{:global, :capacity}, 5000})
    :ets.insert(tab, {{:global, :discover_ssh_config}, false})
    :ets.insert(tab, {{:ssh_server, :enabled}, true})
    :ets.insert(tab, {{:ssh_server, :ip}, "0.0.0.0"})
    :ets.insert(tab, {{:ssh_server, :port}, 2223})
    :ets.insert(tab, {{:ssh_server, :host_keys_dir}, "/tmp/keys"})

    profile =
      Caudata.Profile.new(%{
        id: "custom-server",
        host_pattern: "10.0.0.5",
        host_name: "10.0.0.5",
        user: "deploy",
        port: 2222,
        identity_file: "/tmp/id_rsa"
      })

    :ets.insert(tab, {{:profile, "custom-server"}, profile})

    File.mkdir_p!(Path.dirname(@temp_config_path))
    :ok = :ets.tab2file(tab, String.to_charlist(@temp_config_path))
    :ets.delete(tab)

    assert {:ok, config} = Caudata.Config.load()

    assert Caudata.Config.global_capacity(config) == 5000
    assert Caudata.Config.discover_ssh_config?(config) == false

    assert Caudata.Config.ssh_server_settings(config) == %{
             enabled: true,
             ip: "0.0.0.0",
             port: 2223,
             host_keys_dir: "/tmp/keys"
           }

    assert [profile_loaded] = Caudata.Config.custom_profiles(config)
    assert profile_loaded.id == "custom-server"
    assert profile_loaded.host_name == "10.0.0.5"
    assert profile_loaded.user == "deploy"
    assert profile_loaded.port == 2222
    assert profile_loaded.identity_file == "/tmp/id_rsa"
  end

  test "append_profile/1 persists a profile to the config file" do
    assert {:ok, _config} = Caudata.Config.load()

    profile_attrs = %{
      id: "appended-server",
      host_pattern: "10.0.0.6",
      host_name: "10.0.0.6",
      user: "admin",
      port: 22,
      identity_file: "/tmp/id_rsa"
    }

    assert :ok = Caudata.Config.append_profile(profile_attrs)

    assert {:ok, reloaded_config} = Caudata.Config.load()
    assert [profile] = Caudata.Config.custom_profiles(reloaded_config)
    assert profile.id == "appended-server"
    assert profile.host_name == "10.0.0.6"
    assert profile.user == "admin"
    assert profile.port == 22
    assert profile.identity_file == "/tmp/id_rsa"
  end

  test "append_profile/1 handles nil fields gracefully" do
    assert {:ok, _config} = Caudata.Config.load()

    profile_attrs = %{
      id: "minimal-server",
      host_pattern: "10.0.0.7",
      host_name: "10.0.0.7",
      port: 22,
      user: nil,
      identity_file: nil
    }

    assert :ok = Caudata.Config.append_profile(profile_attrs)

    assert {:ok, reloaded_config} = Caudata.Config.load()
    assert [profile] = Caudata.Config.custom_profiles(reloaded_config)
    assert profile.id == "minimal-server"
    assert profile.host_name == "10.0.0.7"
    assert profile.port == 22
    assert is_nil(profile.user)
    assert is_nil(profile.identity_file)
  end
end
