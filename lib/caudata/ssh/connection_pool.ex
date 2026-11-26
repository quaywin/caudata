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
  @default_health_check_interval 30_000

  defstruct [
    :profile,
    :ssh_client,
    :max_channels_per_conn,
    :health_check_interval,
    :health_check_timer,
    # %{conn_ref => %{active_channels: integer(), channels: MapSet.t(), monitor_ref: reference() | nil, is_primary: boolean()}}
    connections: %{},
    # List of conn_refs in order of creation
    conn_order: [],
    # %{channel_key => {conn_ref, channel_id, caller_pid, caller_monitor_ref}}
    active_leases: %{},
    # %{caller_monitor_ref => {caller_pid, [channel_key]}}
    caller_monitors: %{},
    # When true, pool rejects new checkouts/channels (e.g. while ServerWorker is disconnected)
    suspended: false,
    # Async connect state: nil or %{task_ref: ref, waiters: [{from, :checkout | :acquire, caller_pid}]}
    pending_connect: nil
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
  Optional `status` can be `:ok` or `:error` (e.g. if opening a channel on this connection failed).
  """
  def release_connection(pool, conn_ref, lease_ref, status \\ :ok) do
    GenServer.call(pool, {:release_connection, conn_ref, lease_ref, status})
  end

  @doc """
  Updates the profile used by the connection pool.
  """
  def update_profile(pool, profile) do
    GenServer.call(pool, {:update_profile, profile})
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

  @doc """
  Suspends the pool, closing all connections and rejecting new requests until `resume/1` is called.
  """
  def suspend(pool) do
    GenServer.call(pool, :suspend)
  end

  @doc """
  Resumes the pool so new checkouts/channels are allowed again.
  """
  def resume(pool) do
    GenServer.call(pool, :resume)
  end

  @doc """
  Registers an already-established primary SSH connection in the pool so data channels
  reuse it before opening secondary connections.
  """
  def set_primary_conn(pool, conn_ref) do
    GenServer.call(pool, {:set_primary_conn, conn_ref})
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    profile = Keyword.fetch!(opts, :profile)
    ssh_client = Keyword.get(opts, :ssh_client, Caudata.SSHClient.Native)
    max_channels = Keyword.get(opts, :max_channels_per_conn, @default_max_channels_per_conn)

    health_check_interval =
      Keyword.get(opts, :health_check_interval, default_health_check_interval(ssh_client))

    state = %__MODULE__{
      profile: profile,
      ssh_client: ssh_client,
      max_channels_per_conn: max_channels,
      health_check_interval: health_check_interval,
      health_check_timer: nil,
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

    state = schedule_health_check(state)

    {:ok, state}
  end

  @impl true
  def handle_call({:checkout_connection, caller_pid}, from, state) do
    if state.suspended do
      {:reply, {:error, :pool_suspended}, state}
    else
      case find_available_connection(state) do
        nil ->
          {:noreply, enqueue_connect(state, [{from, :checkout, caller_pid}])}

        conn_ref ->
          {reply, state} = fulfill_request(state, conn_ref, :checkout, caller_pid)
          {:reply, reply, state}
      end
    end
  end

  @impl true
  def handle_call({:update_profile, profile}, _from, state) do
    {:reply, :ok, %{state | profile: profile}}
  end

  @impl true
  def handle_call({:release_connection, conn_ref, lease_ref}, from, state) do
    handle_call({:release_connection, conn_ref, lease_ref, :ok}, from, state)
  end

  @impl true
  def handle_call({:release_connection, conn_ref, lease_ref, status}, _from, state) do
    state = do_release_lease(state, conn_ref, lease_ref)

    state =
      if status == :error do
        Logger.warning(
          "Purging failed SSH connection #{inspect(conn_ref)} from pool for #{state.profile.id}"
        )

        conn_info = Map.get(state.connections, conn_ref)

        if conn_info && conn_info.monitor_ref,
          do: Process.demonitor(conn_info.monitor_ref, [:flush])

        try do
          state.ssh_client.close(conn_ref)
        catch
          _, _ -> :ok
        end

        handle_connection_down(state, conn_ref)
      else
        state
      end

    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:attach_channel, conn_ref, lease_ref, channel_id}, _from, state) do
    state = do_attach_channel(state, conn_ref, lease_ref, channel_id)
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:acquire_channel, caller_pid}, from, state) do
    if state.suspended do
      {:reply, {:error, :pool_suspended}, state}
    else
      case find_available_connection(state) do
        nil ->
          {:noreply, enqueue_connect(state, [{from, :acquire, caller_pid}])}

        conn_ref ->
          {reply, state} = fulfill_request(state, conn_ref, :acquire, caller_pid)
          {:reply, reply, state}
      end
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
    new_state =
      state
      |> do_close_all(:pool_closed)
      |> schedule_health_check()

    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call(:suspend, _from, state) do
    state = cancel_health_check(state)
    new_state = do_close_all(state, :pool_suspended)
    {:reply, :ok, %{new_state | suspended: true}}
  end

  @impl true
  def handle_call(:resume, _from, state) do
    state = %{state | suspended: false}
    state = schedule_health_check(state)
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:set_primary_conn, conn_ref}, _from, state) do
    {:reply, :ok, do_add_primary(state, conn_ref)}
  end

  @impl true
  def handle_info(:health_check, state) do
    if not state.suspended and map_size(state.connections) > 0 do
      pool_pid = self()
      ssh_client = state.ssh_client

      Enum.each(state.conn_order, fn conn_ref ->
        Task.start(fn ->
          res = Caudata.SSHClient.probe_connection(ssh_client, conn_ref)
          send(pool_pid, {:pool_health_check_result, conn_ref, res})
        end)
      end)
    end

    {:noreply, schedule_health_check(state)}
  end

  @impl true
  def handle_info({:pool_health_check_result, _conn_ref, :ok}, state) do
    {:noreply, state}
  end

  @impl true
  def handle_info({:pool_health_check_result, conn_ref, {:error, reason}}, state) do
    case Map.get(state.connections, conn_ref) do
      nil ->
        {:noreply, state}

      conn_info ->
        Logger.warning(
          "Health check failed for pooled SSH connection #{inspect(conn_ref)} (#{state.profile.id}): #{inspect(reason)}, purging"
        )

        if conn_info.monitor_ref, do: Process.demonitor(conn_info.monitor_ref, [:flush])

        try do
          state.ssh_client.close(conn_ref)
        catch
          _, _ -> :ok
        end

        {:noreply, handle_connection_down(state, conn_ref)}
    end
  end

  @impl true
  def handle_info({:pool_connect_result, task_ref, res}, state) do
    case state.pending_connect do
      %{task_ref: ^task_ref, waiters: waiters} ->
        state = %{state | pending_connect: nil}

        case res do
          {:ok, conn_ref} ->
            state = register_connection(state, conn_ref)
            state = serve_waiters(state, waiters)
            {:noreply, state}

          {:error, reason} ->
            Logger.error(
              "Failed to establish new SSH connection in pool for #{state.profile.id}: #{inspect(reason)}"
            )

            {remaining, state} = drain_available(state, waiters)

            Enum.each(remaining, fn {from, _op, _caller_pid} ->
              GenServer.reply(from, {:error, reason})
            end)

            {:noreply, state}
        end

      _ ->
        # Stale connect completed after suspend/close_all — close immediately so nothing leaks
        case res do
          {:ok, conn_ref} ->
            try do
              state.ssh_client.close(conn_ref)
            catch
              _, _ -> :ok
            end

          _ ->
            :ok
        end

        {:noreply, state}
    end
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
    _ = do_close_all(state, :pool_closed)
    :ok
  end

  # Private Helpers

  defp do_add_primary(state, conn_ref) do
    demoted_connections =
      Map.new(state.connections, fn {ref, info} ->
        {ref, %{info | is_primary: ref == conn_ref}}
      end)

    if Map.has_key?(demoted_connections, conn_ref) do
      %{
        state
        | connections: demoted_connections,
          conn_order: [conn_ref | List.delete(state.conn_order, conn_ref)]
      }
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
        | connections: Map.put(demoted_connections, conn_ref, conn_info),
          conn_order: [conn_ref | state.conn_order]
      }
    end
  end

  defp find_available_connection(state) do
    Enum.find(state.conn_order, fn conn_ref ->
      case Map.get(state.connections, conn_ref) do
        %{active_channels: count} -> count < state.max_channels_per_conn
        _ -> false
      end
    end)
  end

  defp fulfill_request(state, conn_ref, :checkout, caller_pid) do
    lease_ref = make_ref()
    state = register_lease(state, conn_ref, lease_ref, caller_pid)
    {{:ok, conn_ref, lease_ref}, state}
  end

  defp fulfill_request(state, conn_ref, :acquire, caller_pid) do
    case state.ssh_client.open_channel(conn_ref) do
      {:ok, channel_id} ->
        lease_ref = make_ref()
        state = register_lease(state, conn_ref, lease_ref, caller_pid)
        state = do_attach_channel(state, conn_ref, lease_ref, channel_id)
        {{:ok, conn_ref, channel_id}, state}

      {:error, reason} ->
        Logger.warning(
          "Failed to open channel on SSH connection #{inspect(conn_ref)}: #{inspect(reason)}"
        )

        conn_info = Map.get(state.connections, conn_ref)

        if conn_info && conn_info.monitor_ref,
          do: Process.demonitor(conn_info.monitor_ref, [:flush])

        try do
          state.ssh_client.close(conn_ref)
        catch
          _, _ -> :ok
        end

        state = handle_connection_down(state, conn_ref)
        {{:error, reason}, state}
    end
  end

  defp enqueue_connect(state, new_waiters) do
    case state.pending_connect do
      %{waiters: existing} = pending ->
        %{state | pending_connect: %{pending | waiters: existing ++ new_waiters}}

      nil ->
        Logger.info(
          "All connections in pool full for #{state.profile.id} (capacity: #{state.max_channels_per_conn} ch/conn). Opening new connection..."
        )

        pool_pid = self()
        task_ref = make_ref()
        ssh_client = state.ssh_client
        host_name = state.profile.host_name
        port = state.profile.port
        connect_opts = Caudata.Profile.to_connect_opts(state.profile)

        Task.start(fn ->
          res =
            try do
              ssh_client.connect(host_name, port, connect_opts)
            catch
              kind, reason -> {:error, {kind, reason}}
            end

          if Process.alive?(pool_pid) do
            send(pool_pid, {:pool_connect_result, task_ref, res})
          else
            case res do
              {:ok, conn_ref} ->
                try do
                  ssh_client.close(conn_ref)
                catch
                  _, _ -> :ok
                end

              _ ->
                :ok
            end
          end
        end)

        %{state | pending_connect: %{task_ref: task_ref, waiters: new_waiters}}
    end
  end

  defp register_connection(state, conn_ref) do
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

    new_state
  end

  defp serve_waiters(state, waiters) do
    case drain_available(state, waiters) do
      {[], state} -> state
      {remaining, state} -> enqueue_connect(state, remaining)
    end
  end

  defp drain_available(state, []), do: {[], state}

  defp drain_available(state, [{from, op, caller_pid} = waiter | rest]) do
    case find_available_connection(state) do
      nil ->
        {[waiter | rest], state}

      conn_ref ->
        {reply, state} = fulfill_request(state, conn_ref, op, caller_pid)
        GenServer.reply(from, reply)
        drain_available(state, rest)
    end
  end

  defp default_health_check_interval(Caudata.SSHClient.Native) do
    if Application.get_env(:caudata, :env) != :test do
      @default_health_check_interval
    else
      nil
    end
  end

  defp default_health_check_interval(_ssh_client), do: nil

  defp schedule_health_check(%{health_check_interval: interval, suspended: false} = state)
       when is_integer(interval) and interval > 0 do
    state = cancel_health_check(state)
    timer = Process.send_after(self(), :health_check, interval)
    %{state | health_check_timer: timer}
  end

  defp schedule_health_check(state), do: cancel_health_check(state)

  defp cancel_health_check(%{health_check_timer: nil} = state), do: state

  defp cancel_health_check(%{health_check_timer: timer} = state) do
    Process.cancel_timer(timer)

    receive do
      :health_check -> :ok
    after
      0 -> :ok
    end

    %{state | health_check_timer: nil}
  end

  defp do_close_all(state, reject_reason) do
    state = cancel_health_check(state)

    if state.pending_connect do
      Enum.each(state.pending_connect.waiters, fn {from, _op, _caller_pid} ->
        GenServer.reply(from, {:error, reject_reason})
      end)
    end

    Enum.each(state.caller_monitors, fn {mref, _} ->
      Process.demonitor(mref, [:flush])
    end)

    Enum.each(state.connections, fn {_conn_ref, info} ->
      if info.monitor_ref, do: Process.demonitor(info.monitor_ref, [:flush])
    end)

    Enum.each(state.active_leases, fn {_key, lease} ->
      if lease.channel_id do
        try do
          state.ssh_client.close_channel(lease.conn_ref, lease.channel_id)
        catch
          _, _ -> :ok
        end
      end
    end)

    Enum.each(state.connections, fn {conn_ref, _info} ->
      try do
        state.ssh_client.close(conn_ref)
      catch
        _, _ -> :ok
      end
    end)

    %{
      state
      | connections: %{},
        conn_order: [],
        active_leases: %{},
        caller_monitors: %{},
        pending_connect: nil
    }
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
