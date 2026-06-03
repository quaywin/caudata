defmodule Caudata.Config do
  @moduledoc """
  Manages loading, parsing, and persisting settings from ~/.caudata/config.toml.
  """
  require Logger

  @default_dir "~/.caudata"
  @default_file "config.toml"

  @doc """
  Returns the path to the configuration file.
  Can be overridden by the CAUDATA_CONFIG_PATH environment variable.
  """
  def config_path do
    System.get_env("CAUDATA_CONFIG_PATH") ||
      Path.join(Path.expand(@default_dir), @default_file)
  end

  @doc """
  Loads the configuration. If the file doesn't exist, it creates a default one.
  """
  def load do
    path = config_path()
    ensure_config_exists(path)

    case Toml.decode_file(path) do
      {:ok, config} ->
        {:ok, config}

      {:error, reason} ->
        Logger.error(
          "Failed to parse TOML config at #{path}: #{inspect(reason)}. Using default settings."
        )

        {:ok, default_config()}
    end
  end

  @doc """
  Appends a manual connection profile to the config.toml file for persistence.
  """
  def append_profile(profile_attrs) do
    path = config_path()
    ensure_config_exists(path)

    id = profile_attrs[:id] || profile_attrs["id"]
    host_name = profile_attrs[:host_name] || profile_attrs["host_name"] || id
    user = profile_attrs[:user] || profile_attrs["user"]
    port = profile_attrs[:port] || profile_attrs["port"] || 22
    identity_file = profile_attrs[:identity_file] || profile_attrs["identity_file"]
    log_command = profile_attrs[:log_command] || profile_attrs["log_command"]

    lines = [
      "",
      "[[profiles]]",
      "id = #{inspect(id)}",
      "host_name = #{inspect(host_name)}",
      "port = #{port}"
    ]

    lines = if user, do: lines ++ ["user = #{inspect(user)}"], else: lines

    lines =
      if identity_file, do: lines ++ ["identity_file = #{inspect(identity_file)}"], else: lines

    lines = if log_command, do: lines ++ ["log_command = #{inspect(log_command)}"], else: lines

    entry = Enum.join(lines, "\n") <> "\n"

    case File.write(path, entry, [:append]) do
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
    case Map.get(config, "profiles") do
      profiles when is_list(profiles) ->
        Enum.map(profiles, fn p ->
          id = Map.get(p, "id")
          host_name = Map.get(p, "host_name") || id

          %{
            id: id,
            host_pattern: host_name,
            host_name: host_name,
            user: Map.get(p, "user"),
            port: Map.get(p, "port") || 22,
            identity_file: maybe_expand_path(Map.get(p, "identity_file")),
            log_command: Map.get(p, "log_command") || global_log_command(config)
          }
        end)

      _ ->
        []
    end
  end

  defp maybe_expand_path(nil), do: nil
  defp maybe_expand_path(path), do: Path.expand(path)

  # Private helpers

  defp ensure_config_exists(path) do
    unless File.exists?(path) do
      dir = Path.dirname(path)
      File.mkdir_p!(dir)

      default_toml = """
      # Caudata Configuration File
      # Located at ~/.caudata/config.toml

      [global]
      # Bounded queue capacity for logs (default: 1000)
      capacity = 1000

      # Default command to run on remote servers to stream logs
      log_command = "tail -F /var/log/messages"

      # Whether to auto-discover connection profiles from ~/.ssh/config (default: true)
      discover_ssh_config = true

      [ssh_server]
      # Enable the collaborative SSH UI server (default: false)
      enabled = false
      ip = "127.0.0.1"
      port = 2222
      host_keys_dir = "~/.caudata/ssh_keys"
      """

      File.write!(path, default_toml)
      Logger.info("Created default configuration file at #{path}")
    end
  end

  defp default_config do
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
end
