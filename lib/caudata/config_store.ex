defmodule Caudata.ConfigStore do
  @moduledoc """
  A specialized, decoupled storage backend that owns and manages the ETS table for configuration.
  Reads are direct ETS queries running in the caller's process for zero latency, while
  writes are serialized through the GenServer and persisted to disk in a background Task.
  """
  use GenServer
  require Logger

  # Client API

  @doc """
  Starts the ConfigStore.
  Accepts:
    * `:name` - name of the GenServer and the ETS table. Defaults to `Caudata.ConfigStore`.
    * `:config_path` - path to the config file. Defaults to `Caudata.Config.config_path()`.
  """
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Lists all profiles directly from ETS (non-blocking).
  """
  def list_profiles(store \\ __MODULE__) do
    tab = get_table_name(store)

    :ets.match_object(tab, {{:profile, :_}, :_})
    |> Enum.map(fn {_, p} -> Caudata.Profile.ensure_struct_fields(p) end)
  end

  @doc """
  Gets a specific profile directly from ETS (non-blocking).
  """
  def get_profile(store \\ __MODULE__, id) do
    tab = get_table_name(store)

    case :ets.lookup(tab, {:profile, id}) do
      [{_, p}] -> Caudata.Profile.ensure_struct_fields(p)
      [] -> nil
    end
  end

  @doc """
  Adds a new manual profile.
  """
  def add_profile(store \\ __MODULE__, profile) do
    GenServer.call(store, {:add_profile, profile})
  end

  @doc """
  Updates an existing profile.
  """
  def update_profile(store \\ __MODULE__, id, updates) do
    GenServer.call(store, {:update_profile, id, updates})
  end

  @doc """
  Deletes a profile by its ID.
  """
  def delete_profile(store \\ __MODULE__, id) do
    GenServer.call(store, {:delete_profile, id})
  end

  @doc """
  Retrieves a global setting directly from ETS (non-blocking).
  """
  def get_setting(store \\ __MODULE__, section, key, default \\ nil) do
    tab = get_table_name(store)

    case :ets.lookup(tab, {section, key}) do
      [{_, val}] -> val
      [] -> default
    end
  end

  @doc """
  Saves a global setting.
  """
  def put_setting(store \\ __MODULE__, section, key, value) do
    GenServer.call(store, {:put_setting, section, key, value})
  end

  @doc """
  Saves a batch of global settings.
  Expects a list of tuples: `[{section, key, value}, ...]`
  """
  def put_settings(store \\ __MODULE__, settings) when is_list(settings) do
    GenServer.call(store, {:put_settings, settings})
  end

  # Helper to resolve table name from GenServer name/ref
  defp get_table_name(store) when is_atom(store), do: store

  defp get_table_name(store) when is_pid(store) do
    GenServer.call(store, :get_table_name)
  end

  # GenServer Callbacks

  @impl true
  def init(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    path = Keyword.get(opts, :config_path) || Caudata.Config.config_path()
    char_path = String.to_charlist(path)

    # Initialize public ETS table using GenServer's registered name
    my_tab =
      case :ets.info(name) do
        :undefined ->
          :ets.new(name, [:named_table, :public, :set, {:read_concurrency, true}])

        _info ->
          name
      end

    # Load initial config from database file if present, else initialize defaults
    if File.exists?(path) do
      case :ets.file2tab(char_path) do
        {:ok, file_tab} ->
          :ets.foldl(
            fn element, _acc ->
              sanitized_element =
                case element do
                  {{:profile, id}, profile} ->
                    {{:profile, id}, Caudata.Profile.ensure_struct_fields(profile)}

                  other ->
                    other
                end

              :ets.insert(my_tab, sanitized_element)
            end,
            :ok,
            file_tab
          )

          :ets.delete(file_tab)

        {:error, _reason} ->
          initialize_defaults(my_tab)
      end
    else
      initialize_defaults(my_tab)
    end

    {:ok, %{table: my_tab, config_path: path, save_timer: nil}}
  end

  @impl true
  def handle_call(:get_table_name, _from, state) do
    {:reply, state.table, state}
  end

  @impl true
  def handle_call({:add_profile, profile}, _from, state) do
    profile = Caudata.Profile.ensure_struct_fields(profile)
    :ets.insert(state.table, {{:profile, profile.id}, profile})
    new_state = save_async(state)
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call({:update_profile, id, updates}, _from, state) do
    case :ets.lookup(state.table, {:profile, id}) do
      [{_, p}] ->
        p = Caudata.Profile.ensure_struct_fields(p)
        updated_profile = struct!(p, updates)

        updated_profile = Caudata.Profile.ensure_struct_fields(updated_profile)

        :ets.insert(state.table, {{:profile, id}, updated_profile})
        new_state = save_async(state)
        {:reply, {:ok, updated_profile}, new_state}

      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call({:delete_profile, id}, _from, state) do
    :ets.delete(state.table, {:profile, id})
    new_state = save_async(state)
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call({:put_setting, section, key, value}, _from, state) do
    :ets.insert(state.table, {{section, key}, value})
    new_state = save_async(state)
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call({:put_settings, settings}, _from, state) do
    Enum.each(settings, fn {section, key, value} ->
      :ets.insert(state.table, {{section, key}, value})
    end)

    new_state = save_async(state)
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_info(:perform_save, state) do
    do_perform_save(state)
    {:noreply, Map.put(state, :save_timer, nil)}
  end

  # Helpers

  defp initialize_defaults(t) do
    :ets.insert(t, {{:global, :capacity}, 10000})
    :ets.insert(t, {{:global, :discover_ssh_config}, true})

    :ets.insert(t, {{:ssh_server, :enabled}, false})
    :ets.insert(t, {{:ssh_server, :ip}, "127.0.0.1"})
    :ets.insert(t, {{:ssh_server, :port}, 2222})
    :ets.insert(t, {{:ssh_server, :host_keys_dir}, "~/.caudata/ssh_keys"})

    # Trigger synchronous save of defaults
    path = Caudata.Config.config_path()
    char_path = String.to_charlist(path)
    dir = Path.dirname(path)
    File.mkdir_p!(dir)

    file_tab = :ets.new(:caudata_config_file, [:set, :public])

    :ets.foldl(
      fn element, _acc ->
        :ets.insert(file_tab, element)
      end,
      :ok,
      t
    )

    :ok = :ets.tab2file(file_tab, char_path)
    :ets.delete(file_tab)
    :ok
  end

  defp save_async(state) do
    if Application.get_env(:caudata, :env) == :test do
      do_perform_save(state)
      state
    else
      if state.save_timer, do: Process.cancel_timer(state.save_timer)
      timer = Process.send_after(self(), :perform_save, 200)
      Map.put(state, :save_timer, timer)
    end
  end

  defp do_perform_save(state) do
    # Capture snapshot of the table in memory
    file_tab = :ets.new(:caudata_config_file, [:set, :public])

    :ets.foldl(
      fn element, _acc ->
        :ets.insert(file_tab, element)
      end,
      :ok,
      state.table
    )

    path = state.config_path

    dir = Path.dirname(path)
    File.mkdir_p!(dir)
    tmp_path = path <> ".tmp.#{System.unique_integer([:positive])}"
    tmp_char_path = String.to_charlist(tmp_path)

    try do
      case :ets.tab2file(file_tab, tmp_char_path) do
        :ok ->
          File.rename!(tmp_path, path)

        {:error, reason} ->
          Logger.error("Failed to persist config to disk at #{path}: #{inspect(reason)}")
          File.rm(tmp_path)
      end
    rescue
      e ->
        Logger.error("Error persisting config: #{inspect(e)}")
        File.rm(tmp_path)
    after
      :ets.delete(file_tab)
    end
  end
end
