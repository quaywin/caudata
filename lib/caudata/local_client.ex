defmodule Caudata.LocalClient do
  @behaviour Caudata.SSHClient
  require Logger

  @impl true
  def connect(host, port, opts) do
    Logger.info("LocalClient connecting (host: #{inspect(host)}, port: #{inspect(port)})")
    password = Keyword.get(opts, :password)
    {:ok, {:local_conn, password}}
  end

  @impl true
  def open_channel({:local_conn, _password} = conn_ref) do
    # Spawns a channel process which acts as the SSH channel adapter.
    Caudata.LocalClient.Channel.start(conn_ref)
  end

  @impl true
  def exec(_conn_ref, channel_pid, command) when is_pid(channel_pid) do
    send(channel_pid, {:exec, command, self()})
    :ok
  end

  @impl true
  def close_channel(_conn_ref, channel_pid) when is_pid(channel_pid) do
    send(channel_pid, :close)
    :ok
  end

  @impl true
  def close(_conn_ref) do
    :ok
  end
end

defmodule Caudata.LocalClient.Channel do
  require Logger

  def start(conn_ref) do
    caller = self()

    Task.start(fn ->
      # Monitor caller so we clean up if the calling process exits
      Process.monitor(caller)
      loop(nil, conn_ref, caller)
    end)
  end

  defp loop(port, conn_ref, caller) do
    receive do
      {:exec, command, reply_to} ->
        if port, do: Port.close(port)

        # Start the port. We use stderr_to_stdout: true to merge stdout/stderr,
        # or we can use :stderr to split them.
        # Since Erlang supports :stderr option, let's use [:binary, :exit_status, :stderr]
        # and forward stdout as stream_id: 0, stderr as stream_id: 1.
        try do
          sh_path = System.find_executable("sh") || "/bin/sh"
          # Note: we use :stderr_to_stdout to merge stdout and stderr.
          new_port =
            Port.open({:spawn_executable, sh_path}, [
              :binary,
              :exit_status,
              :stderr_to_stdout,
              args: ["-c", command]
            ])

          loop(new_port, conn_ref, reply_to)
        rescue
          e ->
            Logger.error("Failed to open local port for command: #{inspect(e)}")
            send(reply_to, {:ssh_cm, conn_ref, {:exit_status, self(), 1}})
            send(reply_to, {:ssh_cm, conn_ref, {:closed, self()}})
            loop(nil, conn_ref, reply_to)
        end

      # stdout and stderr data from port
      {^port, {:data, chunk}} when is_binary(chunk) ->
        send(caller, {:ssh_cm, conn_ref, {:data, self(), 0, chunk}})
        loop(port, conn_ref, caller)

      # port exit status
      {^port, {:exit_status, status}} ->
        send(caller, {:ssh_cm, conn_ref, {:eof, self()}})
        send(caller, {:ssh_cm, conn_ref, {:exit_status, self(), status}})
        send(caller, {:ssh_cm, conn_ref, {:closed, self()}})
        loop(nil, conn_ref, caller)

      {:DOWN, _ref, :process, ^caller, _reason} ->
        if port, do: Port.close(port)
        :ok

      :close ->
        if port, do: Port.close(port)
        :ok
    end
  end
end
