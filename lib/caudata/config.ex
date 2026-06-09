defmodule Caudata.Config do
  @moduledoc """
  Manages loading, parsing, and persisting settings using a binary ETS file at ~/.caudata/config.db.
  """
  require Logger

  @default_dir "~/.caudata"
  @default_file "config.db"

  @doc """
  Returns the path to the configuration file.
  Can be overridden by the CAUDATA_CONFIG_PATH environment variable.
  """
  def config_path do
    System.get_env("CAUDATA_CONFIG_PATH") ||
      Path.join(Path.expand(@default_dir), @default_file)
  end

  @doc """
  Returns the path to the ETS file.
  """
  def ets_path do
    config_path()
  end

  @doc """
  Loads the configuration. If the file doesn't exist, it creates a default one.
  """
  def load do
    path = config_path()
    char_path = String.to_charlist(path)

    case :ets.file2tab(char_path) do
      {:ok, tab} ->
        config_map = ets_to_map(tab)
        :ets.delete(tab)
        {:ok, config_map}

      {:error, _reason} ->
        default = default_config_map()
        ensure_config_exists(path, default)
        {:ok, default}
    end
  end

  @doc """
  Appends a manual connection profile to the ETS config file for persistence.
  """
  def append_profile(profile_attrs) do
    path = config_path()
    char_path = String.to_charlist(path)

    tab =
      case :ets.file2tab(char_path) do
        {:ok, t} -> t
        {:error, _} -> :ets.new(:caudata_config_file, [:set, :public])
      end

    profile =
      case profile_attrs do
        %Caudata.Profile{} -> Caudata.Profile.ensure_struct_fields(profile_attrs)
        _ -> Caudata.Profile.new(profile_attrs)
      end

    :ets.insert(tab, {{:profile, profile.id}, profile})
    res = :ets.tab2file(tab, char_path)
    :ets.delete(tab)

    case res do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # Helper functions to extract configuration values

  def global_capacity(config) do
    get_in(config, ["global", "capacity"]) || 1000
  end

  def global_log_command(config) do
    get_in(config, ["global", "log_command"]) || "tail -F /var/log/messages"
  end

  def discover_ssh_config?(config) do
    case get_in(config, ["global", "discover_ssh_config"]) do
      nil -> true
      val -> val
    end
  end

  def ssh_server_settings(config) do
    %{
      enabled: get_in(config, ["ssh_server", "enabled"]) || false,
      ip: get_in(config, ["ssh_server", "ip"]) || "127.0.0.1",
      port: get_in(config, ["ssh_server", "port"]) || 2222,
      host_keys_dir: get_in(config, ["ssh_server", "host_keys_dir"]) || "~/.caudata/ssh_keys"
    }
  end

  def custom_profiles(config) do
    Map.get(config, "profiles") || []
  end

  @doc """
  Saves the list of profiles back to the configuration file, updating existing ones.
  """
  def save_profiles(profiles) do
    path = config_path()
    char_path = String.to_charlist(path)

    tab =
      case :ets.file2tab(char_path) do
        {:ok, t} -> t
        {:error, _} -> :ets.new(:caudata_config_file, [:set, :public])
      end

    # Delete existing profile records
    existing = :ets.match_object(tab, {{:profile, :_}, :_})
    Enum.each(existing, fn {key, _} -> :ets.delete(tab, key) end)

    # Insert new ones
    Enum.each(profiles, fn p ->
      profile_struct =
        case p do
          %Caudata.Profile{} -> Caudata.Profile.ensure_struct_fields(p)
          _ -> Caudata.Profile.new(p)
        end

      :ets.insert(tab, {{:profile, profile_struct.id}, profile_struct})
    end)

    res = :ets.tab2file(tab, char_path)
    :ets.delete(tab)

    case res do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # Helper functions to serialize/deserialize between ETS and Map

  defp ets_to_map(tab) do
    global_capacity =
      case :ets.lookup(tab, {:global, :capacity}) do
        [{_, val}] -> val
        _ -> 1000
      end

    global_log_command =
      case :ets.lookup(tab, {:global, :log_command}) do
        [{_, val}] -> val
        _ -> "tail -F /var/log/messages"
      end

    discover_ssh_config =
      case :ets.lookup(tab, {:global, :discover_ssh_config}) do
        [{_, val}] -> val
        _ -> true
      end

    ssh_enabled =
      case :ets.lookup(tab, {:ssh_server, :enabled}) do
        [{_, val}] -> val
        _ -> false
      end

    ssh_ip =
      case :ets.lookup(tab, {:ssh_server, :ip}) do
        [{_, val}] -> val
        _ -> "127.0.0.1"
      end

    ssh_port =
      case :ets.lookup(tab, {:ssh_server, :port}) do
        [{_, val}] -> val
        _ -> 2222
      end

    ssh_keys_dir =
      case :ets.lookup(tab, {:ssh_server, :host_keys_dir}) do
        [{_, val}] -> val
        _ -> "~/.caudata/ssh_keys"
      end

    profiles =
      :ets.match_object(tab, {{:profile, :_}, :_})
      |> Enum.map(fn {_, profile} ->
        Caudata.Profile.ensure_struct_fields(profile)
      end)

    %{
      "global" => %{
        "capacity" => global_capacity,
        "log_command" => global_log_command,
        "discover_ssh_config" => discover_ssh_config
      },
      "ssh_server" => %{
        "enabled" => ssh_enabled,
        "ip" => ssh_ip,
        "port" => ssh_port,
        "host_keys_dir" => ssh_keys_dir
      },
      "profiles" => profiles
    }
  end

  defp default_config_map do
    %{
      "global" => %{
        "capacity" => 1000,
        "log_command" => "tail -F /var/log/messages",
        "discover_ssh_config" => true
      },
      "ssh_server" => %{
        "enabled" => false,
        "ip" => "127.0.0.1",
        "port" => 2222,
        "host_keys_dir" => "~/.caudata/ssh_keys"
      },
      "profiles" => []
    }
  end

  defp map_to_ets(tab, map) do
    :ets.insert(tab, {{:global, :capacity}, get_in(map, ["global", "capacity"])})
    :ets.insert(tab, {{:global, :log_command}, get_in(map, ["global", "log_command"])})

    :ets.insert(
      tab,
      {{:global, :discover_ssh_config}, get_in(map, ["global", "discover_ssh_config"])}
    )

    :ets.insert(tab, {{:ssh_server, :enabled}, get_in(map, ["ssh_server", "enabled"])})
    :ets.insert(tab, {{:ssh_server, :ip}, get_in(map, ["ssh_server", "ip"])})
    :ets.insert(tab, {{:ssh_server, :port}, get_in(map, ["ssh_server", "port"])})

    :ets.insert(
      tab,
      {{:ssh_server, :host_keys_dir}, get_in(map, ["ssh_server", "host_keys_dir"])}
    )

    profiles = Map.get(map, "profiles") || []

    Enum.each(profiles, fn p ->
      profile_struct =
        case p do
          %Caudata.Profile{} -> Caudata.Profile.ensure_struct_fields(p)
          _ -> Caudata.Profile.new(p)
        end

      :ets.insert(tab, {{:profile, profile_struct.id}, profile_struct})
    end)
  end

  defp ensure_config_exists(path, default_map) do
    unless File.exists?(path) do
      dir = Path.dirname(path)
      File.mkdir_p!(dir)

      # Write default map as an ETS file
      tab = :ets.new(:caudata_config_file, [:set, :public])
      map_to_ets(tab, default_map)
      :ok = :ets.tab2file(tab, String.to_charlist(path))
      :ets.delete(tab)
      Logger.info("Created default configuration file at #{path}")
    end
  end
end
