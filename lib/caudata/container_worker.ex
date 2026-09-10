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
    :ssh_client,
    :tail_limit,
    :channel_opened_at,
    :pending_logs,
    :flush_timer,
    :password,
    :reconnecting_stream,
    :should_stream,
    :reconnect_timer,
    :stream_channel,
    :pool
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

  def get_stream_channel(pid) do
    GenServer.call(pid, :get_stream_channel)
  end

  def get_streaming_status(pid) do
    try do
      GenServer.call(pid, :get_streaming_status, 100)
    catch
      :exit, _ -> %{streaming?: false, opened_at: nil, stream_channel: nil}
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
      ssh_client: ssh_client,
      tail_limit: 1000,
      channel_opened_at: nil,
      pending_logs: [],
      flush_timer: nil,
      password: Keyword.get(opts, :password),
      reconnecting_stream: false,
      should_stream: false,
      reconnect_timer: nil,
      stream_channel: nil,
      pool: Keyword.get(opts, :pool)
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
  def handle_call(:get_stream_channel, _from, state) do
    {:reply, state.stream_channel, state}
  end

  @impl true
  def handle_call(:get_streaming_status, _from, state) do
    info = %{
      streaming?: not is_nil(state.channel_id),
      opened_at: state.channel_opened_at,
      stream_channel: state.stream_channel
    }

    {:reply, info, state}
  end

  @impl true
  def handle_call({:start_streaming, conn_ref}, _from, state) do
    state = cancel_reconnect_timer(state)
    state = %{state | should_stream: true}

    is_stopped =
      state.state in ["exited", "stopped", "dead", "paused"] or
        String.starts_with?(state.status, "Exited")

    has_logs =
      if Process.whereis(Caudata.LogStore) do
        stats = Caudata.LogStore.get_stats(Caudata.LogStore, state.source_id)
        stats.size > 0
      else
        false
      end

    if is_stopped and has_logs do
      {:reply, :ok, state}
    else
      already_streaming? =
        state.channel_id != nil and
          ((is_pid(state.pool) and Process.alive?(state.pool)) or state.conn_ref == conn_ref)

      if already_streaming? do
        {:reply, :ok, state}
      else
        state = close_log_channel(state)
        state = %{state | should_stream: true}

        if is_nil(conn_ref) and not (is_pid(state.pool) and Process.alive?(state.pool)) do
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
  end

  @impl true
  def handle_call(:stop_streaming, _from, state) do
    state = cancel_reconnect_timer(state)
    state = %{state | should_stream: false}
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

    new_state =
      if (new_state.channel_id || new_state.reconnect_timer) &&
           (new_state.state in ["exited", "stopped", "dead", "paused"] or
              String.starts_with?(new_state.status, "Exited")) do
        new_state = cancel_reconnect_timer(new_state)
        new_state = %{new_state | should_stream: false}
        close_log_channel(new_state)
      else
        new_state
      end

    {:noreply, new_state}
  end

  @impl true
  def handle_cast({:restart_with_tail_limit, new_limit}, state) do
    Caudata.LogStore.clear_logs(state.source_id)

    # Cancel timer and discard pending logs to ensure a clean restart
    state = cancel_flush_timer(state)
    state = %{state | pending_logs: []}

    conn_ref = state.conn_ref

    if state.stream_channel do
      Caudata.SSH.StreamChannel.stop(state.stream_channel)
    end

    state = %{state | channel_id: nil, stream_channel: nil}

    case start_log_streaming(%{state | tail_limit: new_limit}, conn_ref) do
      {:ok, new_state} ->
        {:noreply, new_state}

      {:error, _reason} ->
        {:noreply, state}
    end
  end

  # Handle StreamChannel high-level events
  @impl true
  def handle_info({:stream_lines, _pid, stream, lines}, state) do
    streamed_lines = Enum.map(lines, fn line -> {stream, line} end)
    new_pending_logs = Enum.reverse(streamed_lines) ++ state.pending_logs

    state =
      if is_nil(state.flush_timer) do
        timer_ref = Process.send_after(self(), :flush_logs, 100)
        %{state | pending_logs: new_pending_logs, flush_timer: timer_ref}
      else
        %{state | pending_logs: new_pending_logs}
      end

    {:noreply, state}
  end

  @impl true
  def handle_info({:stream_eof, _pid}, state) do
    Logger.info("Received EOF from log stream for container #{state.container_id}")
    {:noreply, handle_disconnect(state, "EOF received")}
  end

  @impl true
  def handle_info({:stream_exit_status, _pid, status}, state) do
    Logger.info("Remote command for #{state.container_id} exited with status #{status}")
    {:noreply, handle_disconnect(state, "Command exited with status #{status}")}
  end

  @impl true
  def handle_info({:stream_closed, _pid}, state) do
    Logger.info("SSH Channel closed for container #{state.container_id}")
    {:noreply, handle_disconnect(state, "Channel closed")}
  end

  @impl true
  def handle_info(:flush_logs, state) do
    # Only reset flush_timer reference since timer has fired
    state = %{state | flush_timer: nil}
    state = flush_pending_logs(state)
    {:noreply, state}
  end

  @impl true
  def handle_info(:reconnect_stream, state) do
    state = %{state | reconnect_timer: nil}

    is_stopped =
      state.state in ["exited", "stopped", "dead", "paused"] or
        String.starts_with?(state.status, "Exited")

    can_stream? =
      state.should_stream and not is_stopped and
        ((is_pid(state.pool) and Process.alive?(state.pool)) or not is_nil(state.conn_ref))

    if can_stream? and is_nil(state.channel_id) do
      Logger.info("Attempting auto-reconnect log stream for #{state.container_id}...")

      case start_log_streaming(state, state.conn_ref) do
        {:ok, new_state} ->
          {:noreply, new_state}

        {:error, reason} ->
          Logger.warning(
            "Failed to auto-reconnect log stream for #{state.container_id}: #{inspect(reason)}. Retrying in 2000ms..."
          )

          timer = Process.send_after(self(), :reconnect_stream, 2000)
          {:noreply, %{state | reconnect_timer: timer}}
      end
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info({:EXIT, _from, :normal}, state) do
    {:noreply, state}
  end

  @impl true
  def handle_info({:EXIT, _from, reason}, state) do
    {:stop, reason, state}
  end

  @impl true
  def terminate(_reason, state) do
    state = cancel_reconnect_timer(state)
    state = %{state | should_stream: false}

    # Force flush any pending logs on termination
    _ = flush_pending_logs(state)
    _ = close_log_channel(state)
    :ok
  end

  # Helpers

  defp handle_disconnect(state, reason) do
    # Force flush any pending logs before disconnecting
    state = flush_pending_logs(state)

    Phoenix.PubSub.broadcast(
      Caudata.PubSub,
      "container_logs:#{state.profile_id}/#{state.container_id}",
      {:container_log_disconnected, state.profile_id, state.container_id, reason}
    )

    is_stopped =
      state.state in ["exited", "stopped", "dead", "paused"] or
        String.starts_with?(state.status, "Exited")

    if state.stream_channel do
      Caudata.SSH.StreamChannel.stop(state.stream_channel)
    end

    state = %{
      state
      | stream_channel: nil,
        channel_id: nil,
        channel_opened_at: nil,
        reconnecting_stream: false
    }

    can_stream? =
      state.should_stream and not is_stopped and
        ((is_pid(state.pool) and Process.alive?(state.pool)) or not is_nil(state.conn_ref))

    if can_stream? do
      Logger.info("Scheduling log stream reconnect for #{state.container_id} in 1000ms")
      state = cancel_reconnect_timer(state)
      timer = Process.send_after(self(), :reconnect_stream, 1000)
      %{state | reconnect_timer: timer}
    else
      %{state | conn_ref: nil, should_stream: false}
    end
  end

  defp start_log_streaming(state, conn_ref) do
    Logger.info("Streaming logs for #{state.container_id} on #{state.profile_id}...")

    stats =
      if Process.whereis(Caudata.LogStore) do
        Caudata.LogStore.get_stats(Caudata.LogStore, state.source_id)
      else
        %{size: 0, drop_count: 0, last_ts: nil}
      end

    log_cmd = build_log_command_for_container(state, stats)
    is_reconnect = stats.size > 0 && stats.last_ts && stats.last_ts != ""

    stream_opts = [
      cmd: log_cmd,
      notify_to: self(),
      ssh_client: state.ssh_client
    ]

    stream_opts =
      if is_pid(state.pool) and Process.alive?(state.pool) do
        Keyword.put(stream_opts, :pool, state.pool)
      else
        Keyword.put(stream_opts, :conn_ref, conn_ref)
      end

    case Caudata.SSH.StreamChannel.start_link(stream_opts) do
      {:ok, stream_pid} ->
        info = Caudata.SSH.StreamChannel.get_info(stream_pid)

        {:ok,
         %{
           state
           | stream_channel: stream_pid,
             conn_ref: info.conn_ref,
             channel_id: info.channel_id,
             channel_opened_at: System.monotonic_time(),
             reconnecting_stream: is_reconnect
         }}

      {:error, reason} ->
        Logger.info("Failed to open channel for container logs: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp build_log_command_for_container(state, stats) do
    cond do
      String.starts_with?(state.container_id, "file:") ->
        "file:" <> path = state.container_id
        escaped_path = String.replace(path, "'", "'\\\'\''")
        limit = if stats.size > 0, do: 0, else: state.tail_limit || 1000

        build_log_cmd(
          "tail -n #{limit} -F \"#{escaped_path}\"",
          state.password
        )

      String.starts_with?(state.container_id, "systemd:") ->
        "systemd:" <> service_name = state.container_id
        escaped_service = String.replace(service_name, "'", "'\\\'\''")

        cmd =
          cond do
            stats.size > 0 && stats.last_ts && stats.last_ts != "" ->
              limit = state.tail_limit || 1000
              since_ts = clamp_timestamp_max_age(stats.last_ts, 3600)
              "journalctl -u \"#{escaped_service}\" -f -n #{limit} --since \"#{since_ts}\""

            stats.size > 0 ->
              "journalctl -u \"#{escaped_service}\" -f -n 0"

            true ->
              limit = state.tail_limit || 1000
              "journalctl -u \"#{escaped_service}\" -f -n #{limit}"
          end

        build_log_cmd(cmd, state.password)

      String.starts_with?(state.container_id, "launchd:") ->
        "launchd:" <> service_name = state.container_id
        escaped_service = String.replace(service_name, "'", "'\\\'\''")

        build_log_cmd(
          "log stream --predicate \"process == \\\"#{escaped_service}\\\"\"",
          state.password
        )

      true ->
        escaped_container_id = String.replace(state.container_id, "'", "'\\\'\''")

        cmd =
          cond do
            stats.size > 0 && stats.last_ts && stats.last_ts != "" ->
              limit = state.tail_limit || 1000
              since_ts = clamp_timestamp_max_age(stats.last_ts, 3600)

              "docker logs -t --follow --tail #{limit} --since \"#{since_ts}\" #{escaped_container_id}"

            stats.size > 0 ->
              "docker logs -t --follow --tail 0 #{escaped_container_id}"

            true ->
              limit = state.tail_limit || 1000
              "docker logs -t --follow --tail #{limit} #{escaped_container_id}"
          end

        build_log_cmd(cmd, state.password)
    end
  end

  defp close_log_channel(state) do
    # Cancel any active reconnect timer or flush timer and flush logs before closing the channel
    state = cancel_reconnect_timer(state)
    state = cancel_flush_timer(state)
    state = flush_pending_logs(state)

    if state.stream_channel do
      Caudata.SSH.StreamChannel.stop(state.stream_channel)
    end

    %{
      state
      | stream_channel: nil,
        channel_id: nil,
        conn_ref: nil,
        channel_opened_at: nil,
        reconnecting_stream: false,
        reconnect_timer: nil
    }
  end

  # Cancels the active reconnect timer if it exists and flushes any message from the mailbox
  defp cancel_reconnect_timer(state) do
    if state.reconnect_timer do
      Process.cancel_timer(state.reconnect_timer)

      receive do
        :reconnect_stream -> :ok
      after
        0 -> :ok
      end

      %{state | reconnect_timer: nil}
    else
      state
    end
  end

  # Flush logs helper that writes all pending logs to LogStore
  defp flush_pending_logs(state) do
    if state.pending_logs != [] do
      logs_to_send = Enum.reverse(state.pending_logs)

      state =
        if state.reconnecting_stream do
          limit = state.tail_limit || 1000

          if length(logs_to_send) >= limit do
            Logger.info(
              "Log limit reached on reconnect (#{length(logs_to_send)} lines >= #{limit}). Clearing old log buffer for continuous history."
            )

            LogStore.clear_logs(state.source_id)
          end

          %{state | reconnecting_stream: false}
        else
          state
        end

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
    escaped_cmd = String.replace(base_cmd, "'", "'\\''")

    inner_script =
      if password && password != "" do
        escaped_password = String.replace(password, "'", "'\\''")

        "if true <&0 2>/dev/null; then exec 3<&0; fi; " <>
          "echo '#{escaped_password}' | sudo -S -p '' sh -c 'if true <&3 2>/dev/null; then exec 0<&3 3<&-; fi; exec #{escaped_cmd}' & pid=$!; " <>
          "trap 'kill $pid 2>/dev/null' EXIT HUP INT TERM; wait $pid 2>/dev/null; kill $pid 2>/dev/null"
      else
        "if command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then exec sudo -n #{escaped_cmd}; else exec #{escaped_cmd}; fi & pid=$!; trap 'kill $pid 2>/dev/null' EXIT HUP INT TERM; wait $pid 2>/dev/null; kill $pid 2>/dev/null"
      end

    escape_for_subshell(inner_script)
  end

  defp escape_for_subshell(cmd) do
    escaped_for_dq =
      cmd
      |> String.replace("\\", "\\\\")
      |> String.replace("\"", "\\\"")
      |> String.replace("$", "\\$")
      |> String.replace("`", "\\`")

    "sh -c \"#{escaped_for_dq}\""
  end

  def clamp_timestamp_max_age(nil, _max_seconds), do: nil
  def clamp_timestamp_max_age("", _max_seconds), do: nil

  def clamp_timestamp_max_age(last_ts, max_seconds)
      when is_binary(last_ts) and is_integer(max_seconds) do
    case parse_iso8601_dt(last_ts) do
      {:ok, dt} ->
        now = DateTime.utc_now()
        min_allowed = DateTime.add(now, -max_seconds, :second)

        if DateTime.compare(dt, min_allowed) == :lt do
          DateTime.to_iso8601(min_allowed)
        else
          last_ts
        end

      _ ->
        last_ts
    end
  end

  defp parse_iso8601_dt(last_ts) do
    case DateTime.from_iso8601(last_ts) do
      {:ok, dt, _offset} ->
        {:ok, dt}

      _ ->
        case NaiveDateTime.from_iso8601(last_ts) do
          {:ok, ndt} -> {:ok, DateTime.from_naive!(ndt, "Etc/UTC")}
          _ -> :error
        end
    end
  end
end
