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
  def adjust_window(_conn_ref, _channel_pid, _bytes) do
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
      ref = Process.monitor(caller)
      loop(nil, conn_ref, caller, %{caller => ref})
    end)
  end

  defp loop(port, conn_ref, active_dest, monitors) do
    receive do
      {:exec, command, reply_to} ->
        if port, do: Port.close(port)

        # Monitor the new recipient if not already monitored
        monitors =
          if Map.has_key?(monitors, reply_to) do
            monitors
          else
            ref = Process.monitor(reply_to)
            Map.put(monitors, reply_to, ref)
          end

        try do
          sh_path = System.find_executable("sh") || "/bin/sh"

          new_port =
            Port.open({:spawn_executable, sh_path}, [
              :binary,
              :exit_status,
              :stderr_to_stdout,
              args: ["-c", command]
            ])

          loop(new_port, conn_ref, reply_to, monitors)
        rescue
          e ->
            Logger.error("Failed to open local port for command: #{inspect(e)}")
            send(reply_to, {:ssh_cm, conn_ref, {:exit_status, self(), 1}})
            send(reply_to, {:ssh_cm, conn_ref, {:closed, self()}})
            loop(nil, conn_ref, reply_to, monitors)
        end

      # stdout and stderr data from port
      {^port, {:data, chunk}} when is_binary(chunk) ->
        send(active_dest, {:ssh_cm, conn_ref, {:data, self(), 0, chunk}})
        loop(port, conn_ref, active_dest, monitors)

      # port exit status
      {^port, {:exit_status, status}} ->
        send(active_dest, {:ssh_cm, conn_ref, {:eof, self()}})
        send(active_dest, {:ssh_cm, conn_ref, {:exit_status, self(), status}})
        send(active_dest, {:ssh_cm, conn_ref, {:closed, self()}})
        loop(nil, conn_ref, active_dest, monitors)

      {:DOWN, _ref, :process, _pid, _reason} ->
        if port, do: Port.close(port)
        # Clean up all monitors
        Enum.each(monitors, fn {_pid, ref} -> Process.demonitor(ref, [:flush]) end)
        :ok

      :close ->
        if port, do: Port.close(port)
        # Demonitor all to be clean
        Enum.each(monitors, fn {_pid, ref} -> Process.demonitor(ref, [:flush]) end)
        :ok
    end
  end
end
