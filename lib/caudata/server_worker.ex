defmodule Caudata.ServerWorker do
  use GenServer, restart: :transient
  require Logger
  alias Caudata.LogStore

  @max_reconnect_delay 30_000
  @initial_reconnect_delay 1000
  @max_active_streams 8

  defstruct [
    :profile,
    :status,
    :conn_ref,
    :channel_id,
    :buffer,
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
    :tail_limit,
    :events_channel_id,
    :enable_events,
    :metrics_channel_id,
    :enable_metrics,
    :metrics,
    metrics_buffer: "",
    events_buffer: "",
    validation_channels: %{}
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
      Keyword.get(opts, :ssh_client) ||
        Application.get_env(:caudata, :ssh_client, Caudata.SSHClient.Native)

    state = %__MODULE__{
      profile: profile,
      status: :connecting,
      conn_ref: nil,
      channel_id: nil,
      buffer: "",
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
      tail_limit: 1000,
      events_channel_id: nil,
      enable_events:
        Keyword.get(opts, :enable_events, Application.get_env(:caudata, :env) != :test),
      events_buffer: "",
      validation_channels: %{},
      metrics_channel_id: nil,
      metrics_buffer: "",
      enable_metrics:
        Keyword.get(opts, :enable_metrics, Application.get_env(:caudata, :env) != :test),
      metrics: nil
    }

    # Broadcast initial connecting status
    broadcast_status(profile.id, :connecting)

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

          case state.ssh_client.exec(state.conn_ref, channel_id, cmd) do
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

    if is_nil(state.conn_ref) do
      {:reply, {:error, :not_connected},
       %{state | active_container_id: container_id, active_container_name: active_container_name}}
    else
      case Map.fetch(state.container_pids, container_id) do
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
              sorted_streams =
                Enum.sort_by(active_streams, fn {_id, _c_pid, opened_at} -> opened_at end)

              case sorted_streams do
                [{old_id, old_pid, _opened_at} | _] ->
                  Logger.info(
                    "Max active channels (#{@max_active_streams}) reached. Closing oldest channel for container #{old_id} to make room."
                  )

                  Caudata.ContainerWorker.stop_streaming(old_pid)

                [] ->
                  :ok
              end
            end
          end

          case Caudata.ContainerWorker.start_streaming(pid, state.conn_ref) do
            :ok ->
              {:reply, :ok,
               %{
                 state
                 | active_container_id: container_id,
                   active_container_name: active_container_name
               }}

            {:error, reason} ->
              {:reply, {:error, reason},
               %{
                 state
                 | active_container_id: container_id,
                   active_container_name: active_container_name
               }}
          end

        :error ->
          {:reply, {:error, :container_not_found}, %{state | active_container_id: container_id}}
      end
    end
  end

  @impl true
  def handle_call(:stream_server_logs, _from, state) do
    if is_nil(state.conn_ref) do
      {:reply, {:error, :not_connected}, %{state | active_container_id: nil}}
    else
      if state.channel_id do
        {:reply, :ok, %{state | active_container_id: nil}}
      else
        case start_server_log_streaming(state) do
          {:ok, new_state} ->
            {:reply, :ok, new_state}

          {:error, reason, new_state} ->
            {:reply, {:error, reason}, new_state}
        end
      end
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
        old_profile.log_command != updated_profile.log_command or
        old_profile.identity_file != updated_profile.identity_file or
        Map.get(old_profile, :password) != Map.get(updated_profile, :password)

    if needs_refresh and state.conn_ref do
      GenServer.cast(self(), :refresh_containers)
    end

    {:noreply, new_state}
  end

  @impl true
  def handle_cast({:restart_with_tail_limit, new_limit}, state) do
    Caudata.LogStore.clear_logs(state.profile.id)

    state = close_ssh_log_channel(state)

    case start_server_log_streaming(%{state | tail_limit: new_limit}) do
      {:ok, new_state} ->
        {:noreply, new_state}

      {:error, _reason, new_state} ->
        {:noreply, new_state}
    end
  end

  @impl true
  def handle_cast(:refresh_containers, state) do
    if state.conn_ref do
      state = close_list_channel(state)

      Logger.info("Refreshing containers list for #{state.profile.id}...")

      case state.ssh_client.open_channel(state.conn_ref) do
        {:ok, list_channel_id} ->
          case state.ssh_client.exec(
                 state.conn_ref,
                 list_channel_id,
                 "docker ps --format '{{json .}}'"
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

    Task.start(fn ->
      case ssh_client.connect(host, port, connect_opts) do
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

    {:noreply, state}
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
        case state.ssh_client.exec(conn_ref, list_channel_id, "docker ps --format '{{json .}}'") do
          :ok ->
            {:noreply,
             %{
               state
               | conn_ref: conn_ref,
                 list_channel_id: list_channel_id,
                 list_buffer: "",
                 conn_task_pid: task_pid
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
                conn_task_pid: task_pid
            }

            state = sync_container_workers(state, [])

            # Start streaming server logs immediately if no active container
            state =
              case start_server_log_streaming(state) do
                {:ok, new_state} -> new_state
                {:error, _reason, new_state} -> new_state
              end

            state = start_metrics_streaming(state)

            {:noreply, state}
        end

      {:error, reason} ->
        Logger.info(
          "Failed to open channel for container list on #{state.profile.id}: #{inspect(reason)}. Falling back to server log command."
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
            conn_task_pid: task_pid
        }

        state = sync_container_workers(state, [])

        # Start streaming server logs immediately if no active container
        state =
          case start_server_log_streaming(state) do
            {:ok, new_state} -> new_state
            {:error, _reason, new_state} -> new_state
          end

        state = start_metrics_streaming(state)

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
    cond do
      conn_ref == state.conn_ref && Map.has_key?(state.validation_channels, channel_id) ->
        {from, buffer} = Map.get(state.validation_channels, channel_id)
        new_buffer = buffer <> to_string(chunk)
        new_validations = Map.put(state.validation_channels, channel_id, {from, new_buffer})
        {:noreply, %{state | validation_channels: new_validations}}

      conn_ref == state.conn_ref && channel_id == state.list_channel_id ->
        new_buffer = state.list_buffer <> to_string(chunk)
        {:noreply, %{state | list_buffer: new_buffer}}

      conn_ref == state.conn_ref && channel_id == state.channel_id ->
        chunk_str = to_string(chunk)
        {lines, new_buffer} = process_chunk(chunk_str, state.buffer)

        if length(lines) > 0 do
          source_id = state.profile.id
          # Batch insert to LogStore
          LogStore.append_logs(source_id, lines)
        end

        {:noreply, %{state | buffer: new_buffer}}

      conn_ref == state.conn_ref && channel_id == state.events_channel_id ->
        chunk_str = to_string(chunk)
        {lines, new_events_buffer} = process_chunk(chunk_str, state.events_buffer)
        state = Enum.reduce(lines, state, &handle_docker_event/2)
        {:noreply, %{state | events_buffer: new_events_buffer}}

      conn_ref == state.conn_ref && channel_id == state.metrics_channel_id ->
        chunk_str = to_string(chunk)
        {lines, new_metrics_buffer} = process_chunk(chunk_str, state.metrics_buffer)
        state = Enum.reduce(lines, state, &handle_metrics_line/2)
        {:noreply, %{state | metrics_buffer: new_metrics_buffer}}

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

      conn_ref == state.conn_ref && channel_id == state.channel_id ->
        Logger.info("Received EOF from server log stream")
        handle_disconnect(state, "EOF received")

      true ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_info(
        {:ssh_cm, conn_ref, {:exit_status, channel_id, status}},
        state
      ) do
    cond do
      conn_ref == state.conn_ref && channel_id == state.list_channel_id ->
        {:noreply, state}

      conn_ref == state.conn_ref && channel_id == state.channel_id ->
        Logger.info("Remote server log command exited with status #{status}")

        handle_disconnect(state, "Command exited with status #{status}")

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
        containers = parse_docker_ps_output(state.list_buffer)
        Logger.info("Discovered #{length(containers)} docker containers for #{state.profile.id}")

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
                  case start_server_log_streaming(%{state | active_container_id: nil}) do
                    {:ok, new_state} -> new_state
                    {:error, _reason, new_state} -> new_state
                  end
              end
            else
              # Active container not found anymore, fallback to server logs
              case start_server_log_streaming(%{state | active_container_id: nil}) do
                {:ok, new_state} -> new_state
                {:error, _reason, new_state} -> new_state
              end
            end
          else
            case start_server_log_streaming(state) do
              {:ok, new_state} -> new_state
              {:error, _reason, new_state} -> new_state
            end
          end

        state = start_docker_events_listener(state)
        state = start_metrics_streaming(state)
        {:noreply, state}

      conn_ref == state.conn_ref && channel_id == state.channel_id ->
        Logger.info("SSH Channel closed for server logs")
        handle_disconnect(state, "Channel closed")

      conn_ref == state.conn_ref && channel_id == state.metrics_channel_id ->
        Logger.info("SSH Channel closed for metrics on #{state.profile.id}")
        {:noreply, %{state | metrics_channel_id: nil}}

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
  def handle_info(_other, state) do
    # Catch-all to ignore other spurious messages (e.g. {:EXIT, pid, :normal} from Tasks)
    {:noreply, state}
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

    # 1. Stop all container workers in parallel while SSH connection is still active
    # This allows container workers to close their channels cleanly.
    start_time = System.monotonic_time(:millisecond)

    state.container_pids
    |> Enum.map(fn {_id, pid} ->
      Task.async(fn ->
        if Process.alive?(pid) do
          _ = Caudata.ServerSupervisor.stop_container_worker(pid)
        end
      end)
    end)
    |> Task.await_many(:infinity)

    duration = System.monotonic_time(:millisecond) - start_time
    Logger.info("Stopped all container workers for #{state.profile.id} in #{duration}ms")

    # Ensure any remaining buffer is flushed as a log line
    if state.buffer != "" do
      LogStore.append_logs(state.profile.id, [state.buffer])
    end

    # 2. Close parent worker's SSH channels cleanly
    state = close_ssh_log_channel(state)
    state = close_list_channel(state)
    state = close_metrics_channel(state)

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

    broadcast_status(state.profile.id, :disconnected)
    :ok
  end

  # Helpers

  defp process_chunk(chunk, buffer) do
    combined = buffer <> chunk

    case String.split(combined, ~r{\r?\n}) do
      [single_part] ->
        {[], single_part}

      parts ->
        {lines, [last_part]} = Enum.split(parts, -1)
        {lines, last_part}
    end
  end

  defp handle_disconnect(state, reason) do
    # Reply to any pending validation channels
    Enum.each(state.validation_channels || %{}, fn {_ch, {from, _buf}} ->
      GenServer.reply(from, {:error, :disconnected})
    end)

    # If there is remaining text in the buffer, flush it
    if state.buffer != "" do
      LogStore.append_logs(state.profile.id, [state.buffer])
    end

    # Stop connection task
    if state.conn_task_pid do
      send(state.conn_task_pid, :stop)
    end

    # Close old connections cleanly
    state = close_ssh_log_channel(state)
    state = close_list_channel(state)
    state = close_events_channel(state)
    state = close_metrics_channel(state)

    # Stop all container streams
    Enum.each(state.container_pids, fn {_id, pid} ->
      if Process.alive?(pid), do: Caudata.ContainerWorker.stop_streaming(pid)
    end)

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
         validation_channels: %{}
     }}
  end

  defp start_server_log_streaming(state) do
    base_cmd = state.profile.log_command || "tail -F /var/log/messages"
    log_cmd = build_log_command(base_cmd, state.tail_limit)
    escaped_log_cmd = String.replace(log_cmd, "'", "'\\''")

    wrapped_log_cmd =
      "sh -c '#{escaped_log_cmd} 2>&1 & pid=$!; trap \"kill $pid 2>/dev/null\" EXIT HUP INT TERM; read -r _; kill $pid 2>/dev/null'"

    Logger.info("Streaming server logs via: #{wrapped_log_cmd} on #{state.profile.id}...")

    case state.ssh_client.open_channel(state.conn_ref) do
      {:ok, channel_id} ->
        case state.ssh_client.exec(state.conn_ref, channel_id, wrapped_log_cmd) do
          :ok ->
            {:ok,
             %{
               state
               | channel_id: channel_id,
                 active_container_id: nil,
                 buffer: ""
             }}

          {:error, reason} ->
            Logger.info("Failed to execute server log command: #{inspect(reason)}")
            {:error, reason, %{state | active_container_id: nil}}
        end

      {:error, reason} ->
        Logger.info("Failed to open channel for server logs: #{inspect(reason)}")
        {:error, reason, %{state | active_container_id: nil}}
    end
  end

  defp build_log_command(base_cmd, nil), do: base_cmd

  defp build_log_command(base_cmd, limit) do
    cond do
      String.contains?(base_cmd, "tail -F") ->
        String.replace(base_cmd, "tail -F", "tail -n #{limit} -F")

      String.contains?(base_cmd, "tail") and not String.contains?(base_cmd, "-n") ->
        String.replace(base_cmd, "tail", "tail -n #{limit}")

      String.contains?(base_cmd, "journalctl -f") ->
        String.replace(base_cmd, "journalctl -f", "journalctl -n #{limit} -f")

      String.contains?(base_cmd, "journalctl") and not String.contains?(base_cmd, "-n") ->
        String.replace(base_cmd, "journalctl", "journalctl -n #{limit}")

      true ->
        base_cmd
    end
  end

  defp close_ssh_log_channel(state) do
    if state.channel_id && state.conn_ref do
      state.ssh_client.close_channel(state.conn_ref, state.channel_id)
    end

    %{state | channel_id: nil}
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
    state = close_events_channel(state)

    if state.enable_events && state.conn_ref do
      Logger.info("Starting docker events listener for #{state.profile.id}...")

      case state.ssh_client.open_channel(state.conn_ref) do
        {:ok, events_channel_id} ->
          event_cmd =
            "docker events --filter 'type=container' --filter 'event=start' --filter 'event=die' --filter 'event=destroy' --format '{{json .}}'"

          case state.ssh_client.exec(state.conn_ref, events_channel_id, event_cmd) do
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
    state = close_metrics_channel(state)

    if state.enable_metrics && state.conn_ref do
      Logger.info("Starting real-time metrics collector for #{state.profile.id}...")

      case state.ssh_client.open_channel(state.conn_ref) do
        {:ok, metrics_channel_id} ->
          # Run the metrics loop
          metrics_cmd = """
          prev_total=0
          prev_idle=0
          while true; do
            # CPU
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

            # RAM
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

            # Disk
            disk_info=$(df -k -P / | awk 'NR==2 {print $2" "$3" "$5}' | tr -d '%')
            if [ -z "$disk_info" ]; then
              disk_info="0 0 0"
            fi

            echo "METRICS: $cpu_pct $ram_pct $ram_total $ram_used $disk_info"

            # Container stats
            if command -v docker >/dev/null 2>&1; then
              docker stats --no-stream --format 'CONTAINER_METRICS: {{.ID}} {{.CPUPerc}} {{.MemUsage}}' 2>/dev/null
            fi

            sleep 5
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
    case String.split(line, " ", trim: true) do
      ["METRICS:", cpu, ram, total_ram, used_ram, total_disk_kb, used_disk_kb, disk_pct] ->
        try do
          cpu_val = String.to_integer(cpu)
          ram_val = String.to_integer(ram)
          disk_val = String.to_integer(disk_pct)

          total_ram_val = String.to_integer(total_ram)
          used_ram_val = String.to_integer(used_ram)

          total_disk_val = String.to_integer(total_disk_kb)
          used_disk_val = String.to_integer(used_disk_kb)

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

      ["CONTAINER_METRICS:", id, cpu_val, used_val, "/", limit_val] ->
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
      {:ok, %{"status" => status, "id" => id, "Actor" => %{"Attributes" => attributes}}} ->
        name = Map.get(attributes, "name")
        image = Map.get(attributes, "image", "")
        process_parsed_event(state, status, id, name, image)

      _ ->
        state
    end
  end

  defp process_parsed_event(state, "start", id, name, image) do
    # Check if this new container has the same name as the active container (rebuilt)
    rebuilt? = state.active_container_name == name && state.active_container_id != id
    old_active_id = state.active_container_id

    new_container = %{
      id: id,
      name: name,
      image: image,
      status: "Up",
      state: "running"
    }

    # Reject old containers with the same name or ID, then add the new one
    updated_containers =
      state.containers
      |> Enum.reject(fn c -> c.name == name || c.id == id end)
      |> Kernel.++([new_container])

    # If it is rebuilt, transition active_container_id and broadcast rebuilt event
    state =
      if rebuilt? do
        Logger.info("Docker container rebuilt: #{old_active_id} -> #{id} for name: #{name}")

        Phoenix.PubSub.broadcast(
          Caudata.PubSub,
          "servers",
          {:container_rebuilt, state.profile.id, old_active_id, id}
        )

        %{state | active_container_id: id}
      else
        state
      end

    # Sync container workers
    state = sync_container_workers(state, updated_containers)

    # Resume log streaming if this container is now active
    if state.active_container_id == id do
      case Map.fetch(state.container_pids, id) do
        {:ok, pid} ->
          source_id = "#{state.profile.id}/#{id}"
          Caudata.LogStore.clear_logs(source_id)

          _ = Caudata.ContainerWorker.start_streaming(pid, state.conn_ref)
          :ok

        :error ->
          :ok
      end
    end

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

  defp parse_docker_ps_output(output) do
    output
    |> String.split(["\r\n", "\n"])
    |> Enum.map(&String.trim/1)
    |> Enum.filter(&(&1 != ""))
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
  end

  defp cancel_reconnect_timer(state) do
    if state.reconnect_timer do
      Process.cancel_timer(state.reconnect_timer)
    end

    %{state | reconnect_timer: nil}
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

  defp sync_container_workers(state, new_containers) do
    # Preserve cpu_text and ram_text from old containers if they exist
    new_containers =
      Enum.map(new_containers, fn new_c ->
        case Enum.find(state.containers, &(&1.id == new_c.id)) do
          nil ->
            new_c

          old_c ->
            new_c
            |> Map.put(:cpu_text, Map.get(old_c, :cpu_text))
            |> Map.put(:ram_text, Map.get(old_c, :ram_text))
        end
      end)

    new_ids = MapSet.new(Enum.map(new_containers, & &1.id))

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
      Enum.reduce(new_containers, remaining_pids, fn container, acc ->
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
                  ssh_client: state.ssh_client
                )

              Map.put(acc, container.id, new_pid)
            end

          :error ->
            {:ok, new_pid} =
              Caudata.ServerSupervisor.start_container_worker(
                state.profile.id,
                container,
                ssh_client: state.ssh_client
              )

            Map.put(acc, container.id, new_pid)
        end
      end)

    broadcast_containers(state.profile.id, new_containers)

    %{state | containers: new_containers, container_pids: updated_pids}
  end
end
