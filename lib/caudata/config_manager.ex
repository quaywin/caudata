defmodule Caudata.ConfigManager do
  use GenServer
  require Logger
  alias Caudata.Profile

  @default_config_path "~/.ssh/config"

  # Client API

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Lists all loaded and manual profiles directly from the ConfigStore (non-blocking).
  """
  def list_profiles(server \\ __MODULE__) do
    Caudata.ConfigStore.list_profiles(get_store_name(server))
  end

  @doc """
  Gets a specific profile by its ID directly from the ConfigStore (non-blocking).
  """
  def get_profile(server \\ __MODULE__, id) do
    Caudata.ConfigStore.get_profile(get_store_name(server), id)
  end

  @doc """
  Adds a manual connection profile.
  """
  def add_manual_profile(server \\ __MODULE__, attrs) do
    GenServer.call(server, {:add_manual_profile, attrs})
  end

  @doc """
  Updates a profile's settings.
  """
  def update_profile(server \\ __MODULE__, id, updates) do
    GenServer.call(server, {:update_profile, id, updates})
  end

  @doc """
  Deletes a profile by its ID.
  """
  def delete_profile(server \\ __MODULE__, id) do
    GenServer.call(server, {:delete_profile, id})
  end

  @doc """
  Discovers profiles from the configured SSH config path.
  """
  def discover_ssh_profiles(server \\ __MODULE__) do
    GenServer.call(server, :discover_ssh_profiles)
  end

  # Helper to resolve isolated ConfigStore name
  defp get_store_name(server) do
    if server == __MODULE__ do
      Caudata.ConfigStore
    else
      Module.concat(server, Store)
    end
  end

  # GenServer Callbacks

  @impl true
  def init(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    store_name = get_store_name(name)

    # Start the linked ConfigStore to handle ETS and I/O
    config_path = Keyword.get(opts, :config_path) || Caudata.Config.config_path()
    {:ok, _store_pid} = Caudata.ConfigStore.start_link(name: store_name, config_path: config_path)

    ssh_config_path =
      Keyword.get(opts, :ssh_config_path) || System.get_env("CAUDATA_SSH_CONFIG_PATH") ||
        @default_config_path

    {:ok, %{store: store_name, ssh_config_path: ssh_config_path}}
  end

  @impl true
  def handle_call(:list_profiles, _from, state) do
    # For backward compatibility in any GenServer.call, though direct list_profiles/1 bypasses this call
    profiles = Caudata.ConfigStore.list_profiles(state.store)
    {:reply, profiles, state}
  end

  @impl true
  def handle_call({:get_profile, id}, _from, state) do
    # For backward compatibility in any GenServer.call, though direct get_profile/2 bypasses this call
    profile = Caudata.ConfigStore.get_profile(state.store, id)
    {:reply, profile, state}
  end

  @impl true
  def handle_call(:discover_ssh_profiles, _from, state) do
    expanded_path = Path.expand(state.ssh_config_path)

    profiles =
      if File.exists?(expanded_path) do
        case parse_ssh_config(expanded_path) do
          {:ok, list} ->
            Logger.info("Discovered #{length(list)} profiles from SSH config at #{expanded_path}")

            list

          {:error, reason} ->
            Logger.info("Failed to parse SSH config at #{expanded_path}: #{inspect(reason)}")
            []
        end
      else
        Logger.info("No SSH config file found at #{expanded_path}")
        []
      end

    {:reply, profiles, state}
  end

  @impl true
  def handle_call({:add_manual_profile, attrs}, _from, state) do
    try do
      profile = Profile.new(attrs)
      profile = Map.put(profile, :enabled, Map.get(profile, :enabled, true))

      :ok = Caudata.ConfigStore.add_profile(state.store, profile)

      all_profiles = Caudata.ConfigStore.list_profiles(state.store)

      # Broadcast profiles update
      Phoenix.PubSub.broadcast(
        Caudata.PubSub,
        "config:profiles",
        {:profiles_updated, all_profiles}
      )

      {:reply, {:ok, profile}, state}
    rescue
      e ->
        {:reply, {:error, e}, state}
    end
  end

  @impl true
  def handle_call({:update_profile, id, updates}, _from, state) do
    old_profile = Caudata.ConfigStore.get_profile(state.store, id)

    case Caudata.ConfigStore.update_profile(state.store, id, updates) do
      {:ok, updated_profile} ->
        # Handle worker lifecycle based on enabled flag transitions
        was_enabled = old_profile && Map.get(old_profile, :enabled, true)
        is_enabled = updated_profile.enabled

        cond do
          # Transition from disabled -> enabled: clean start/restart
          not was_enabled and is_enabled ->
            _ =
              Task.start(fn ->
                start_time = System.monotonic_time(:millisecond)

                case Caudata.ServerSupervisor.lookup_worker(id) do
                  {:ok, pid} ->
                    ref = Process.monitor(pid)
                    _ = Caudata.ServerSupervisor.stop_worker(id)

                    # Await the actual process termination to avoid registry collisions
                    receive do
                      {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
                    after
                      5000 -> :ok
                    end

                    _ = Caudata.UI.ViewHelper.start_worker_if_needed(updated_profile)
                    duration = System.monotonic_time(:millisecond) - start_time

                    Logger.info(
                      "Restarted ServerWorker for #{id} in #{duration}ms (including stop wait)"
                    )

                  {:error, :not_found} ->
                    _ = Caudata.UI.ViewHelper.start_worker_if_needed(updated_profile)
                    duration = System.monotonic_time(:millisecond) - start_time
                    Logger.info("Started ServerWorker for #{id} in #{duration}ms")
                end
              end)

          # If it was already enabled and stays enabled: cast update (or restart if connection details changed)
          was_enabled and is_enabled ->
            connection_changed? =
              old_profile.host_name != updated_profile.host_name or
                old_profile.port != updated_profile.port or
                old_profile.user != updated_profile.user or
                old_profile.identity_file != updated_profile.identity_file or
                Map.get(old_profile, :password) != Map.get(updated_profile, :password)

            if connection_changed? do
              _ =
                Task.start(fn ->
                  start_time = System.monotonic_time(:millisecond)

                  case Caudata.ServerSupervisor.lookup_worker(id) do
                    {:ok, pid} ->
                      ref = Process.monitor(pid)
                      _ = Caudata.ServerSupervisor.stop_worker(id)

                      # Await the actual process termination to avoid registry collisions
                      receive do
                        {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
                      after
                        5000 -> :ok
                      end

                      _ = Caudata.UI.ViewHelper.start_worker_if_needed(updated_profile)
                      duration = System.monotonic_time(:millisecond) - start_time

                      Logger.info(
                        "Restarted ServerWorker for #{id} due to connection change in #{duration}ms"
                      )

                    {:error, :not_found} ->
                      _ = Caudata.UI.ViewHelper.start_worker_if_needed(updated_profile)
                      duration = System.monotonic_time(:millisecond) - start_time
                      Logger.info("Started ServerWorker for #{id} in #{duration}ms")
                  end
                end)
            else
              case Caudata.ServerSupervisor.lookup_worker(id) do
                {:ok, pid} -> GenServer.cast(pid, {:update_profile, updated_profile})
                _ -> :ok
              end
            end

          # If it transitioned from enabled -> disabled: stop worker
          was_enabled and not is_enabled ->
            _ = Task.start(fn -> Caudata.ServerSupervisor.stop_worker(id) end)

          true ->
            :ok
        end

        all_profiles = Caudata.ConfigStore.list_profiles(state.store)

        # Broadcast profiles update
        Phoenix.PubSub.broadcast(
          Caudata.PubSub,
          "config:profiles",
          {:profiles_updated, all_profiles}
        )

        {:reply, {:ok, updated_profile}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:delete_profile, id}, _from, state) do
    # Stop worker before deleting profile from store
    Caudata.ServerSupervisor.stop_worker(id)

    :ok = Caudata.ConfigStore.delete_profile(state.store, id)

    all_profiles = Caudata.ConfigStore.list_profiles(state.store)

    # Broadcast profiles update
    Phoenix.PubSub.broadcast(
      Caudata.PubSub,
      "config:profiles",
      {:profiles_updated, all_profiles}
    )

    {:reply, :ok, state}
  end

  # Parsing Logic

  @doc """
  Parses an SSH config file and returns a list of profiles.
  """
  def parse_ssh_config(path) do
    expanded_path = Path.expand(path)

    if File.exists?(expanded_path) do
      lines = read_lines_recursive(expanded_path, [])

      profiles =
        lines
        |> Enum.reduce({[], nil}, &parse_line/2)
        |> finalize_last_profile()

      {:ok, profiles}
    else
      {:error, :enoent}
    end
  end

  defp read_lines_recursive(path, visited) do
    expanded_path = Path.expand(path)

    if expanded_path in visited or not File.exists?(expanded_path) do
      []
    else
      visited = [expanded_path | visited]
      config_dir = Path.dirname(expanded_path)

      case File.read(expanded_path) do
        {:ok, content} ->
          content
          |> String.split(["\r\n", "\n"])
          |> Enum.flat_map(fn line ->
            trimmed = String.trim(line)
            clean_line = strip_inline_comment(trimmed)

            case String.split(clean_line, ~r{[\s=]+}, parts: 2) do
              [key, val] ->
                directive = String.downcase(String.trim(key))
                value = String.trim(val)

                if directive == "include" do
                  resolved_pattern = expand_include_path(value, config_dir)

                  Path.wildcard(resolved_pattern)
                  |> Enum.flat_map(fn child_path ->
                    read_lines_recursive(child_path, visited)
                  end)
                else
                  [line]
                end

              _ ->
                [line]
            end
          end)

        {:error, _} ->
          []
      end
    end
  end

  defp expand_include_path(value, config_dir) do
    clean_val = String.replace(value, ~r{^"|"$}, "")

    cond do
      String.starts_with?(clean_val, "~") ->
        Path.expand(clean_val)

      Path.type(clean_val) == :absolute ->
        clean_val

      true ->
        Path.join(config_dir, clean_val)
    end
  end

  defp parse_line(line, {acc, current}) do
    trimmed = String.trim(line)

    if trimmed == "" or String.starts_with?(trimmed, "#") do
      {acc, current}
    else
      clean_line = strip_inline_comment(trimmed)

      case String.split(clean_line, ~r{[\s=]+}, parts: 2) do
        [key, val] ->
          directive = String.downcase(String.trim(key))
          value = String.trim(val)
          handle_directive(directive, value, acc, current)

        _ ->
          {acc, current}
      end
    end
  end

  defp strip_inline_comment(line) do
    line
    |> String.split("#", parts: 2)
    |> List.first()
    |> String.trim()
  end

  defp handle_directive("host", value, acc, current) do
    acc = if current, do: [build_profile(current) | acc], else: acc
    host_pattern = List.first(String.split(value, ~r{\s+}))

    new_profile = %{
      id: host_pattern,
      host_pattern: host_pattern,
      host_name: host_pattern,
      port: 22,
      identity_file: nil,
      user: nil
    }

    {acc, new_profile}
  end

  defp handle_directive("hostname", value, acc, current) when not is_nil(current) do
    {acc, Map.put(current, :host_name, value)}
  end

  defp handle_directive("user", value, acc, current) when not is_nil(current) do
    {acc, Map.put(current, :user, value)}
  end

  defp handle_directive("port", value, acc, current) when not is_nil(current) do
    port =
      case Integer.parse(value) do
        {int, _} -> int
        _ -> 22
      end

    {acc, Map.put(current, :port, port)}
  end

  defp handle_directive("identityfile", value, acc, current) when not is_nil(current) do
    clean_val = String.replace(value, ~r{^"|"$}, "")
    expanded = Path.expand(clean_val)
    {acc, Map.put(current, :identity_file, expanded)}
  end

  defp handle_directive(_, _value, acc, current) do
    {acc, current}
  end

  defp finalize_last_profile({acc, nil}) do
    acc
    |> Enum.reverse()
    |> Enum.filter(&valid_profile?/1)
  end

  defp finalize_last_profile({acc, current}) do
    [build_profile(current) | acc]
    |> Enum.reverse()
    |> Enum.filter(&valid_profile?/1)
  end

  defp valid_profile?(profile) do
    not (String.contains?(profile.host_pattern, "*") or
           String.contains?(profile.host_pattern, "?"))
  end

  defp build_profile(map) do
    Profile.new(map)
  end
end
