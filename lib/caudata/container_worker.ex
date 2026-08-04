defmodule Caudata.ContainerWorker do
  use GenServer, restart: :temporary
  require Logger
  alias Caudata.LogStore

  defstruct [
    :profile_id,
    :container_id,
    :source_id,
    :container_name,
    :image,
    :status,
    :state,
    :conn_ref,
    :channel_id,
    :stdout_buffer,
    :stderr_buffer,
    :ssh_client,
    :tail_limit,
    :channel_opened_at,
    :pending_logs,
    :flush_timer,
    :password
  ]

  # Client API

  def start_link({profile_id, container, opts}) do
    GenServer.start_link(__MODULE__, {profile_id, container, opts},
      name: {:via, Registry, {Caudata.ServerRegistry, {:container, profile_id, container.id}}}
    )
  end

  def get_info(pid) do
    GenServer.call(pid, :get_info)
  end

  def start_streaming(pid, conn_ref) do
    GenServer.call(pid, {:start_streaming, conn_ref})
  end

  def stop_streaming(pid) do
    GenServer.call(pid, :stop_streaming)
  end

  def get_streaming_status(pid) do
    try do
      GenServer.call(pid, :get_streaming_status, 100)
    catch
      :exit, _ -> %{streaming?: false, opened_at: nil}
    end
  end

  def update_container_info(pid, container) do
    GenServer.cast(pid, {:update_container_info, container})
  end

  # Callbacks

  @impl true
  def init({profile_id, container, opts}) do
    Process.flag(:trap_exit, true)

    ssh_client =
      Keyword.get(opts, :ssh_client) ||
        Application.get_env(:caudata, :ssh_client, Caudata.SSHClient.Native)

    state = %__MODULE__{
      profile_id: profile_id,
      container_id: container.id,
      source_id: "#{profile_id}/#{container.id}",
      container_name: container.name,
      image: Map.get(container, :image, ""),
      status: Map.get(container, :status, ""),
      state: Map.get(container, :state, ""),
      conn_ref: nil,
      channel_id: nil,
      stdout_buffer: "",
      stderr_buffer: "",
      ssh_client: ssh_client,
      tail_limit: 1000,
      channel_opened_at: nil,
      pending_logs: [],
      flush_timer: nil,
      password: Keyword.get(opts, :password)
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:get_info, _from, state) do
    info = %{
      id: state.container_id,
      name: state.container_name,
      image: state.image,
      status: state.status,
      state: state.state
    }

    {:reply, info, state}
  end

  @impl true
  def handle_call(:get_streaming_status, _from, state) do
    info = %{
      streaming?: not is_nil(state.channel_id),
      opened_at: state.channel_opened_at
    }

    {:reply, info, state}
  end

  @impl true
  def handle_call({:start_streaming, conn_ref}, _from, state) do
    if state.channel_id && state.conn_ref == conn_ref do
      {:reply, :ok, state}
    else
      state = close_log_channel(state)

      if is_nil(conn_ref) do
        {:reply, {:error, :not_connected}, state}
      else
        case start_log_streaming(state, conn_ref) do
          {:ok, new_state} ->
            {:reply, :ok, new_state}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
      end
    end
  end

  @impl true
  def handle_call(:stop_streaming, _from, state) do
    new_state = close_log_channel(state)
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_cast({:update_container_info, container}, state) do
    new_state = %{
      state
      | container_name: container.name,
        image: Map.get(container, :image, state.image),
        status: Map.get(container, :status, state.status),
        state: Map.get(container, :state, state.state)
    }

    {:noreply, new_state}
  end

  @impl true
  def handle_cast({:restart_with_tail_limit, new_limit}, state) do
    Caudata.LogStore.clear_logs(state.source_id)

    # Cancel timer and discard pending logs to ensure a clean restart
    state = cancel_flush_timer(state)
    state = %{state | pending_logs: [], stdout_buffer: "", stderr_buffer: ""}

    conn_ref = state.conn_ref

    if state.channel_id && conn_ref do
      state.ssh_client.close_channel(conn_ref, state.channel_id)
    end

    state = %{state | channel_id: nil}

    case start_log_streaming(%{state | tail_limit: new_limit}, conn_ref) do
      {:ok, new_state} ->
        {:noreply, new_state}

      {:error, _reason} ->
        {:noreply, state}
    end
  end

  # Handle SSH incoming messages
  @impl true
  def handle_info({:ssh_cm, conn_ref, {:data, channel_id, stream_id, chunk}}, state) do
    if conn_ref == state.conn_ref && channel_id == state.channel_id do
      chunk_str = to_string(chunk)

      {lines, new_buffer, state_key} =
        if stream_id == 1 do
          {lines, new_buf} = Caudata.LogSanitizer.process_chunk(chunk_str, state.stderr_buffer)
          {lines, new_buf, :stderr_buffer}
        else
          {lines, new_buf} = Caudata.LogSanitizer.process_chunk(chunk_str, state.stdout_buffer)
          {lines, new_buf, :stdout_buffer}
        end

      state = Map.put(state, state_key, new_buffer)

      state =
        if length(lines) > 0 do
          stream = if stream_id == 1, do: :stderr, else: :stdout
          streamed_lines = Enum.map(lines, fn line -> {stream, line} end)

          # Accumulate logs to be flushed in batch (prepended for O(1) efficiency)
          new_pending_logs = Enum.reverse(streamed_lines) ++ state.pending_logs

          # Lazy-start the timer to flush pending logs after 100ms
          if is_nil(state.flush_timer) do
            timer_ref = Process.send_after(self(), :flush_logs, 100)
            %{state | pending_logs: new_pending_logs, flush_timer: timer_ref}
          else
            %{state | pending_logs: new_pending_logs}
          end
        else
          state
        end

      {:noreply, state}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info(:flush_logs, state) do
    # Only reset flush_timer reference since timer has fired
    state = %{state | flush_timer: nil}
    state = flush_pending_logs(state)
    {:noreply, state}
  end

  @impl true
  def handle_info({:ssh_cm, conn_ref, {:eof, channel_id}}, state) do
    if conn_ref == state.conn_ref && channel_id == state.channel_id do
      Logger.info("Received EOF from log stream for container #{state.container_id}")
      new_state = handle_disconnect(state, "EOF received")
      {:noreply, new_state}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info({:ssh_cm, conn_ref, {:exit_status, channel_id, status}}, state) do
    if conn_ref == state.conn_ref && channel_id == state.channel_id do
      Logger.info("Remote command for #{state.container_id} exited with status #{status}")
      new_state = handle_disconnect(state, "Command exited with status #{status}")
      {:noreply, new_state}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info({:ssh_cm, conn_ref, {:closed, channel_id}}, state) do
    if conn_ref == state.conn_ref && channel_id == state.channel_id do
      Logger.info("SSH Channel closed for container #{state.container_id}")
      new_state = handle_disconnect(state, "Channel closed")
      {:noreply, new_state}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info({:ssh_cm, _, _}, state) do
    {:noreply, state}
  end

  @impl true
  def handle_info({:EXIT, _from, reason}, state) do
    {:stop, reason, state}
  end

  @impl true
  def terminate(_reason, state) do
    # Force flush any buffered lines and pending logs on termination
    state = flush_pending_logs(state)

    remaining =
      [{:stdout, state.stdout_buffer}, {:stderr, state.stderr_buffer}]
      |> Enum.filter(fn {_, b} -> b != "" end)

    if remaining != [] do
      LogStore.append_logs(state.source_id, remaining)
    end

    _ = close_log_channel(state)
    :ok
  end

  # Helpers


  defp handle_disconnect(state, reason) do
    # Force flush any pending logs before disconnecting
    state = flush_pending_logs(state)

    remaining =
      [{:stdout, state.stdout_buffer}, {:stderr, state.stderr_buffer}]
      |> Enum.filter(fn {_, b} -> b != "" end)

    if remaining != [] do
      LogStore.append_logs(state.source_id, remaining)
    end

    state = %{state | stdout_buffer: "", stderr_buffer: ""}

    Phoenix.PubSub.broadcast(
      Caudata.PubSub,
      "container_logs:#{state.profile_id}/#{state.container_id}",
      {:container_log_disconnected, state.profile_id, state.container_id, reason}
    )

    close_log_channel(state)
  end

  defp start_log_streaming(state, conn_ref) do
    Logger.info("Streaming logs for #{state.container_id} on #{state.profile_id}...")

    case state.ssh_client.open_channel(conn_ref) do
      {:ok, channel_id} ->
        log_cmd =
          cond do
            String.starts_with?(state.container_id, "file:") ->
              "file:" <> path = state.container_id
              escaped_path = String.replace(path, "'", "'\\\'\''")

              build_log_cmd(
                "tail -n #{state.tail_limit || 100} -F \"#{escaped_path}\"",
                state.password
              )

            String.starts_with?(state.container_id, "systemd:") ->
              "systemd:" <> service_name = state.container_id
              escaped_service = String.replace(service_name, "'", "'\\\'\''")

              build_log_cmd(
                "journalctl -u \"#{escaped_service}\" -f -n #{state.tail_limit || 100}",
                state.password
              )

            String.starts_with?(state.container_id, "launchd:") ->
              "launchd:" <> service_name = state.container_id
              escaped_service = String.replace(service_name, "'", "'\\\'\''")

              build_log_cmd(
                "log stream --predicate \"process == \\\"#{escaped_service}\\\"\"",
                state.password
              )

            true ->
              escaped_container_id = String.replace(state.container_id, "'", "'\\\'\''")

              build_log_cmd(
                "docker logs -t --follow --tail #{state.tail_limit || 1000} #{escaped_container_id}",
                state.password
              )
          end

        case state.ssh_client.exec(conn_ref, channel_id, log_cmd) do
          :ok ->
            {:ok,
             %{
               state
               | conn_ref: conn_ref,
                 channel_id: channel_id,
                 stdout_buffer: "",
                 stderr_buffer: "",
                 channel_opened_at: System.monotonic_time()
             }}

          {:error, reason} ->
            Logger.info(
              "Failed to execute log streaming for #{state.container_id}: #{inspect(reason)}"
            )

            {:error, reason}
        end

      {:error, reason} ->
        Logger.info("Failed to open channel for container logs: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp close_log_channel(state) do
    # Cancel any active flush timer and flush logs before closing the channel
    state = cancel_flush_timer(state)
    state = flush_pending_logs(state)

    if state.channel_id && state.conn_ref do
      Logger.info(
        "Closing log channel #{inspect(state.channel_id)} for container #{state.container_id}"
      )

      state.ssh_client.close_channel(state.conn_ref, state.channel_id)
    end

    %{state | channel_id: nil, conn_ref: nil, channel_opened_at: nil}
  end

  # Flush logs helper that writes all pending logs to LogStore
  defp flush_pending_logs(state) do
    if state.pending_logs != [] do
      logs_to_send = Enum.reverse(state.pending_logs)
      LogStore.append_logs(state.source_id, logs_to_send)
      %{state | pending_logs: []}
    else
      state
    end
  end

  # Cancels the active flush timer if it exists and flushes any message from the mailbox
  defp cancel_flush_timer(state) do
    if state.flush_timer do
      Process.cancel_timer(state.flush_timer)

      # Drain any pending :flush_logs message from mailbox
      receive do
        :flush_logs -> :ok
      after
        0 -> :ok
      end

      %{state | flush_timer: nil}
    else
      state
    end
  end

  defp build_log_cmd(base_cmd, password) do
    cond do
      password && password != "" ->
        escaped_password = String.replace(password, "'", "'\\''")
        escaped_cmd = String.replace(base_cmd, "'", "'\\''")

        inner_script =
          "if true <&0 2>/dev/null; then exec 3<&0; fi; " <>
            "echo '#{escaped_password}' | sudo -S -p '' sh -c 'if true <&3 2>/dev/null; then exec 0<&3 3<&-; fi; exec #{escaped_cmd}' & pid=$!; " <>
            "trap 'kill $pid 2>/dev/null' EXIT HUP INT TERM; read -r _; kill $pid 2>/dev/null"

        escaped_for_dq =
          inner_script
          |> String.replace("\\", "\\\\")
          |> String.replace("\"", "\\\"")
          |> String.replace("$", "\\$")
          |> String.replace("`", "\\`")

        "sh -c \"#{escaped_for_dq}\""

      true ->
        escaped_cmd = String.replace(base_cmd, "'", "'\\''")

        inner_script =
          "if command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then exec sudo -n #{escaped_cmd}; else exec #{escaped_cmd}; fi & pid=$!; trap 'kill $pid 2>/dev/null' EXIT HUP INT TERM; read -r _; kill $pid 2>/dev/null"

        escaped_for_dq =
          inner_script
          |> String.replace("\\", "\\\\")
          |> String.replace("\"", "\\\"")
          |> String.replace("$", "\\$")
          |> String.replace("`", "\\`")

        "sh -c \"#{escaped_for_dq}\""
    end
  end
end
