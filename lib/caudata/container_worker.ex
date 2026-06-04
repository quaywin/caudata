defmodule Caudata.ContainerWorker do
  use GenServer, restart: :transient
  require Logger
  alias Caudata.LogStore

  defstruct [
    :profile_id,
    :container_id,
    :container_name,
    :image,
    :status,
    :state,
    :conn_ref,
    :channel_id,
    :buffer,
    :ssh_client,
    :tail_limit
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
      container_name: container.name,
      image: Map.get(container, :image, ""),
      status: Map.get(container, :status, ""),
      state: Map.get(container, :state, ""),
      conn_ref: nil,
      channel_id: nil,
      buffer: "",
      ssh_client: ssh_client,
      tail_limit: 100
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
    source_id = "#{state.profile_id}/#{state.container_id}"
    Caudata.LogStore.clear_logs(source_id)

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
      {lines, new_buffer} = process_chunk(chunk_str, state.buffer)

      if length(lines) > 0 do
        source_id = "#{state.profile_id}/#{state.container_id}"

        processed_lines =
          if stream_id == 1 do
            Enum.map(lines, fn line -> "[stderr] " <> line end)
          else
            lines
          end

        LogStore.append_logs(source_id, processed_lines)
      end

      {:noreply, %{state | buffer: new_buffer}}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info({:ssh_cm, conn_ref, {:eof, channel_id}}, state) do
    if conn_ref == state.conn_ref && channel_id == state.channel_id do
      Logger.debug("Received EOF from log stream for container #{state.container_id}")
      new_state = handle_disconnect(state, "EOF received")
      {:noreply, new_state}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info({:ssh_cm, conn_ref, {:exit_status, channel_id, status}}, state) do
    if conn_ref == state.conn_ref && channel_id == state.channel_id do
      Logger.debug("Remote command for #{state.container_id} exited with status #{status}")
      new_state = handle_disconnect(state, "Command exited with status #{status}")
      {:noreply, new_state}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info({:ssh_cm, conn_ref, {:closed, channel_id}}, state) do
    if conn_ref == state.conn_ref && channel_id == state.channel_id do
      Logger.debug("SSH Channel closed for container #{state.container_id}")
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
  def terminate(_reason, state) do
    if state.buffer != "" do
      source_id = "#{state.profile_id}/#{state.container_id}"
      LogStore.append_logs(source_id, [state.buffer])
    end

    _ = close_log_channel(state)
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
    if state.buffer != "" do
      source_id = "#{state.profile_id}/#{state.container_id}"
      LogStore.append_logs(source_id, [state.buffer])
    end

    Phoenix.PubSub.broadcast(
      Caudata.PubSub,
      "container_logs:#{state.profile_id}/#{state.container_id}",
      {:container_log_disconnected, state.profile_id, state.container_id, reason}
    )

    close_log_channel(state)
  end

  defp start_log_streaming(state, conn_ref) do
    Logger.debug("Streaming logs for #{state.container_id} on #{state.profile_id}...")

    case state.ssh_client.open_channel(conn_ref) do
      {:ok, channel_id} ->
        log_cmd =
          if String.starts_with?(state.container_id, "file:") do
            "file:" <> path = state.container_id
            "tail -n #{state.tail_limit || 100} -F \"#{path}\""
          else
            "docker logs --follow --tail #{state.tail_limit || 1000} #{state.container_id}"
          end

        case state.ssh_client.exec(conn_ref, channel_id, log_cmd) do
          :ok ->
            {:ok,
             %{
               state
               | conn_ref: conn_ref,
                 channel_id: channel_id,
                 buffer: ""
             }}

          {:error, reason} ->
            Logger.debug(
              "Failed to execute docker logs for #{state.container_id}: #{inspect(reason)}"
            )

            {:error, reason}
        end

      {:error, reason} ->
        Logger.debug("Failed to open channel for container logs: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp close_log_channel(state) do
    if state.channel_id && state.conn_ref do
      state.ssh_client.close_channel(state.conn_ref, state.channel_id)
    end

    %{state | channel_id: nil, conn_ref: nil}
  end
end
