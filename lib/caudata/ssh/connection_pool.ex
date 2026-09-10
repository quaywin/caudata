defmodule Caudata.SSH.ConnectionPool do
  @moduledoc """
  Manages a pool of SSH connections for a single remote server profile.

  To avoid exceeding OpenSSH server `MaxSessions` limits (typically 10 per TCP connection),
  this pool maintains multiple SSH connections when the number of concurrent channels
  exceeds `max_channels_per_conn` (default: 8).
  """

  use GenServer
  require Logger

  @default_max_channels_per_conn 8

  defstruct [
    :profile,
    :ssh_client,
    :max_channels_per_conn,
    # %{conn_ref => %{active_channels: integer(), channels: MapSet.t(), monitor_ref: reference() | nil, is_primary: boolean()}}
    connections: %{},
    # List of conn_refs in order of creation
    conn_order: [],
    # %{channel_key => {conn_ref, channel_id, caller_pid, caller_monitor_ref}}
    active_leases: %{},
    # %{caller_monitor_ref => {caller_pid, [channel_key]}}
    caller_monitors: %{}
  ]

  # Client API

  @doc """
  Starts the ConnectionPool.

  ## Options
  * `:profile` - `%Caudata.Profile{}` (required)
  * `:ssh_client` - Module implementing `Caudata.SSHClient` behaviour (defaults to `Caudata.SSHClient.Native`)
  * `:max_channels_per_conn` - Maximum channels per connection (defaults to 8)
  * `:name` - Optional GenServer registration name
  """
  def start_link(opts) do
    name = Keyword.get(opts, :name)
    gen_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @doc """
  Checks out an available connection reference from the pool and reserves a channel slot.
  Returns `{:ok, conn_ref, lease_ref}` or `{:error, reason}`.
  """
  def checkout_connection(pool, caller_pid \\ nil) do
    pid = caller_pid || self()
    GenServer.call(pool, {:checkout_connection, pid}, 30_000)
  end

  @doc """
  Releases a checked out connection slot back to the pool using the lease_ref.
  """
  def release_connection(pool, conn_ref, lease_ref) do
    GenServer.call(pool, {:release_connection, conn_ref, lease_ref})
  end

  @doc """
  Attaches a created channel_id to an active lease for tracking and introspection.
  """
  def attach_channel(pool, conn_ref, lease_ref, channel_id) do
    GenServer.call(pool, {:attach_channel, conn_ref, lease_ref, channel_id})
  end

  @doc """
  Acquires an open SSH channel from the pool.
  Finds a connection with active_channels < max_channels_per_conn, or establishes a new connection.
  Returns `{:ok, conn_ref, channel_id}` or `{:error, reason}`.
  """
  def acquire_channel(pool, caller_pid \\ nil) do
    pid = caller_pid || self()
    GenServer.call(pool, {:acquire_channel, pid}, 30_000)
  end

  @doc """
  Releases an SSH channel back to the pool.
  """
  def release_channel(pool, conn_ref, channel_id) do
    GenServer.call(pool, {:release_channel, conn_ref, channel_id})
  end

  @doc """
  Returns a snapshot of the connections currently in the pool and their channel counts.
  """
  def get_status(pool) do
    GenServer.call(pool, :get_status)
  end

  @doc """
  Closes all connections in the pool and resets state.
  """
  def close_all(pool) do
    GenServer.call(pool, :close_all)
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    profile = Keyword.fetch!(opts, :profile)
    ssh_client = Keyword.get(opts, :ssh_client, Caudata.SSHClient.Native)
    max_channels = Keyword.get(opts, :max_channels_per_conn, @default_max_channels_per_conn)

    state = %__MODULE__{
      profile: profile,
      ssh_client: ssh_client,
      max_channels_per_conn: max_channels,
      connections: %{},
      conn_order: [],
      active_leases: %{},
      caller_monitors: %{}
    }

    state =
      case Keyword.get(opts, :primary_conn) do
        nil -> state
        conn_ref -> do_add_primary(state, conn_ref)
      end

    {:ok, state}
  end

  @impl true
  def handle_call({:checkout_connection, caller_pid}, _from, state) do
    case find_or_create_connection(state) do
      {:ok, conn_ref, state} ->
        lease_ref = make_ref()
        state = register_lease(state, conn_ref, lease_ref, caller_pid)
        {:reply, {:ok, conn_ref, lease_ref}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:release_connection, conn_ref, lease_ref}, _from, state) do
    state = do_release_lease(state, conn_ref, lease_ref)
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:attach_channel, conn_ref, lease_ref, channel_id}, _from, state) do
    state = do_attach_channel(state, conn_ref, lease_ref, channel_id)
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:acquire_channel, caller_pid}, _from, state) do
    case find_or_create_connection(state) do
      {:ok, conn_ref, state} ->
        case state.ssh_client.open_channel(conn_ref) do
          {:ok, channel_id} ->
            lease_ref = make_ref()
            state = register_lease(state, conn_ref, lease_ref, caller_pid)
            state = do_attach_channel(state, conn_ref, lease_ref, channel_id)
            {:reply, {:ok, conn_ref, channel_id}, state}

          {:error, reason} ->
            Logger.warning(
              "Failed to open channel on SSH connection #{inspect(conn_ref)}: #{inspect(reason)}"
            )

            {:reply, {:error, reason}, state}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:release_channel, conn_ref, channel_id}, _from, state) do
    state = do_release_channel(state, conn_ref, channel_id)
    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:get_status, _from, state) do
    status = %{
      connection_count: map_size(state.connections),
      max_channels_per_conn: state.max_channels_per_conn,
      connections:
        Enum.map(state.conn_order, fn conn_ref ->
          info = Map.get(state.connections, conn_ref, %{})

          %{
            conn_ref: conn_ref,
            active_channels: Map.get(info, :active_channels, 0),
            is_primary: Map.get(info, :is_primary, false)
          }
        end)
    }

    {:reply, status, state}
  end

  @impl true
  def handle_call(:close_all, _from, state) do
    # Demonitor all callers
    Enum.each(state.caller_monitors, fn {mref, _} ->
      Process.demonitor(mref, [:flush])
    end)

    # Demonitor all connections
    Enum.each(state.connections, fn {_conn_ref, info} ->
      if info.monitor_ref, do: Process.demonitor(info.monitor_ref, [:flush])
    end)

    # Close all channels
    Enum.each(state.active_leases, fn {_key, lease} ->
      if lease.channel_id do
        try do
          state.ssh_client.close_channel(lease.conn_ref, lease.channel_id)
        catch
          _, _ -> :ok
        end
      end
    end)

    # Close all connections
    Enum.each(state.connections, fn {conn_ref, _info} ->
      try do
        state.ssh_client.close(conn_ref)
      catch
        _, _ -> :ok
      end
    end)

    new_state = %{
      state
      | connections: %{},
        conn_order: [],
        active_leases: %{},
        caller_monitors: %{}
    }

    {:reply, :ok, new_state}
  end

  # Handle caller process crash
  @impl true
  def handle_info({:DOWN, mref, :process, pid, reason}, state) do
    cond do
      # Check if this is a connection process dying
      Enum.find(state.connections, fn {_c, info} -> info.monitor_ref == mref end) ->
        {conn_ref, _info} =
          Enum.find(state.connections, fn {_c, info} -> info.monitor_ref == mref end)

        Logger.warning(
          "SSH connection #{inspect(conn_ref)} died in pool for #{state.profile.id}: #{inspect(reason)}"
        )

        state = handle_connection_down(state, conn_ref)
        {:noreply, state}

      # Check if this is a caller process dying
      Map.has_key?(state.caller_monitors, mref) ->
        {^pid, lease_keys} = Map.get(state.caller_monitors, mref)

        Logger.info(
          "Caller process #{inspect(pid)} died (#{inspect(reason)}), cleaning up #{length(lease_keys)} leased channel(s)"
        )

        state =
          Enum.reduce(lease_keys, state, fn {conn_ref, lease_ref}, acc ->
            do_release_lease(acc, conn_ref, lease_ref, false)
          end)

        state = %{state | caller_monitors: Map.delete(state.caller_monitors, mref)}
        {:noreply, state}

      true ->
        {:noreply, state}
    end
  end

  @impl true
  def terminate(_reason, state) do
    # Demonitor all callers
    Enum.each(state.caller_monitors, fn {mref, _} ->
      Process.demonitor(mref, [:flush])
    end)

    # Demonitor all connections
    Enum.each(state.connections, fn {_conn_ref, info} ->
      if info.monitor_ref, do: Process.demonitor(info.monitor_ref, [:flush])
    end)

    # Cleanup all connections on pool termination
    Enum.each(state.connections, fn {conn_ref, _info} ->
      try do
        state.ssh_client.close(conn_ref)
      catch
        _, _ -> :ok
      end
    end)

    :ok
  end

  # Private Helpers

  defp do_add_primary(state, conn_ref) do
    if Map.has_key?(state.connections, conn_ref) do
      state
    else
      mref = if is_pid(conn_ref), do: Process.monitor(conn_ref), else: nil

      conn_info = %{
        active_channels: 0,
        channels: MapSet.new(),
        monitor_ref: mref,
        is_primary: true
      }

      %{
        state
        | connections: Map.put(state.connections, conn_ref, conn_info),
          conn_order: [conn_ref | state.conn_order] |> Enum.reverse()
      }
    end
  end

  defp find_or_create_connection(state) do
    # Try to find an existing connection with available capacity
    available =
      Enum.find(state.conn_order, fn conn_ref ->
        case Map.get(state.connections, conn_ref) do
          %{active_channels: count} -> count < state.max_channels_per_conn
          _ -> false
        end
      end)

    if available do
      {:ok, available, state}
    else
      # All current connections are full or none exist, establish a new connection
      Logger.info(
        "All connections in pool full for #{state.profile.id} (capacity: #{state.max_channels_per_conn} ch/conn). Opening new connection..."
      )

      case connect_new(state) do
        {:ok, new_conn_ref, state} ->
          {:ok, new_conn_ref, state}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp connect_new(state) do
    connect_opts = [
      user: state.profile.user,
      identity_file: state.profile.identity_file,
      password: Map.get(state.profile, :password)
    ]

    case state.ssh_client.connect(state.profile.host_name, state.profile.port, connect_opts) do
      {:ok, conn_ref} ->
        mref = if is_pid(conn_ref), do: Process.monitor(conn_ref), else: nil
        is_first = map_size(state.connections) == 0

        conn_info = %{
          active_channels: 0,
          channels: MapSet.new(),
          monitor_ref: mref,
          is_primary: is_first
        }

        new_state = %{
          state
          | connections: Map.put(state.connections, conn_ref, conn_info),
            conn_order: state.conn_order ++ [conn_ref]
        }

        Logger.info(
          "Successfully added new SSH connection #{inspect(conn_ref)} to pool for #{state.profile.id} (total: #{map_size(new_state.connections)})"
        )

        {:ok, conn_ref, new_state}

      {:error, reason} ->
        Logger.error(
          "Failed to establish new SSH connection in pool for #{state.profile.id}: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  defp register_lease(state, conn_ref, lease_ref, caller_pid) do
    lease_key = {conn_ref, lease_ref}

    # Monitor caller if valid pid
    {mref, state} =
      if is_pid(caller_pid) and Process.alive?(caller_pid) do
        # Check if we already monitor this caller
        existing_mref =
          Enum.find_value(state.caller_monitors, fn {ref, {pid, _keys}} ->
            if pid == caller_pid, do: ref, else: nil
          end)

        if existing_mref do
          {_pid, keys} = Map.get(state.caller_monitors, existing_mref)

          new_caller_monitors =
            Map.put(state.caller_monitors, existing_mref, {caller_pid, [lease_key | keys]})

          {existing_mref, %{state | caller_monitors: new_caller_monitors}}
        else
          ref = Process.monitor(caller_pid)
          new_caller_monitors = Map.put(state.caller_monitors, ref, {caller_pid, [lease_key]})
          {ref, %{state | caller_monitors: new_caller_monitors}}
        end
      else
        {nil, state}
      end

    # Record lease
    new_leases =
      Map.put(state.active_leases, lease_key, %{
        conn_ref: conn_ref,
        lease_ref: lease_ref,
        caller_pid: caller_pid,
        monitor_ref: mref,
        channel_id: nil
      })

    # Update connection info
    conn_info =
      Map.get(state.connections, conn_ref, %{active_channels: 0, channels: MapSet.new()})

    updated_info = %{
      conn_info
      | active_channels: conn_info.active_channels + 1
    }

    %{
      state
      | active_leases: new_leases,
        connections: Map.put(state.connections, conn_ref, updated_info)
    }
  end

  defp do_attach_channel(state, conn_ref, lease_ref, channel_id) do
    lease_key = {conn_ref, lease_ref}

    case Map.get(state.active_leases, lease_key) do
      nil ->
        state

      lease ->
        updated_lease = %{lease | channel_id: channel_id}
        conn_info = Map.get(state.connections, conn_ref)

        updated_conn =
          if conn_info do
            %{conn_info | channels: MapSet.put(conn_info.channels, channel_id)}
          else
            conn_info
          end

        state = %{state | active_leases: Map.put(state.active_leases, lease_key, updated_lease)}

        if updated_conn,
          do: %{state | connections: Map.put(state.connections, conn_ref, updated_conn)},
          else: state
    end
  end

  defp do_release_lease(state, conn_ref, lease_ref, cleanup_monitor \\ true) do
    lease_key = {conn_ref, lease_ref}

    {channel_id, state} =
      case Map.pop(state.active_leases, lease_key) do
        {nil, _} ->
          {nil, state}

        {lease, remaining_leases} ->
          if lease.channel_id do
            try do
              state.ssh_client.close_channel(conn_ref, lease.channel_id)
            catch
              _, _ -> :ok
            end
          end

          state = %{state | active_leases: remaining_leases}

          if cleanup_monitor and lease.monitor_ref do
            case Map.get(state.caller_monitors, lease.monitor_ref) do
              {_pid, [^lease_key]} ->
                Process.demonitor(lease.monitor_ref, [:flush])

                {lease.channel_id,
                 %{state | caller_monitors: Map.delete(state.caller_monitors, lease.monitor_ref)}}

              {pid, keys} ->
                new_keys = List.delete(keys, lease_key)

                {lease.channel_id,
                 %{
                   state
                   | caller_monitors:
                       Map.put(state.caller_monitors, lease.monitor_ref, {pid, new_keys})
                 }}

              nil ->
                {lease.channel_id, state}
            end
          else
            {lease.channel_id, state}
          end
      end

    # Decrement connection channel count
    case Map.get(state.connections, conn_ref) do
      nil ->
        state

      conn_info ->
        new_count = max(0, conn_info.active_channels - 1)

        new_channels =
          if channel_id,
            do: MapSet.delete(conn_info.channels, channel_id),
            else: conn_info.channels

        # Check if a non-primary connection has 0 channels and we have more than 1 connection
        if new_count == 0 and not Map.get(conn_info, :is_primary, false) and
             map_size(state.connections) > 1 do
          # Clean up idle secondary SSH connection
          Logger.info("Closing idle secondary SSH connection #{inspect(conn_ref)} in pool")
          if conn_info.monitor_ref, do: Process.demonitor(conn_info.monitor_ref, [:flush])

          try do
            state.ssh_client.close(conn_ref)
          catch
            _, _ -> :ok
          end

          %{
            state
            | connections: Map.delete(state.connections, conn_ref),
              conn_order: List.delete(state.conn_order, conn_ref)
          }
        else
          updated_info = %{conn_info | active_channels: new_count, channels: new_channels}
          %{state | connections: Map.put(state.connections, conn_ref, updated_info)}
        end
    end
  end

  defp do_release_channel(state, conn_ref, channel_id, cleanup_monitor \\ true) do
    # Find matching lease
    matching_entry =
      Enum.find(state.active_leases, fn {{c, _lref}, lease} ->
        c == conn_ref and lease.channel_id == channel_id
      end)

    case matching_entry do
      {{^conn_ref, lease_ref}, _lease} ->
        do_release_lease(state, conn_ref, lease_ref, cleanup_monitor)

      nil ->
        try do
          state.ssh_client.close_channel(conn_ref, channel_id)
        catch
          _, _ -> :ok
        end

        case Map.get(state.connections, conn_ref) do
          nil ->
            state

          conn_info ->
            new_count = max(0, conn_info.active_channels - 1)
            new_channels = MapSet.delete(conn_info.channels, channel_id)

            %{
              state
              | connections:
                  Map.put(state.connections, conn_ref, %{
                    conn_info
                    | active_channels: new_count,
                      channels: new_channels
                  })
            }
        end
    end
  end

  defp handle_connection_down(state, conn_ref) do
    # Clean up leases belonging to this connection
    remaining_leases =
      state.active_leases
      |> Enum.reject(fn {{c, _lref}, _} -> c == conn_ref end)
      |> Map.new()

    new_connections = Map.delete(state.connections, conn_ref)
    new_order = List.delete(state.conn_order, conn_ref)

    %{
      state
      | active_leases: remaining_leases,
        connections: new_connections,
        conn_order: new_order
    }
  end
end
