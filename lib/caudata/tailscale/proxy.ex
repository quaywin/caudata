defmodule Caudata.Tailscale.SSHProxy do
  use GenServer, restart: :temporary
  require Logger

  def start_proxy(dev, host, port) do
    spec = {__MODULE__, [dev: dev, target_host: host, target_port: port]}

    case DynamicSupervisor.start_child(Caudata.ServerSupervisor, spec) do
      {:ok, pid} ->
        local_port = GenServer.call(pid, :get_port)
        {:ok, pid, {"127.0.0.1", local_port}}

      {:error, err} ->
        {:error, err}
    end
  end

  def stop_proxy(pid) do
    if Process.alive?(pid) do
      ref = Process.monitor(pid)
      Process.exit(pid, :shutdown)

      receive do
        {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
      after
        1000 -> :ok
      end
    else
      :ok
    end
  end

  # Server Callbacks

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl true
  def init(opts) do
    dev = Keyword.fetch!(opts, :dev)
    target_host = Keyword.fetch!(opts, :target_host)
    target_port = Keyword.fetch!(opts, :target_port)

    # Listen on port 0 to let OS assign a random free port on localhost
    case :gen_tcp.listen(0, [
           :binary,
           ip: {127, 0, 0, 1},
           active: false,
           reuseaddr: true,
           nodelay: true,
           recbuf: 65536,
           sndbuf: 65536,
           buffer: 65536
         ]) do
      {:ok, local_listener} ->
        {:ok, {_, local_port}} = :inet.sockname(local_listener)

        Logger.info(
          "SSH Proxy listening on 127.0.0.1:#{local_port} -> Tailscale #{target_host}:#{target_port}"
        )

        Task.start_link(fn -> accept_loop(local_listener, dev, target_host, target_port) end)

        {:ok, %{local_port: local_port, local_listener: local_listener}}

      {:error, err} ->
        {:stop, err}
    end
  end

  @impl true
  def handle_call(:get_port, _from, state) do
    {:reply, state.local_port, state}
  end

  defp accept_loop(local_listener, dev, target_host, target_port) do
    case :gen_tcp.accept(local_listener) do
      {:ok, local_socket} ->
        Task.start(fn ->
          case Tailscale.Tcp.connect(dev, target_host, target_port) do
            {:ok, ts_stream} ->
              t1 = Task.async(fn -> forward_local_to_ts(local_socket, ts_stream) end)
              t2 = Task.async(fn -> forward_ts_to_local(ts_stream, local_socket) end)

              # Wait for either forwarding task to exit, then terminate both to prevent hangs/leaks
              receive do
                {:DOWN, _ref, :process, _pid, _reason} ->
                  Task.shutdown(t1, :brutal_kill)
                  Task.shutdown(t2, :brutal_kill)
              end

            {:error, err} ->
              Logger.error(
                "SSH Proxy failed to connect to Tailscale #{target_host}:#{target_port}: #{inspect(err)}"
              )

              :gen_tcp.close(local_socket)
          end
        end)

        accept_loop(local_listener, dev, target_host, target_port)

      {:error, _err} ->
        :ok
    end
  end

  defp forward_local_to_ts(local_socket, ts_stream) do
    case :gen_tcp.recv(local_socket, 0) do
      {:ok, data} ->
        case safe_ts_send(ts_stream, data) do
          :ok -> forward_local_to_ts(local_socket, ts_stream)
          {:error, _} -> :ok
        end

      _ ->
        :ok
    end
  end

  defp forward_ts_to_local(ts_stream, local_socket) do
    case safe_ts_recv(ts_stream) do
      {:ok, data} when byte_size(data) > 0 ->
        case :gen_tcp.send(local_socket, data) do
          :ok -> forward_ts_to_local(ts_stream, local_socket)
          {:error, _} -> :ok
        end

      _ ->
        :gen_tcp.close(local_socket)
        :ok
    end
  end

  # Helpers to work around type mismatch bugs in ts_elixir library

  defp safe_ts_send(_ts_stream, <<>>), do: :ok

  defp safe_ts_send(ts_stream, binary_data) do
    byte_list = :erlang.binary_to_list(binary_data)

    case Tailscale.Native.tcp_send(ts_stream, byte_list) do
      {:ok, n} when n > 0 ->
        case binary_data do
          <<_::binary-size(n), rest::binary>> ->
            safe_ts_send(ts_stream, rest)

          _ ->
            :ok
        end

      {:ok, 0} ->
        {:error, :blocked}

      {:error, err} ->
        {:error, err}

      other ->
        other
    end
  end

  defp safe_ts_recv(ts_stream) do
    case Tailscale.Tcp.Stream.recv(ts_stream) do
      {:ok, list_or_binary} ->
        binary =
          if is_list(list_or_binary) do
            :erlang.list_to_binary(list_or_binary)
          else
            list_or_binary
          end

        {:ok, binary}

      other ->
        other
    end
  end
end
