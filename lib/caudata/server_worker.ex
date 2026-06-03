defmodule Caudata.ServerWorker do
  use GenServer, restart: :transient
  require Logger
  alias Caudata.LogStore

  @max_reconnect_delay 30_000
  @initial_reconnect_delay 1000

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
    :conn_task_pid,
    :tail_limit
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
    GenServer.call(pid, :get_status)
  end

  @doc """
  Gets the list of discovered containers.
  """
  def get_containers(pid) do
    GenServer.call(pid, :get_containers)
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
      conn_task_pid: nil,
      tail_limit: nil
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
  def handle_call({:stream_container_logs, container_id}, _from, state) do
    # Close server log channel if any
    state = close_ssh_log_channel(state)

    # Stop any other active container stream
    state = stop_active_container_stream(state)

    if is_nil(state.conn_ref) do
      {:reply, {:error, :not_connected}, %{state | active_container_id: container_id}}
    else
      case Map.fetch(state.container_pids, container_id) do
        {:ok, pid} ->
          case Caudata.ContainerWorker.start_streaming(pid, state.conn_ref) do
            :ok ->
              {:reply, :ok, %{state | active_container_id: container_id}}

            {:error, reason} ->
              {:reply, {:error, reason}, %{state | active_container_id: container_id}}
          end

        :error ->
          {:reply, {:error, :container_not_found}, %{state | active_container_id: container_id}}
      end
    end
  end

  @impl true
  def handle_call(:stream_server_logs, _from, state) do
    state = close_ssh_log_channel(state)
    state = stop_active_container_stream(state)

    if is_nil(state.conn_ref) do
      {:reply, {:error, :not_connected}, %{state | active_container_id: nil}}
    else
      case start_server_log_streaming(state) do
        {:ok, new_state} ->
          {:reply, :ok, new_state}

        {:error, reason, new_state} ->
          {:reply, {:error, reason}, new_state}
      end
    end
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
              Logger.error("Failed to exec docker ps on refresh: #{inspect(reason)}")
              {:noreply, state}
          end

        {:error, reason} ->
          Logger.error("Failed to open channel on refresh: #{inspect(reason)}")
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
      identity_file: state.profile.identity_file
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

        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:ssh_connect_failed, reason}, state) do
    Logger.error("Failed to establish SSH connection to #{state.profile.id}: #{inspect(reason)}")
    handle_disconnect(state, "Connection failed: #{inspect(reason)}")
  end

  # Handle SSH incoming messages
  @impl true
  def handle_info(
        {:ssh_cm, conn_ref, {:data, channel_id, stream_id, chunk}},
        state
      ) do
    cond do
      conn_ref == state.conn_ref && channel_id == state.list_channel_id ->
        new_buffer = state.list_buffer <> to_string(chunk)
        {:noreply, %{state | list_buffer: new_buffer}}

      conn_ref == state.conn_ref && channel_id == state.channel_id ->
        chunk_str = to_string(chunk)
        {lines, new_buffer} = process_chunk(chunk_str, state.buffer)

        if length(lines) > 0 do
          source_id = state.profile.id

          processed_lines =
            if stream_id == 1 do
              Enum.map(lines, fn line -> "[stderr] " <> line end)
            else
              lines
            end

          # Batch insert to LogStore
          LogStore.append_logs(source_id, processed_lines)
        end

        {:noreply, %{state | buffer: new_buffer}}

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
        Logger.warning("Received EOF from server log stream")
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
        Logger.warning("Remote server log command exited with status #{status}")

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

        state = sync_container_workers(state, containers)

        state =
          if state.active_container_id do
            if Enum.any?(containers, &(&1.id == state.active_container_id)) do
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

        {:noreply, state}

      conn_ref == state.conn_ref && channel_id == state.channel_id ->
        Logger.warning("SSH Channel closed for server logs")
        handle_disconnect(state, "Channel closed")

      conn_ref == state.conn_ref ->
        Logger.warning("SSH Connection closed for #{state.profile.id}")
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
  def handle_continue(:do_connect, state) do
    send(self(), :connect)
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    # Cancel reconnect timer
    state = cancel_reconnect_timer(state)

    # Stop connection task
    if state.conn_task_pid do
      send(state.conn_task_pid, :stop)
    end

    # Ensure any remaining buffer is flushed as a log line
    if state.buffer != "" do
      LogStore.append_logs(state.profile.id, [state.buffer])
    end

    # Clean close SSH connection
    state = close_log_channel(state)
    state = close_list_channel(state)

    # Stop all container workers
    Enum.each(state.container_pids, fn {_id, pid} ->
      if Process.alive?(pid) do
        _ = Caudata.ServerSupervisor.stop_container_worker(pid)
      end
    end)

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

    # Stop active container stream
    state = stop_active_container_stream(state)

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
         conn_task_pid: nil
     }}
  end

  defp start_server_log_streaming(state) do
    base_cmd = state.profile.log_command || "tail -F /var/log/messages"
    log_cmd = build_log_command(base_cmd, state.tail_limit)
    Logger.info("Streaming server logs via: #{log_cmd} on #{state.profile.id}...")

    case state.ssh_client.open_channel(state.conn_ref) do
      {:ok, channel_id} ->
        case state.ssh_client.exec(state.conn_ref, channel_id, log_cmd) do
          :ok ->
            {:ok,
             %{
               state
               | channel_id: channel_id,
                 active_container_id: nil,
                 buffer: ""
             }}

          {:error, reason} ->
            Logger.error("Failed to execute server log command: #{inspect(reason)}")
            {:error, reason, %{state | active_container_id: nil}}
        end

      {:error, reason} ->
        Logger.error("Failed to open channel for server logs: #{inspect(reason)}")
        {:error, reason, %{state | active_container_id: nil}}
    end
  end

  defp close_log_channel(state) do
    if state.channel_id && state.conn_ref do
      state.ssh_client.close_channel(state.conn_ref, state.channel_id)
    end

    %{state | channel_id: nil, conn_ref: nil}
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

  defp sync_container_workers(state, new_containers) do
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

    %{state | containers: new_containers, container_pids: updated_pids}
  end

  defp stop_active_container_stream(state) do
    if state.active_container_id do
      case Map.fetch(state.container_pids, state.active_container_id) do
        {:ok, pid} ->
          if Process.alive?(pid) do
            _ = Caudata.ContainerWorker.stop_streaming(pid)
          end

        :error ->
          :ok
      end
    end

    state
  end
end
