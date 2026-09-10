defmodule Caudata.SSH.StreamChannel do
  @moduledoc """
  Manages a single streaming SSH channel (e.g., container logs, systemd journal, file tail).

  Handles low-level SSH channel lifecycle, flow control (`adjust_window`),
  stream chunk buffering, and sanitization. Reports clean lines to the subscriber.
  """

  use GenServer
  require Logger

  defstruct [
    :conn_ref,
    :channel_id,
    :lease_ref,
    :conn_monitor_ref,
    :cmd,
    :notify_to,
    :ssh_client,
    :pool,
    stdout_buffer: "",
    stderr_buffer: ""
  ]

  # Client API

  @doc """
  Starts a StreamChannel.

  ## Options
  * `:notify_to` - PID to receive streaming events (defaults to caller `self()`)
  * `:ssh_client` - Module implementing `Caudata.SSHClient` behaviour
  * `:cmd` - Command string to execute on the channel
  * `:conn_ref` - SSH connection reference (optional if `:pool` is provided)
  * `:pool` - `Caudata.SSH.ConnectionPool` pid (optional if `:conn_ref` is provided)
  """
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc """
  Stops the StreamChannel and closes the underlying SSH channel.
  """
  def stop(pid) do
    if is_pid(pid) and Process.alive?(pid) do
      try do
        GenServer.stop(pid, :normal, 5_000)
      catch
        :exit, _ -> :ok
      end
    else
      :ok
    end
  end

  @doc """
  Gets channel info: `%{conn_ref: ref, channel_id: id}`.
  """
  def get_info(pid) do
    GenServer.call(pid, :get_info)
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    notify_to = Keyword.get(opts, :notify_to, self())
    ssh_client = Keyword.get(opts, :ssh_client, Caudata.SSHClient.Native)
    cmd = Keyword.get(opts, :cmd)
    pool = Keyword.get(opts, :pool)

    res =
      cond do
        pool && is_pid(pool) ->
          case Caudata.SSH.ConnectionPool.checkout_connection(pool, self()) do
            {:ok, conn_ref, lease_ref} ->
              # Important: open_channel must be executed in StreamChannel's process so Erlang :ssh
              # registers StreamChannel as the controlling process to receive {:ssh_cm, ...} events.
              case ssh_client.open_channel(conn_ref) do
                {:ok, channel_id} ->
                  Caudata.SSH.ConnectionPool.attach_channel(pool, conn_ref, lease_ref, channel_id)
                  {:ok, conn_ref, channel_id, lease_ref}

                {:error, reason} ->
                  Caudata.SSH.ConnectionPool.release_connection(pool, conn_ref, lease_ref)
                  {:error, reason}
              end

            {:error, reason} ->
              {:error, reason}
          end

        conn_ref = Keyword.get(opts, :conn_ref) ->
          case ssh_client.open_channel(conn_ref) do
            {:ok, channel_id} -> {:ok, conn_ref, channel_id, nil}
            {:error, reason} -> {:error, reason}
          end

        true ->
          {:error, :missing_connection_or_pool}
      end

    case res do
      {:ok, conn_ref, channel_id, lease_ref} ->
        monitor_ref = if is_pid(conn_ref), do: Process.monitor(conn_ref), else: nil

        state = %__MODULE__{
          conn_ref: conn_ref,
          channel_id: channel_id,
          lease_ref: lease_ref,
          conn_monitor_ref: monitor_ref,
          cmd: cmd,
          notify_to: notify_to,
          ssh_client: ssh_client,
          pool: pool,
          stdout_buffer: "",
          stderr_buffer: ""
        }

        if cmd do
          case ssh_client.exec(conn_ref, channel_id, cmd) do
            :ok ->
              {:ok, state}

            {:error, reason} ->
              cleanup_channel(state)
              {:stop, {:exec_failed, reason}}
          end
        else
          {:ok, state}
        end

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call(:get_info, _from, state) do
    {:reply, %{conn_ref: state.conn_ref, channel_id: state.channel_id}, state}
  end

  # Handle incoming SSH data chunk
  @impl true
  def handle_info({:ssh_cm, conn_ref, {:data, channel_id, stream_id, chunk}}, state) do
    if conn_ref == state.conn_ref and channel_id == state.channel_id do
      chunk_str = to_string(chunk)

      # Maintain SSH flow-control window (RFC 4254) so remote stream never stalls
      _ = state.ssh_client.adjust_window(conn_ref, channel_id, byte_size(chunk_str))

      {lines, new_buffer, state_key} =
        if stream_id == 1 do
          {lines, new_buf} = Caudata.LogSanitizer.process_chunk(chunk_str, state.stderr_buffer)
          {lines, new_buf, :stderr_buffer}
        else
          {lines, new_buf} = Caudata.LogSanitizer.process_chunk(chunk_str, state.stdout_buffer)
          {lines, new_buf, :stdout_buffer}
        end

      state = Map.put(state, state_key, new_buffer)

      if length(lines) > 0 do
        stream = if stream_id == 1, do: :stderr, else: :stdout
        send(state.notify_to, {:stream_lines, self(), stream, lines})
      end

      {:noreply, state}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info({:ssh_cm, conn_ref, {:eof, channel_id}}, state) do
    if conn_ref == state.conn_ref and channel_id == state.channel_id do
      send(state.notify_to, {:stream_eof, self()})
      {:noreply, state}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info({:ssh_cm, conn_ref, {:exit_status, channel_id, status}}, state) do
    if conn_ref == state.conn_ref and channel_id == state.channel_id do
      send(state.notify_to, {:stream_exit_status, self(), status})
      {:noreply, state}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info({:ssh_cm, conn_ref, {:closed, channel_id}}, state) do
    if conn_ref == state.conn_ref and channel_id == state.channel_id do
      send(state.notify_to, {:stream_closed, self()})
      {:stop, :normal, state}
    else
      {:noreply, state}
    end
  end

  # Handle SSH connection termination
  @impl true
  def handle_info({:DOWN, mref, :process, _pid, _reason}, %{conn_monitor_ref: mref} = state) do
    send(state.notify_to, {:stream_closed, self()})
    {:stop, :normal, state}
  end

  @impl true
  def terminate(_reason, state) do
    cleanup_channel(state)
    :ok
  end

  # Private Helpers

  defp cleanup_channel(%{conn_monitor_ref: mref} = state) when not is_nil(mref) do
    Process.demonitor(mref, [:flush])
    do_cleanup_channel(%{state | conn_monitor_ref: nil})
  end

  defp cleanup_channel(state), do: do_cleanup_channel(state)

  defp do_cleanup_channel(%{conn_ref: conn, pool: pool, lease_ref: lease})
       when is_pid(pool) and not is_nil(conn) and not is_nil(lease) do
    Caudata.SSH.ConnectionPool.release_connection(pool, conn, lease)
  end

  defp do_cleanup_channel(%{ssh_client: client, conn_ref: conn, channel_id: chan})
       when not is_nil(client) and not is_nil(conn) and not is_nil(chan) do
    try do
      client.close_channel(conn, chan)
    catch
      _, _ -> :ok
    end
  end

  defp do_cleanup_channel(_), do: :ok
end
