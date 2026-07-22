defmodule Caudata.ServerWorker do
  use GenServer, restart: :temporary
  require Logger

  @env Application.compile_env(:caudata, :env, :prod)

  @max_reconnect_delay 30_000
  @initial_reconnect_delay 1000
  @max_active_streams 5
  @health_check_interval 15_000
  @activity_timeout 30_000

  @docker_discovery_cmd "echo '===DOCKER==='; docker ps --no-trunc --format '{{json .}}' 2>/dev/null"
  @os_discovery_cmd "echo '===OS==='; uname -s"
  @systemd_discovery_cmd "echo '===SYSTEMD==='; if command -v systemctl >/dev/null 2>&1; then systemctl list-units --type=service --no-legend --no-pager 2>/dev/null; fi"
  @launchd_discovery_cmd "echo '===LAUNCHD==='; if command -v launchctl >/dev/null 2>&1; then launchctl list 2>/dev/null; for dir in '/System/Library/LaunchDaemons' '/Library/LaunchDaemons' '/Library/LaunchAgents' \"$HOME/Library/LaunchAgents\"; do if [ -d \"$dir\" ]; then find \"$dir\" -name '*.plist' -maxdepth 1 2>/dev/null | while read -r plist; do label=$(basename \"$plist\" .plist); echo \"- 0 $label\"; done; fi; done; fi"

  @discovery_cmd Enum.join(
                   [
                     @docker_discovery_cmd,
                     @os_discovery_cmd,
                     @systemd_discovery_cmd,
                     @launchd_discovery_cmd
                   ],
                   "; "
                 )

  defstruct [
    :profile,
    :status,
    :conn_ref,
    :reconnect_delay,
    :reconnect_timer,
    :ssh_client,
    :containers,
    :container_pids,
    :list_channel_id,
    :list_buffer,
    :active_container_id,
    :active_container_name,
    :conn_task_pid,
    :events_channel_id,
    :enable_events,
    :metrics_channel_id,
    :enable_metrics,
    :metrics,
    :ts_proxy_pid,
    container_order: [],
    metrics_buffer: "",
    events_buffer: "",
    validation_channels: %{},
    health_check_timer: nil,
    last_activity_at: nil,
    container_stats_channel_id: nil,
    container_stats_timer: nil,
    container_stats_buffer: "",
    log_stream_timer: nil,
    log_debounce_delay: 100,
    stats_debounce_delay: 300
  ]

  # Client API

  def start_link({profile, opts}) do
    GenServer.start_link(__MODULE__, {profile, opts},
      name: {:via, Registry, {Caudata.ServerRegistry, profile.id}}
    )
  end

  @doc """
  Gets the status of the server worker.
  """
  def get_status(pid) do
    try do
      GenServer.call(pid, :get_status, 100)
    catch
      :exit, _ -> :disconnected
    end
  end

  @doc """
  Gets the list of discovered containers.
  """
  def get_containers(pid) do
    try do
      GenServer.call(pid, :get_containers, 100)
    catch
      :exit, _ -> []
    end
  end

  @doc """
  Gets the current metrics of the server.
  """
  def get_metrics(pid) do
    try do
      GenServer.call(pid, :get_metrics, 100)
    catch
      :exit, _ -> nil
    end
  end

  # GenServer Callbacks

  @impl true
  def init({profile, opts}) do
    # Trap exit to ensure terminate/2 is called on supervisor shutdown
    Process.flag(:trap_exit, true)

    ssh_client =
      cond do
        Map.get(profile, :is_local, false) ->
          Caudata.LocalClient

        true ->
          Keyword.get(opts, :ssh_client) ||
            Application.get_env(:caudata, :ssh_client, Caudata.SSHClient.Native)
      end

    log_delay =
      Keyword.get(opts, :log_debounce_delay) ||
        Application.get_env(:caudata, :log_debounce_delay, 100)

    stats_delay =
      Keyword.get(opts, :stats_debounce_delay) ||
        Application.get_env(:caudata, :stats_debounce_delay, 300)

    state = %__MODULE__{
      profile: profile,
      status: :connecting,
      conn_ref: nil,
      reconnect_delay: @initial_reconnect_delay,
      reconnect_timer: nil,
      ssh_client: ssh_client,
      containers: [],
      container_pids: %{},
      list_channel_id: nil,
      list_buffer: "",
      active_container_id: nil,
      active_container_name: nil,
      conn_task_pid: nil,
      events_channel_id: nil,
      enable_events:
        Keyword.get(opts, :enable_events, Application.get_env(:caudata, :env) != :test),
      events_buffer: "",
      validation_channels: %{},
      metrics_channel_id: nil,
      metrics_buffer: "",
      enable_metrics:
        Keyword.get(opts, :enable_metrics, Application.get_env(:caudata, :env) != :test),
      metrics: nil,
      container_order: [],
      container_stats_channel_id: nil,
      container_stats_timer: nil,
      container_stats_buffer: "",
      log_stream_timer: nil,
      log_debounce_delay: log_delay,
      stats_debounce_delay: stats_delay,
      ts_proxy_pid: nil
    }

    # Broadcast initial connecting status
    broadcast_status(profile.id, :connecting)

    # Subscribe to tailscale events
    if @env != :test do
      Phoenix.PubSub.subscribe(Caudata.PubSub, "tailscale")
    end

    # Trigger async connect
    send(self(), :connect)

    {:ok, state}
  end

  @impl true
  def handle_call(:get_status, _from, state) do
    {:reply, state.status, state}
  end

  @impl true
  def handle_call(:get_containers, _from, state) do
    {:reply, state.containers, state}
  end

  @impl true
  def handle_call(:get_metrics, _from, state) do
    {:reply, state.metrics, state}
  end

  @impl true
  def handle_call({:validate_path, path}, from, state) do
    if is_nil(state.conn_ref) do
      {:reply, {:error, :not_connected}, state}
    else
      case state.ssh_client.open_channel(state.conn_ref) do
        {:ok, channel_id} ->
          escaped_path = String.replace(path, "\"", "\\\"")
          cmd = "if [ -r \"#{escaped_path}\" ]; then echo \"valid\"; else echo \"invalid\"; fi"
          wrapped_cmd = wrap_sudo(cmd, state.profile.password)

          case state.ssh_client.exec(state.conn_ref, channel_id, wrapped_cmd) do
            :ok ->
              new_validations = Map.put(state.validation_channels, channel_id, {from, ""})
              {:noreply, %{state | validation_channels: new_validations}}

            {:error, reason} ->
              {:reply, {:error, reason}, state}
          end

        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    end
  end

  @impl true
  def handle_call({:stream_container_logs, container_id}, _from, state) do
    container_id = to_string(container_id)

    active_container_name =
      case Enum.find(state.containers, &(to_string(&1.id) == container_id)) do
        nil -> nil
        c -> to_string(c.name)
      end

    new_state = %{
      state
      | active_container_id: container_id,
        active_container_name: active_container_name
    }

    new_state = cancel_log_stream_timer(new_state)
    new_state = update_container_stats_stream(new_state, new_state.stats_debounce_delay)

    if new_state.log_debounce_delay == 0 do
      new_state = do_start_log_streaming(new_state)
      {:reply, :ok, new_state}
    else
      timer = Process.send_after(self(), :start_log_streaming, new_state.log_debounce_delay)
      new_state = %{new_state | log_stream_timer: timer}
      {:reply, :ok, new_state}
    end
  end

  @impl true
  def handle_cast({:update_profile, updated_profile}, state) do
    old_profile = state.profile
    new_state = %{state | profile: updated_profile}

    # Only refresh containers when connection-relevant fields change.
    # Toggling disabled_containers is just a UI filter and should not
    # trigger a full SSH refresh that causes status flicker.
    needs_refresh =
      old_profile.custom_logs != updated_profile.custom_logs or
        old_profile.host_name != updated_profile.host_name or
        old_profile.port != updated_profile.port or
        old_profile.user != updated_profile.user or
        old_profile.identity_file != updated_profile.identity_file or
        Map.get(old_profile, :password) != Map.get(updated_profile, :password)

    if needs_refresh and state.conn_ref do
      GenServer.cast(self(), :refresh_containers)
    end

    {:noreply, new_state}
  end

  @impl true
  def handle_cast(:refresh_containers, state) do
    if state.conn_ref do
      state = close_list_channel(state)

      Logger.info("Refreshing containers list for #{state.profile.id}...")

      case state.ssh_client.open_channel(state.conn_ref) do
        {:ok, list_channel_id} ->
          wrapped_cmd = wrap_sudo(@discovery_cmd, state.profile.password)

          case state.ssh_client.exec(
                 state.conn_ref,
                 list_channel_id,
                 wrapped_cmd
               ) do
            :ok ->
              {:noreply,
               %{
                 state
                 | list_channel_id: list_channel_id,
                   list_buffer: ""
               }}

            {:error, reason} ->
              Logger.info("Failed to exec docker ps on refresh: #{inspect(reason)}")
              {:noreply, state}
          end

        {:error, reason} ->
          Logger.info("Failed to open channel on refresh: #{inspect(reason)}")
          {:noreply, state}
      end
    else
      send(self(), :connect)
      {:noreply, state}
    end
  end

  @impl true
  def handle_info(:connect, state) do
    # Cancel any active reconnect timer
    state = cancel_reconnect_timer(state)
    state = stop_existing_conn_task(state)

    Logger.info(
      "Connecting to server #{state.profile.id} (#{state.profile.host_name}:#{state.profile.port})"
    )

    # Connect to SSH host asynchronously
    parent = self()

    connect_opts = [
      user: state.profile.user,
      identity_file: state.profile.identity_file,
      password: Map.get(state.profile, :password)
    ]

    ssh_client = state.ssh_client
    host = state.profile.host_name
    port = state.profile.port

    {:ok, task_pid} =
      Task.start(fn ->
        {host_to_connect, port_to_connect, proxy_pid} =
          if Caudata.Tailscale.Service.tailscale_host?(host) &&
               Caudata.Tailscale.Service.active?() do
            case Caudata.Tailscale.Service.get_ssh_proxy(host, port) do
              {:ok, pid, {local_host, local_port}} ->
                {local_host, local_port, pid}

              _ ->
                {host, port, nil}
            end
          else
            {host, port, nil}
          end

        if proxy_pid, do: send(parent, {:ssh_proxy_started, proxy_pid})

        case ssh_client.connect(host_to_connect, port_to_connect, connect_opts) do
          {:ok, conn_ref} ->
            send(parent, {:ssh_connected, conn_ref, self()})

            # Keep the task process alive as long as the worker is alive
            ref = Process.monitor(parent)

            receive do
              :stop -> :ok
              {:DOWN, ^ref, :process, _, _} -> :ok
            end

            ssh_client.close(conn_ref)

          {:error, reason} ->
            send(parent, {:ssh_connect_failed, reason})
        end
      end)

    {:noreply, %{state | conn_task_pid: task_pid}}
  end

  @impl true
  def handle_info({:ssh_proxy_started, proxy_pid}, state) do
    {:noreply, %{state | ts_proxy_pid: proxy_pid}}
  end

  @impl true
  def handle_info(:tailscale_connected, state) do
    host = state.profile.host_name

    if Caudata.Tailscale.Service.tailscale_host?(host) and state.status == :connecting do
      Logger.info(
        "Tailscale service became active. Triggering immediate reconnect for #{state.profile.id}..."
      )

      state = cancel_reconnect_timer(state)
      send(self(), :connect)
      {:noreply, %{state | reconnect_delay: @initial_reconnect_delay}}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info({:ssh_connected, conn_ref, task_pid}, state) do
    Logger.info("SSH connection established to #{state.profile.id}, discovering containers...")

    # Stop any existing task just in case
    if state.conn_task_pid && state.conn_task_pid != task_pid do
      send(state.conn_task_pid, :stop)
    end

    case state.ssh_client.open_channel(conn_ref) do
      {:ok, list_channel_id} ->
        wrapped_cmd = wrap_sudo(@discovery_cmd, state.profile.password)

        case state.ssh_client.exec(
               conn_ref,
               list_channel_id,
               wrapped_cmd
             ) do
          :ok ->
            {:noreply,
             %{
               state
               | conn_ref: conn_ref,
                 list_channel_id: list_channel_id,
                 list_buffer: "",
                 conn_task_pid: task_pid,
                 reconnect_delay: @initial_reconnect_delay
             }}

          {:error, reason} ->
            Logger.info(
              "Docker ps execution failed or not available on #{state.profile.id}: #{inspect(reason)}. Falling back to server log command."
            )

            state.ssh_client.close_channel(conn_ref, list_channel_id)

            # Transition to connected, but with empty containers
            broadcast_status(state.profile.id, :connected)

            state = %{
              state
              | conn_ref: conn_ref,
                list_channel_id: nil,
                list_buffer: "",
                status: :connected,
                containers: [],
                conn_task_pid: task_pid,
                reconnect_delay: @initial_reconnect_delay
            }

            state = sync_container_workers(state, [])
            state = start_metrics_streaming(state)
            state = schedule_health_check(state)

            {:noreply, state}
        end

      {:error, reason} ->
        Logger.info(
          "Failed to open channel for container list on #{state.profile.id}: #{inspect(reason)}."
        )

        # Transition to connected, but with empty containers
        broadcast_status(state.profile.id, :connected)

        state = %{
          state
          | conn_ref: conn_ref,
            list_channel_id: nil,
            list_buffer: "",
            status: :connected,
            containers: [],
            conn_task_pid: task_pid,
            reconnect_delay: @initial_reconnect_delay
        }

        state = sync_container_workers(state, [])
        state = start_metrics_streaming(state)
        state = schedule_health_check(state)

        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:ssh_connect_failed, reason}, state) do
    Logger.info("Failed to establish SSH connection to #{state.profile.id}: #{inspect(reason)}")
    handle_disconnect(state, "Connection failed: #{inspect(reason)}")
  end

  # Handle SSH incoming messages
  @impl true
  def handle_info(
        {:ssh_cm, conn_ref, {:data, channel_id, _stream_id, chunk}},
        state
      ) do
    now = System.monotonic_time(:millisecond)

    cond do
      conn_ref == state.conn_ref && Map.has_key?(state.validation_channels, channel_id) ->
        {from, buffer} = Map.get(state.validation_channels, channel_id)
        new_buffer = buffer <> to_string(chunk)
        new_validations = Map.put(state.validation_channels, channel_id, {from, new_buffer})
        {:noreply, %{state | validation_channels: new_validations, last_activity_at: now}}

      conn_ref == state.conn_ref && channel_id == state.list_channel_id ->
        new_buffer = state.list_buffer <> to_string(chunk)
        {:noreply, %{state | list_buffer: new_buffer, last_activity_at: now}}

      conn_ref == state.conn_ref && channel_id == state.events_channel_id ->
        chunk_str = to_string(chunk)
        {lines, new_events_buffer} = process_chunk(chunk_str, state.events_buffer)
        state = Enum.reduce(lines, state, &handle_docker_event/2)
        {:noreply, %{state | events_buffer: new_events_buffer, last_activity_at: now}}

      conn_ref == state.conn_ref && channel_id == state.metrics_channel_id ->
        chunk_str = to_string(chunk)
        {lines, new_metrics_buffer} = process_chunk(chunk_str, state.metrics_buffer)
        state = Enum.reduce(lines, state, &handle_metrics_line/2)
        {:noreply, %{state | metrics_buffer: new_metrics_buffer, last_activity_at: now}}

      conn_ref == state.conn_ref && channel_id == state.container_stats_channel_id ->
        chunk_str = to_string(chunk)
        {lines, new_stats_buffer} = process_chunk(chunk_str, state.container_stats_buffer)
        state = Enum.reduce(lines, state, &handle_metrics_line/2)
        {:noreply, %{state | container_stats_buffer: new_stats_buffer, last_activity_at: now}}

      true ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_info(
        {:ssh_cm, conn_ref, {:eof, channel_id}},
        state
      ) do
    cond do
      conn_ref == state.conn_ref && channel_id == state.list_channel_id ->
        {:noreply, state}

      true ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_info(
        {:ssh_cm, conn_ref, {:exit_status, channel_id, _status}},
        state
      ) do
    cond do
      conn_ref == state.conn_ref && channel_id == state.list_channel_id ->
        {:noreply, state}

      true ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_info(
        {:ssh_cm, conn_ref, {:closed, channel_id}},
        state
      ) do
    cond do
      conn_ref == state.conn_ref && Map.has_key?(state.validation_channels, channel_id) ->
        {{from, buffer}, remaining_validations} = Map.pop(state.validation_channels, channel_id)

        result =
          if String.trim(buffer) == "valid" do
            :ok
          else
            {:error, :not_readable_or_not_found}
          end

        GenServer.reply(from, result)
        {:noreply, %{state | validation_channels: remaining_validations}}

      conn_ref == state.conn_ref && channel_id == state.list_channel_id ->
        containers = parse_discovery_output(state.list_buffer)

        Logger.info(
          "Discovered #{length(containers)} containers/services for #{state.profile.id}"
        )

        broadcast_status(state.profile.id, :connected)

        state = %{
          state
          | list_channel_id: nil,
            list_buffer: "",
            status: :connected
        }

        custom_containers =
          Enum.map(state.profile.custom_logs || [], fn path ->
            path_str = to_string(path)

            %{
              id: "file:#{path_str}",
              name: path_str,
              image: "file",
              status: "active",
              state: "running"
            }
          end)

        all_containers = containers ++ custom_containers

        state = sync_container_workers(state, all_containers)

        state =
          if state.active_container_id do
            if Enum.any?(all_containers, &(&1.id == state.active_container_id)) do
              case Map.fetch(state.container_pids, state.active_container_id) do
                {:ok, pid} ->
                  case Caudata.ContainerWorker.start_streaming(pid, state.conn_ref) do
                    :ok -> state
                    {:error, _reason} -> state
                  end

                :error ->
                  %{state | active_container_id: nil}
              end
            else
              %{state | active_container_id: nil}
            end
          else
            state
          end

        state = start_docker_events_listener(state)
        state = start_metrics_streaming(state)
        state = update_container_stats_stream(state)
        state = schedule_health_check(state)
        {:noreply, state}

      conn_ref == state.conn_ref && channel_id == state.container_stats_channel_id ->
        Logger.info("SSH Channel closed for container stats on #{state.profile.id}")
        {:noreply, %{state | container_stats_channel_id: nil}}

      conn_ref == state.conn_ref && channel_id == state.metrics_channel_id ->
        Logger.info("SSH Channel closed for metrics on #{state.profile.id}")
        {:noreply, %{state | metrics_channel_id: nil}}

      conn_ref == state.conn_ref && channel_id == state.events_channel_id ->
        Logger.info("SSH Channel closed for docker events on #{state.profile.id}")
        {:noreply, %{state | events_channel_id: nil}}

      conn_ref == state.conn_ref && channel_id == conn_ref ->
        Logger.info("SSH Connection closed for #{state.profile.id}")
        handle_disconnect(state, "Connection closed")

      true ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:ssh_cm, _, _}, state) do
    # Ignore other/spurious SSH connection manager messages
    {:noreply, state}
  end

  # Trigger connection attempt via reconnect timer
  @impl true
  def handle_info(:reconnect, state) do
    {:noreply, state, {:continue, :do_connect}}
  end

  @impl true
  def handle_info(:health_check, state) do
    if state.status == :connected && state.conn_ref do
      has_streaming = state.metrics_channel_id || state.events_channel_id

      if has_streaming do
        # Passive check: streaming channels exist, verify we're receiving data
        now = System.monotonic_time(:millisecond)
        last = state.last_activity_at || now

        if now - last > @activity_timeout do
          # No activity for timeout period, but perform an active check to verify
          # if the connection is actually dead before we initiate disconnect/reconnect.
          case state.ssh_client.open_channel(state.conn_ref) do
            {:ok, temp_channel} ->
              state.ssh_client.close_channel(state.conn_ref, temp_channel)
              schedule_health_check_reschedule(%{state | last_activity_at: now})

            {:error, reason} ->
              Logger.warning(
                "No SSH activity for #{@activity_timeout}ms on #{state.profile.id} and active check failed: #{inspect(reason)}, treating as disconnected"
              )

              handle_disconnect(state, "Health check: no activity for #{@activity_timeout}ms")
          end
        else
          schedule_health_check_reschedule(state)
        end
      else
        # Active check: no streaming channels, verify connection by opening a temp channel
        case state.ssh_client.open_channel(state.conn_ref) do
          {:ok, temp_channel} ->
            state.ssh_client.close_channel(state.conn_ref, temp_channel)
            schedule_health_check_reschedule(state)

          {:error, reason} ->
            Logger.warning(
              "Health check failed for #{state.profile.id}: #{inspect(reason)}, treating as disconnected"
            )

            handle_disconnect(state, "Health check: channel open failed")
        end
      end
    else
      schedule_health_check_reschedule(state)
    end
  end

  @impl true
  def handle_info(:start_container_stats, state) do
    state = %{state | container_stats_timer: nil}
    new_state = start_container_stats_streaming!(state)
    {:noreply, new_state}
  end

  @impl true
  def handle_info(:start_log_streaming, state) do
    state = %{state | log_stream_timer: nil}
    new_state = do_start_log_streaming(state)
    {:noreply, new_state}
  end

  @impl true
  def handle_info(_other, state) do
    # Catch-all to ignore other spurious messages (e.g. {:EXIT, pid, :normal} from Tasks)
    {:noreply, state}
  end

  defp schedule_health_check_reschedule(state) do
    timer = Process.send_after(self(), :health_check, @health_check_interval)
    {:noreply, %{state | health_check_timer: timer}}
  end

  @impl true
  def handle_continue(:do_connect, state) do
    send(self(), :connect)
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    # Unregister immediately from Registry to prevent UI / callers from making blocking calls
    _ = Registry.unregister(Caudata.ServerRegistry, state.profile.id)

    # Cancel reconnect timer
    state = cancel_reconnect_timer(state)

    # Cancel health check timer
    state = cancel_health_check(state)

    # 1. Stop all container workers in parallel while SSH connection is still active
    # This allows container workers to close their channels cleanly.
    # We use Process.exit/2 with :shutdown to avoid circular GenServer deadlock on the supervisor.
    start_time = System.monotonic_time(:millisecond)

    state.container_pids
    |> Enum.map(fn {_id, pid} ->
      Task.async(fn ->
        if Process.alive?(pid) do
          ref = Process.monitor(pid)
          Process.exit(pid, :shutdown)

          receive do
            {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
          after
            1000 -> :ok
          end
        end
      end)
    end)
    |> Task.await_many(:infinity)

    duration = System.monotonic_time(:millisecond) - start_time
    Logger.info("Stopped all container workers for #{state.profile.id} in #{duration}ms")

    # 2. Close parent worker's SSH channels cleanly
    state = close_list_channel(state)
    state = close_metrics_channel(state)
    state = close_container_stats_channel(state)
    state = cancel_container_stats_timer(state)
    state = cancel_log_stream_timer(state)

    # 3. Stop SSH connection task and await its termination (closes the actual SSH connection)
    if state.conn_task_pid do
      ref = Process.monitor(state.conn_task_pid)
      send(state.conn_task_pid, :stop)

      receive do
        {:DOWN, ^ref, :process, _, _} -> :ok
      after
        1000 -> :ok
      end
    end

    # Stop Tailscale SSH proxy if active
    state = maybe_stop_ts_proxy(state)

    broadcast_status(state.profile.id, :disconnected)
    :ok
  end

  # Helpers

  defp stop_existing_conn_task(state) do
    if state.conn_task_pid && Process.alive?(state.conn_task_pid) do
      ref = Process.monitor(state.conn_task_pid)
      send(state.conn_task_pid, :stop)

      receive do
        {:DOWN, ^ref, :process, _, _} ->
          :ok
      after
        100 ->
          Process.exit(state.conn_task_pid, :kill)

          receive do
            {:DOWN, ^ref, :process, _, _} -> :ok
          end
      end
    end

    %{state | conn_task_pid: nil}
  end

  defp maybe_stop_ts_proxy(state) do
    if state.ts_proxy_pid do
      Caudata.Tailscale.SSHProxy.stop_proxy(state.ts_proxy_pid)
    end

    %{state | ts_proxy_pid: nil}
  end

  @max_buffer_size 10_000

  defp process_chunk(chunk, buffer) do
    combined = buffer <> chunk

    case String.split(combined, ~r{\r?\n}) do
      [single_part] ->
        if byte_size(single_part) > @max_buffer_size do
          {chunk_part, rest_part} = String.split_at(single_part, @max_buffer_size)
          {[chunk_part], rest_part}
        else
          {[], single_part}
        end

      parts ->
        {lines, [last_part]} = Enum.split(parts, -1)

        if byte_size(last_part) > @max_buffer_size do
          {chunk_part, rest_part} = String.split_at(last_part, @max_buffer_size)
          {lines ++ [chunk_part], rest_part}
        else
          {lines, last_part}
        end
    end
  end

  defp handle_disconnect(state, reason) do
    # Reply to any pending validation channels
    Enum.each(state.validation_channels || %{}, fn {_ch, {from, _buf}} ->
      GenServer.reply(from, {:error, :disconnected})
    end)

    # Stop connection task
    state = stop_existing_conn_task(state)

    # Close old connections cleanly
    state = close_list_channel(state)
    state = close_events_channel(state)
    state = close_metrics_channel(state)
    state = close_container_stats_channel(state)
    state = cancel_container_stats_timer(state)
    state = cancel_log_stream_timer(state)

    # Cancel health check timer
    state = cancel_health_check(state)

    # Stop all container streams
    Enum.each(state.container_pids, fn {_id, pid} ->
      if Process.alive?(pid), do: Caudata.ContainerWorker.stop_streaming(pid)
    end)

    # Stop Tailscale SSH proxy if active
    state = maybe_stop_ts_proxy(state)

    broadcast_status(state.profile.id, :connecting)

    # Schedule reconnect with exponential backoff
    delay = state.reconnect_delay
    next_delay = min(delay * 2, @max_reconnect_delay)

    Logger.info("Reconnecting to #{state.profile.id} in #{delay}ms (reason: #{reason})")
    timer = Process.send_after(self(), :reconnect, delay)

    {:noreply,
     %{
       state
       | status: :connecting,
         conn_ref: nil,
         reconnect_delay: next_delay,
         reconnect_timer: timer,
         conn_task_pid: nil,
         validation_channels: %{},
         last_activity_at: nil
     }}
  end

  defp close_list_channel(state) do
    if state.list_channel_id && state.conn_ref do
      state.ssh_client.close_channel(state.conn_ref, state.list_channel_id)
    end

    %{state | list_channel_id: nil}
  end

  defp close_events_channel(state) do
    if state.events_channel_id && state.conn_ref do
      state.ssh_client.close_channel(state.conn_ref, state.events_channel_id)
    end

    %{state | events_channel_id: nil, events_buffer: ""}
  end

  defp start_docker_events_listener(state) do
    # Only start the listener if it isn't already running. Each container
    # rebuild triggers a full list refresh, which flows through the closed-list
    # channel handler and reaches here. Restarting the events stream on every
    # refresh would close the long-lived `docker events` channel and could drop
    # events that arrive during the restart window.
    if state.events_channel_id do
      state
    else
      start_docker_events_listener!(state)
    end
  end

  defp start_docker_events_listener!(state) do
    if state.enable_events && state.conn_ref do
      Logger.info("Starting docker events listener for #{state.profile.id}...")

      case state.ssh_client.open_channel(state.conn_ref) do
        {:ok, events_channel_id} ->
          event_cmd =
            "docker events --filter 'type=container' --filter 'event=start' --filter 'event=die' --filter 'event=destroy' --format '{{json .}}'"

          wrapped_cmd = wrap_sudo(event_cmd, state.profile.password)

          case state.ssh_client.exec(state.conn_ref, events_channel_id, wrapped_cmd) do
            :ok ->
              %{state | events_channel_id: events_channel_id, events_buffer: ""}

            {:error, reason} ->
              Logger.warning(
                "Failed to exec docker events command on #{state.profile.id}: #{inspect(reason)}"
              )

              state
          end

        {:error, reason} ->
          Logger.warning(
            "Failed to open channel for docker events on #{state.profile.id}: #{inspect(reason)}"
          )

          state
      end
    else
      state
    end
  end

  defp close_metrics_channel(state) do
    if state.metrics_channel_id && state.conn_ref do
      state.ssh_client.close_channel(state.conn_ref, state.metrics_channel_id)
    end

    %{state | metrics_channel_id: nil, metrics_buffer: "", metrics: nil}
  end

  defp start_metrics_streaming(state) do
    # Only start the metrics stream if it isn't already running, to avoid
    # restarting the (expensive) remote metrics loop on every list refresh.
    if state.metrics_channel_id do
      state
    else
      start_metrics_streaming!(state)
    end
  end

  defp start_metrics_streaming!(state) do
    if state.enable_metrics && state.conn_ref do
      Logger.info("Starting real-time metrics collector for #{state.profile.id}...")

      case state.ssh_client.open_channel(state.conn_ref) do
        {:ok, metrics_channel_id} ->
          # Run the metrics loop
          metrics_cmd = """
          prev_total=0
          prev_idle=0
          disk_info="0 0 0"
          disk_counter=0

          is_darwin=0
          if [ "$(uname -s 2>/dev/null)" = "Darwin" ]; then
            is_darwin=1
          fi

          while true; do

            if [ "$is_darwin" -eq 1 ]; then
              # macOS CPU
              cpu_pct=$(top -l 1 -n 0 2>/dev/null | awk '/CPU usage/ {printf "%.0f\\n", $3+$5}')
              cpu_pct=${cpu_pct:-0}

              # macOS RAM
              page_size=$(vm_stat 2>/dev/null | awk '/page size of/ {print $8}' | tr -d ' bytes)')
              page_size=${page_size:-16384}
              active=$(vm_stat 2>/dev/null | awk '/Pages active/ {print $3}' | tr -d '.')
              wired=$(vm_stat 2>/dev/null | awk '/Pages wired/ {print $4}' | tr -d '.')
              compressed=$(vm_stat 2>/dev/null | awk '/occupied by compressor/ {print $5}' | tr -d '.')
              active=${active:-0}
              wired=${wired:-0}
              compressed=${compressed:-0}

              ram_used=$(( (active + wired + compressed) * page_size / 1024 ))
              ram_total=$(( $(sysctl -n hw.memsize 2>/dev/null || echo 0) / 1024 ))
              if [ "$ram_total" -gt 0 ]; then
                ram_pct=$(( ram_used * 100 / ram_total ))
              else
                ram_pct=0
              fi
            else
              # Linux CPU
              if [ -f /proc/stat ]; then
                user=0; nice=0; system=0; idle=0; iowait=0; irq=0; softirq=0; steal=0
                read -r _ user nice system idle iowait irq softirq steal _ < /proc/stat
                total=$((${user:-0} + ${nice:-0} + ${system:-0} + ${idle:-0} + ${iowait:-0} + ${irq:-0} + ${softirq:-0} + ${steal:-0}))
                diff_idle=$((${idle:-0} - ${prev_idle:-0}))
                diff_total=$((${total:-0} - ${prev_total:-0}))
                if [ "${prev_total:-0}" -gt 0 ] && [ "${diff_total:-0}" -gt 0 ]; then
                  cpu_pct=$((100 - (diff_idle * 100) / diff_total))
                else
                  cpu_pct=0
                fi
                prev_total=$total
                prev_idle=$idle
              else
                cpu_pct=0
              fi

              # Linux RAM
              ram_total=0
              ram_used=0
              ram_pct=0
              if [ -f /proc/meminfo ]; then
                mem_total=$(grep MemTotal /proc/meminfo | awk '{print $2}')
                mem_avail=$(grep MemAvailable /proc/meminfo | awk '{print $2}')
                mem_total=${mem_total:-0}
                mem_avail=${mem_avail:-0}
                if [ "$mem_avail" -eq 0 ]; then
                  mem_free=$(grep MemFree /proc/meminfo | awk '{print $2}')
                  mem_cached=$(grep ^Cached /proc/meminfo | awk '{print $2}')
                  mem_buffers=$(grep Buffers /proc/meminfo | awk '{print $2}')
                  mem_free=${mem_free:-0}
                  mem_cached=${mem_cached:-0}
                  mem_buffers=${mem_buffers:-0}
                  mem_avail=$((${mem_free:-0} + ${mem_cached:-0} + ${mem_buffers:-0}))
                fi
                if [ "${mem_total:-0}" -gt 0 ]; then
                  ram_total=$mem_total
                  ram_used=$((mem_total - mem_avail))
                  ram_pct=$((ram_used * 100 / mem_total))
                fi
              elif command -v free >/dev/null 2>&1; then
                ram_info=$(free -k | awk '/Mem:/ {print $2" "$3}')
                ram_total=$(echo "$ram_info" | awk '{print $1}')
                ram_used=$(echo "$ram_info" | awk '{print $2}')
                ram_total=${ram_total:-0}
                ram_used=${ram_used:-0}
                if [ "${ram_total:-0}" -gt 0 ]; then
                  ram_pct=$((ram_used * 100 / ram_total))
                fi
              fi
            fi

            # Disk - check once every 60 seconds (when disk_counter == 0)
            if [ "$disk_counter" -eq 0 ]; then
              if [ "$is_darwin" -eq 1 ]; then
                target_dir="$HOME"
              else
                target_dir="/"
              fi
              curr_disk_info=$(df -k -P "$target_dir" | awk 'NR==2 {print $2" "$3" "$5}' | tr -d '%')
              if [ -n "$curr_disk_info" ]; then
                disk_info=$curr_disk_info
              fi
            fi
            disk_counter=$(( (disk_counter + 1) % 60 ))

            echo "METRICS: $cpu_pct $ram_pct $ram_total $ram_used $disk_info"

            sleep 1
          done
          """

          wrapped_metrics_cmd =
            "sh -c '#{String.replace(metrics_cmd, "'", "'\\''")} & pid=$!; trap \"kill $pid 2>/dev/null\" EXIT HUP INT TERM; read -r _; kill $pid 2>/dev/null'"

          case state.ssh_client.exec(state.conn_ref, metrics_channel_id, wrapped_metrics_cmd) do
            :ok ->
              %{state | metrics_channel_id: metrics_channel_id, metrics_buffer: ""}

            {:error, reason} ->
              Logger.warning(
                "Failed to exec metrics command on #{state.profile.id}: #{inspect(reason)}"
              )

              state
          end

        {:error, reason} ->
          Logger.warning(
            "Failed to open channel for metrics on #{state.profile.id}: #{inspect(reason)}"
          )

          state
      end
    else
      state
    end
  end

  defp handle_metrics_line(line, state) do
    clean_line =
      line
      |> String.replace(~r/\e\[[0-9;]*[a-zA-Z]/, "")
      |> String.replace("\r", "")
      |> String.trim()

    case String.split(clean_line, " ", trim: true) do
      ["METRICS:", cpu, ram, total_ram, used_ram, total_disk_kb, used_disk_kb, _disk_pct] ->
        try do
          cpu_val = String.to_integer(cpu)
          ram_val = String.to_integer(ram)

          total_ram_val = String.to_integer(total_ram)
          used_ram_val = String.to_integer(used_ram)

          total_disk_val = String.to_integer(total_disk_kb)
          used_disk_val = String.to_integer(used_disk_kb)

          disk_val =
            if total_disk_val > 0 do
              round(used_disk_val * 100 / total_disk_val)
            else
              0
            end

          # Convert KB to GB
          total_ram_gb = Float.round(total_ram_val / (1024 * 1024), 1)
          used_ram_gb = Float.round(used_ram_val / (1024 * 1024), 1)

          total_disk_gb = round(total_disk_val / (1024 * 1024))
          used_disk_gb = Float.round(used_disk_val / (1024 * 1024), 1)

          metrics =
            {cpu_val, ram_val, used_ram_gb, total_ram_gb, disk_val, used_disk_gb, total_disk_gb}

          # Update state
          new_state = %{state | metrics: metrics}

          # Broadcast metrics to UI
          broadcast_metrics(state.profile.id, metrics)

          new_state
        rescue
          _ -> state
        end

      ["CONTAINER_METRICS:", id, cpu_val | mem_parts] ->
        mem_str = Enum.join(mem_parts, " ")

        case String.split(mem_str, "/", parts: 2) do
          [used_val, limit_val] ->
            used_val = String.trim(used_val)
            limit_val = String.trim(limit_val)

            updated_containers =
              Enum.map(state.containers, fn container ->
                if String.starts_with?(container.id, id) or String.starts_with?(id, container.id) do
                  container
                  |> Map.put(:cpu_text, cpu_val)
                  |> Map.put(:ram_text, "#{used_val} / #{limit_val}")
                else
                  container
                end
              end)

            if updated_containers != state.containers do
              broadcast_containers(state.profile.id, updated_containers)
              %{state | containers: updated_containers}
            else
              state
            end

          _ ->
            state
        end

      _ ->
        state
    end
  end

  defp broadcast_metrics(source_id, metrics) do
    Phoenix.PubSub.broadcast(
      Caudata.PubSub,
      "servers",
      {:metrics_updated, source_id, metrics}
    )
  end

  defp handle_docker_event(line, state) do
    case Jason.decode(line) do
      {:ok, data} when is_map(data) ->
        status = Map.get(data, "Action") || Map.get(data, "status")

        actor = Map.get(data, "Actor") || %{}
        id = Map.get(actor, "ID") || Map.get(data, "id") || Map.get(data, "ID")

        attributes = Map.get(actor, "Attributes") || %{}
        name = Map.get(attributes, "name")
        image = Map.get(attributes, "image", "")

        if status && id && name do
          process_parsed_event(state, status, id, name, image)
        else
          state
        end

      _ ->
        state
    end
  end

  defp process_parsed_event(state, "start", id, name, _image) do
    # If the rebuilt container is the one currently being viewed, transition the
    # active container id so log streaming follows the new container. The full
    # list refresh triggered below will resume streaming for it once `docker ps`
    # confirms the new container exists.
    state =
      if state.active_container_name == name && state.active_container_id != id do
        old_active_id = state.active_container_id

        Logger.info("Docker container rebuilt: #{old_active_id} -> #{id} for name: #{name}")

        Phoenix.PubSub.broadcast(
          Caudata.PubSub,
          "servers",
          {:container_rebuilt, state.profile.id, name, old_active_id, id}
        )

        source_id = "#{state.profile.id}/#{id}"

        if Process.whereis(Caudata.LogStore) do
          Caudata.LogStore.clear_logs(source_id)
        end

        %{state | active_container_id: id}
      else
        state
      end

    # Always reload the authoritative container list (re-runs `docker ps` and
    # re-merges custom file logs) instead of incrementally patching it. A rebuild
    # changes the container id, and an incremental patch can leave the sidebar out
    # of sync (e.g. file log entries becoming unselectable afterwards). The full
    # refresh guarantees a consistent list.
    #
    # Overlapping refreshes are safe: each refresh closes the previous list
    # channel and opens a new one, and the channel-id guard in handle_info only
    # processes data for the latest channel.
    GenServer.cast(self(), :refresh_containers)
    state
  end

  defp process_parsed_event(state, "die", id, _name, _image) do
    case Map.fetch(state.container_pids, id) do
      {:ok, pid} ->
        if Process.alive?(pid) do
          _ = Caudata.ContainerWorker.stop_streaming(pid)
          :ok
        end

      :error ->
        :ok
    end

    updated_containers =
      Enum.map(state.containers, fn c ->
        if c.id == id do
          %{c | status: "Exited", state: "exited"}
        else
          c
        end
      end)

    sync_container_workers(state, updated_containers)
  end

  defp process_parsed_event(state, "destroy", id, _name, _image) do
    case Map.fetch(state.container_pids, id) do
      {:ok, pid} ->
        if Process.alive?(pid) do
          _ = Caudata.ContainerWorker.stop_streaming(pid)
          :ok
        end

      :error ->
        :ok
    end

    updated_containers = Enum.reject(state.containers, &(&1.id == id))
    sync_container_workers(state, updated_containers)
  end

  defp process_parsed_event(state, _status, _id, _name, _image) do
    state
  end

  defp parse_discovery_output(buffer) do
    lines = String.split(buffer, ["\r\n", "\n"])

    has_headers =
      Enum.any?(lines, fn line ->
        trimmed = String.trim(line)
        trimmed in ["===DOCKER===", "===OS===", "===SYSTEMD===", "===LAUNCHD==="]
      end)

    if has_headers do
      initial_state = %{
        section: nil,
        docker_lines: [],
        os: nil,
        systemd_lines: [],
        launchd_lines: []
      }

      parsed =
        Enum.reduce(lines, initial_state, fn line, acc ->
          trimmed = String.trim(line)

          case trimmed do
            "===DOCKER===" ->
              %{acc | section: :docker}

            "===OS===" ->
              %{acc | section: :os}

            "===SYSTEMD===" ->
              %{acc | section: :systemd}

            "===LAUNCHD===" ->
              %{acc | section: :launchd}

            "" ->
              acc

            other ->
              case acc.section do
                :docker -> %{acc | docker_lines: [other | acc.docker_lines]}
                :os -> %{acc | os: other}
                :systemd -> %{acc | systemd_lines: [other | acc.systemd_lines]}
                :launchd -> %{acc | launchd_lines: [other | acc.launchd_lines]}
                _ -> acc
              end
          end
        end)

      docker_containers =
        parsed.docker_lines
        |> Enum.reverse()
        |> Enum.flat_map(fn line ->
          case Jason.decode(line) do
            {:ok, %{"ID" => id, "Names" => names} = map} ->
              [
                %{
                  id: id,
                  name: names,
                  image: Map.get(map, "Image", ""),
                  status: Map.get(map, "Status", ""),
                  state: Map.get(map, "State", "")
                }
              ]

            _ ->
              []
          end
        end)

      systemd_services =
        parsed.systemd_lines
        |> Enum.reverse()
        |> Enum.flat_map(fn line ->
          parts = String.split(line, ~r/\s+/, trim: true)

          case parts do
            [service_name | _] ->
              if String.ends_with?(service_name, ".service") do
                [
                  %{
                    id: "systemd:#{service_name}",
                    name: service_name,
                    image: "systemd",
                    status: "active",
                    state: "running"
                  }
                ]
              else
                []
              end

            _ ->
              []
          end
        end)

      launchd_services =
        parsed.launchd_lines
        |> Enum.reverse()
        |> Enum.flat_map(fn line ->
          parts = String.split(line, ~r/\s+/, trim: true)

          case parts do
            [_pid, _status, label] ->
              if label != "Label" do
                [
                  %{
                    id: "launchd:#{label}",
                    name: label,
                    image: "launchd",
                    status: "active",
                    state: "running"
                  }
                ]
              else
                []
              end

            _ ->
              []
          end
        end)

      Enum.uniq_by(docker_containers ++ systemd_services ++ launchd_services, & &1.id)
    else
      Enum.flat_map(lines, fn line ->
        trimmed = String.trim(line)

        case Jason.decode(trimmed) do
          {:ok, %{"ID" => id, "Names" => names} = map} ->
            [
              %{
                id: id,
                name: names,
                image: Map.get(map, "Image", ""),
                status: Map.get(map, "Status", ""),
                state: Map.get(map, "State", "")
              }
            ]

          _ ->
            []
        end
      end)
    end
  end

  defp cancel_reconnect_timer(state) do
    if state.reconnect_timer do
      Process.cancel_timer(state.reconnect_timer)
    end

    %{state | reconnect_timer: nil}
  end

  defp schedule_health_check(state) do
    state = cancel_health_check(state)
    timer = Process.send_after(self(), :health_check, @health_check_interval)
    %{state | health_check_timer: timer}
  end

  defp cancel_health_check(state) do
    if state.health_check_timer do
      Process.cancel_timer(state.health_check_timer)
    end

    %{state | health_check_timer: nil}
  end

  defp broadcast_status(source_id, status) do
    Phoenix.PubSub.broadcast(
      Caudata.PubSub,
      "servers",
      {:status_updated, source_id, status}
    )
  end

  defp broadcast_containers(source_id, containers) do
    Phoenix.PubSub.broadcast(
      Caudata.PubSub,
      "servers",
      {:containers_updated, source_id, containers}
    )
  end

  defp maybe_put(map, source, key) do
    if Map.has_key?(source, key), do: Map.put(map, key, Map.get(source, key)), else: map
  end

  defp sync_container_workers(state, new_containers) do
    # 1. Sort by category (Docker -> System services -> File logs), then alphabetically by name
    sorted_containers =
      Enum.sort(new_containers, fn c1, c2 ->
        cat1 = container_category(c1)
        cat2 = container_category(c2)

        cond do
          cat1 != cat2 ->
            cat1 < cat2

          true ->
            to_string(c1.name) <= to_string(c2.name)
        end
      end)

    # 2. Preserve cpu_text and ram_text from old containers if they exist.
    old_containers_map = Map.new(state.containers, fn c -> {c.id, c} end)

    sorted_containers =
      Enum.map(sorted_containers, fn new_c ->
        case Map.get(old_containers_map, new_c.id) do
          nil ->
            new_c

          old_c ->
            new_c
            |> maybe_put(old_c, :cpu_text)
            |> maybe_put(old_c, :ram_text)
        end
      end)

    new_ids = MapSet.new(Enum.map(sorted_containers, & &1.id))

    # Stop and remove workers for containers that no longer exist
    {remaining_pids, _stopped_pids} =
      Enum.reduce(state.container_pids, {%{}, []}, fn {id, pid}, {keep, stop} ->
        if MapSet.member?(new_ids, id) do
          {Map.put(keep, id, pid), stop}
        else
          _ = Caudata.ServerSupervisor.stop_container_worker(pid)
          {keep, [pid | stop]}
        end
      end)

    # Start or update workers for new/existing containers
    updated_pids =
      Enum.reduce(sorted_containers, remaining_pids, fn container, acc ->
        case Map.fetch(acc, container.id) do
          {:ok, pid} ->
            if Process.alive?(pid) do
              Caudata.ContainerWorker.update_container_info(pid, container)
              acc
            else
              {:ok, new_pid} =
                Caudata.ServerSupervisor.start_container_worker(
                  state.profile.id,
                  container,
                  ssh_client: state.ssh_client,
                  password: Map.get(state.profile, :password)
                )

              Map.put(acc, container.id, new_pid)
            end

          :error ->
            {:ok, new_pid} =
              Caudata.ServerSupervisor.start_container_worker(
                state.profile.id,
                container,
                ssh_client: state.ssh_client,
                password: Map.get(state.profile, :password)
              )

            Map.put(acc, container.id, new_pid)
        end
      end)

    broadcast_containers(state.profile.id, sorted_containers)

    %{
      state
      | containers: sorted_containers,
        container_pids: updated_pids
    }
  end

  defp container_category(container) do
    id_str = to_string(container.id)
    image = container.image

    cond do
      image == "file" or String.starts_with?(id_str, "file:") ->
        3

      image in ["systemd", "launchd"] or String.starts_with?(id_str, "systemd:") or
          String.starts_with?(id_str, "launchd:") ->
        2

      true ->
        1
    end
  end

  defp cancel_log_stream_timer(state) do
    if state.log_stream_timer do
      Process.cancel_timer(state.log_stream_timer)
    end

    %{state | log_stream_timer: nil}
  end

  defp do_start_log_streaming(state) do
    if is_nil(state.conn_ref) or is_nil(state.active_container_id) do
      state
    else
      case Map.fetch(state.container_pids, state.active_container_id) do
        {:ok, pid} ->
          # Check and close oldest stream if we are about to open a new channel
          target_status = Caudata.ContainerWorker.get_streaming_status(pid)

          if not target_status.streaming? do
            active_streams =
              state.container_pids
              |> Enum.filter(fn {_id, c_pid} -> Process.alive?(c_pid) end)
              |> Enum.map(fn {id, c_pid} ->
                case Caudata.ContainerWorker.get_streaming_status(c_pid) do
                  %{streaming?: true, opened_at: opened_at} ->
                    {id, c_pid, opened_at}

                  _ ->
                    nil
                end
              end)
              |> Enum.reject(&is_nil/1)

            if length(active_streams) >= @max_active_streams do
              case Enum.min_by(active_streams, fn {_id, _c_pid, opened_at} -> opened_at end, fn ->
                     nil
                   end) do
                nil ->
                  :ok

                {old_id, old_pid, _opened_at} ->
                  Logger.info(
                    "Max active channels (#{@max_active_streams}) reached. Closing oldest channel for container #{old_id} to make room."
                  )

                  Caudata.ContainerWorker.stop_streaming(old_pid)
              end
            end
          end

          try do
            Caudata.ContainerWorker.start_streaming(pid, state.conn_ref)
            state
          catch
            :exit, reason ->
              Logger.warning(
                "Timed out starting log stream for container #{state.active_container_id}: #{inspect(reason)}"
              )

              state
          end

        :error ->
          state
      end
    end
  end

  defp close_container_stats_channel(state) do
    if state.container_stats_channel_id && state.conn_ref do
      state.ssh_client.close_channel(state.conn_ref, state.container_stats_channel_id)
    end

    %{state | container_stats_channel_id: nil, container_stats_buffer: ""}
  end

  defp cancel_container_stats_timer(state) do
    if state.container_stats_timer do
      Process.cancel_timer(state.container_stats_timer)
    end

    %{state | container_stats_timer: nil}
  end

  defp update_container_stats_stream(state) do
    update_container_stats_stream(state, state.stats_debounce_delay)
  end

  defp update_container_stats_stream(state, delay) do
    state = cancel_container_stats_timer(state)

    if delay == 0 do
      start_container_stats_streaming!(state)
    else
      timer = Process.send_after(self(), :start_container_stats, delay)
      %{state | container_stats_timer: timer}
    end
  end

  defp docker_container?(nil), do: false

  defp docker_container?(id) do
    not String.starts_with?(id, "systemd:") and
      not String.starts_with?(id, "launchd:") and
      not String.starts_with?(id, "file:")
  end

  defp start_container_stats_streaming!(state) do
    state = close_container_stats_channel(state)

    if state.enable_metrics && state.conn_ref && docker_container?(state.active_container_id) do
      Logger.info("Starting container stats collector for #{state.active_container_id}...")

      case state.ssh_client.open_channel(state.conn_ref) do
        {:ok, stats_channel_id} ->
          escaped_id = String.replace(state.active_container_id, "'", "'\\''")

          cmd =
            "docker stats --format \"CONTAINER_METRICS: {{.ID}} {{.CPUPerc}} {{.MemUsage}}\" '#{escaped_id}'"

          wrapped_cmd = wrap_sudo(cmd, state.profile.password)

          case state.ssh_client.exec(state.conn_ref, stats_channel_id, wrapped_cmd) do
            :ok ->
              %{state | container_stats_channel_id: stats_channel_id, container_stats_buffer: ""}

            {:error, reason} ->
              Logger.warning("Failed to exec container stats command: #{inspect(reason)}")
              state
          end

        {:error, reason} ->
          Logger.warning("Failed to open channel for container stats: #{inspect(reason)}")
          state
      end
    else
      state
    end
  end

  defp wrap_sudo(cmd, password) do
    escaped_cmd = String.replace(cmd, "'", "'\\''")

    inner_script =
      cond do
        password && password != "" ->
          escaped_password = String.replace(password, "'", "'\\''")

          "if command -v sudo >/dev/null 2>&1; then if true <&0 2>/dev/null; then exec 3<&0; fi; echo '#{escaped_password}' | sudo -S -p '' sh -c 'if true <&3 2>/dev/null; then exec 0<&3 3<&-; fi; #{escaped_cmd}' 2>/dev/null || sh -c '#{escaped_cmd}'; else sh -c '#{escaped_cmd}'; fi"

        true ->
          "if command -v sudo >/dev/null 2>&1; then sudo -n sh -c '#{escaped_cmd}' 2>/dev/null || sh -c '#{escaped_cmd}'; else sh -c '#{escaped_cmd}'; fi"
      end

    # Wrap the entire script in sh -c "..." to ensure compatibility with
    # any login shell (fish, zsh, bash, etc.) - the login shell only sees
    # a simple `sh -c "..."` command, not the POSIX syntax inside.
    escaped_for_dq =
      inner_script
      |> String.replace("\\", "\\\\")
      |> String.replace("\"", "\\\"")
      |> String.replace("$", "\\$")
      |> String.replace("`", "\\`")

    "sh -c \"#{escaped_for_dq}\""
  end
end
