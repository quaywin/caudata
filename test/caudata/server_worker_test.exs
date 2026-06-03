defmodule Caudata.ServerWorkerTest do
  use ExUnit.Case, async: false
  import Mox
  alias Caudata.Profile
  alias Caudata.ServerWorker
  alias Caudata.LogStore
  alias Caudata.SSHClient.Mock

  setup :verify_on_exit!

  setup do
    set_mox_global()
    # No need to start PubSub or ServerRegistry because they are already booted globally
    # via the application supervision tree.
    :ok
  end

  test "successful connection and log streaming lifecycle" do
    profile =
      Profile.new(%{
        host_pattern: "test-server",
        host_name: "127.0.0.1",
        user: "test-user",
        port: 2222,
        log_command: "tail -F /var/log/test"
      })

    test_pid = self()

    # Set up expectations on the SSH Client Mock
    Mock
    |> expect(:connect, fn "127.0.0.1", 2222, [user: "test-user", identity_file: nil] ->
      {:ok, :dummy_conn}
    end)
    |> expect(:open_channel, fn :dummy_conn ->
      send(test_pid, :opened_list_channel)
      {:ok, :dummy_list_channel}
    end)
    |> expect(:exec, fn :dummy_conn, :dummy_list_channel, "docker ps --format '{{json .}}'" ->
      :ok
    end)
    |> expect(:open_channel, fn :dummy_conn ->
      {:ok, :dummy_server_log_channel}
    end)
    |> expect(:exec, fn :dummy_conn, :dummy_server_log_channel, "tail -F /var/log/test" ->
      :ok
    end)
    |> expect(:close_channel, fn :dummy_conn, :dummy_server_log_channel ->
      :ok
    end)
    |> expect(:open_channel, fn :dummy_conn ->
      {:ok, :dummy_log_channel}
    end)
    |> expect(:exec, fn :dummy_conn,
                        :dummy_log_channel,
                        "docker logs --follow --tail 100 container1" ->
      :ok
    end)
    |> expect(:close_channel, fn :dummy_conn, :dummy_log_channel ->
      :ok
    end)
    |> expect(:close, fn :dummy_conn ->
      :ok
    end)

    # Subscribe to status changes
    Phoenix.PubSub.subscribe(Caudata.PubSub, "servers")
    # Subscribe to log updates
    Phoenix.PubSub.subscribe(Caudata.PubSub, "logs:test-server/container1")

    # Start the worker
    {:ok, worker_pid} = start_supervised({ServerWorker, {profile, ssh_client: Mock}})

    # Wait for async connection setup to complete
    assert_receive :opened_list_channel, 1000

    # Simulate sending docker ps data chunk and closing the list channel
    send(
      worker_pid,
      {:ssh_cm, :dummy_conn,
       {:data, :dummy_list_channel, 0,
        "{\"ID\":\"container1\",\"Names\":\"test-container\",\"Image\":\"nginx\",\"Status\":\"Up\"}\n"}}
    )

    send(worker_pid, {:ssh_cm, :dummy_conn, {:closed, :dummy_list_channel}})

    # Expect connected status broadcast
    assert_receive {:status_updated, "test-server", :connected}, 1000

    assert ServerWorker.get_status(worker_pid) == :connected

    assert ServerWorker.get_containers(worker_pid) == [
             %{id: "container1", name: "test-container", image: "nginx", status: "Up", state: ""}
           ]

    # Start streaming logs
    assert :ok = GenServer.call(worker_pid, {:stream_container_logs, "container1"})

    # Find the ContainerWorker pid
    {:ok, container_worker_pid} =
      Caudata.ServerSupervisor.lookup_container_worker("test-server", "container1")

    # Simulate receiving incoming data chunk split across packets on the ContainerWorker
    send(
      container_worker_pid,
      {:ssh_cm, :dummy_conn, {:data, :dummy_log_channel, 0, "line 1\npart"}}
    )

    send(
      container_worker_pid,
      {:ssh_cm, :dummy_conn, {:data, :dummy_log_channel, 0, " 2\nline 3\n"}}
    )

    # Expect log updates and verify LogStore state
    assert_receive {:logs_updated, "test-server/container1", _}, 1000

    # Wait for the casts to complete in LogStore
    Process.sleep(50)

    # Read from global LogStore
    snapshot = LogStore.get_snapshot("test-server/container1")
    assert snapshot == ["line 1", "part 2", "line 3"]

    # Terminate the process to verify cleanup and close
    stop_supervised(ServerWorker)
    assert_receive {:status_updated, "test-server", :disconnected}, 1000
  end

  test "reconnection behavior on channel close" do
    profile =
      Profile.new(%{
        host_pattern: "reconnect-server",
        host_name: "10.0.0.1",
        user: "root",
        port: 22
      })

    test_pid = self()

    # First attempt: connection succeeds, then docker ps channel closes, then log stream channel opens
    Mock
    # First connect
    |> expect(:connect, fn "10.0.0.1", 22, _ -> {:ok, :dummy_conn} end)
    |> expect(:open_channel, fn :dummy_conn ->
      send(test_pid, :opened_list_channel1)
      {:ok, :dummy_list_channel}
    end)
    |> expect(:exec, fn :dummy_conn, :dummy_list_channel, "docker ps --format '{{json .}}'" ->
      :ok
    end)
    |> expect(:open_channel, fn :dummy_conn ->
      {:ok, :dummy_server_log_channel}
    end)
    |> expect(:exec, fn :dummy_conn, :dummy_server_log_channel, "tail -F /var/log/messages" ->
      :ok
    end)
    |> expect(:close_channel, fn :dummy_conn, :dummy_server_log_channel ->
      :ok
    end)
    # Then log stream channel open
    |> expect(:open_channel, fn :dummy_conn -> {:ok, :dummy_log_channel} end)
    |> expect(:exec, fn :dummy_conn,
                        :dummy_log_channel,
                        "docker logs --follow --tail 100 container1" ->
      :ok
    end)
    # Reconnect attempt starts:
    |> expect(:connect, fn "10.0.0.1", 22, _ -> {:ok, :dummy_conn2} end)
    |> expect(:open_channel, fn :dummy_conn2 ->
      send(test_pid, :opened_list_channel2)
      {:ok, :dummy_list_channel2}
    end)
    |> expect(:exec, fn :dummy_conn2, :dummy_list_channel2, "docker ps --format '{{json .}}'" ->
      :ok
    end)
    # On reconnect, container1 is not found, so it falls back to server logs
    |> expect(:open_channel, fn :dummy_conn2 ->
      {:ok, :dummy_server_log_channel2}
    end)
    |> expect(:exec, fn :dummy_conn2, :dummy_server_log_channel2, "tail -F /var/log/messages" ->
      :ok
    end)
    # Cleanup calls
    |> expect(:close_channel, fn :dummy_conn, :dummy_log_channel -> :ok end)
    |> expect(:close_channel, fn :dummy_conn2, :dummy_server_log_channel2 -> :ok end)
    |> expect(:close, fn :dummy_conn -> :ok end)
    |> expect(:close, fn :dummy_conn2 -> :ok end)

    Phoenix.PubSub.subscribe(Caudata.PubSub, "servers")

    # Start the worker
    {:ok, worker_pid} = start_supervised({ServerWorker, {profile, ssh_client: Mock}})

    # Wait for list channel open
    assert_receive :opened_list_channel1, 1000

    # Simulate container listing completion
    send(
      worker_pid,
      {:ssh_cm, :dummy_conn,
       {:data, :dummy_list_channel, 0, "{\"ID\":\"container1\",\"Names\":\"test-container\"}\n"}}
    )

    send(worker_pid, {:ssh_cm, :dummy_conn, {:closed, :dummy_list_channel}})

    assert_receive {:status_updated, "reconnect-server", :connected}, 1000

    # Start streaming
    assert :ok = GenServer.call(worker_pid, {:stream_container_logs, "container1"})

    # Simulate connection close by SSH manager
    send(worker_pid, {:ssh_cm, :dummy_conn, {:closed, :dummy_conn}})

    # Expect worker to transition to :connecting status broadcast
    assert_receive {:status_updated, "reconnect-server", :connecting}, 1000

    # Wait for the reconnect connection to be established and the list channel to open
    assert_receive :opened_list_channel2, 2000

    # After reconnecting, it will first open the docker ps list channel again
    send(worker_pid, {:ssh_cm, :dummy_conn2, {:closed, :dummy_list_channel2}})
    assert_receive {:status_updated, "reconnect-server", :connected}, 2000

    stop_supervised(ServerWorker)
    assert_receive {:status_updated, "reconnect-server", :disconnected}, 1000
  end

  test "reconnection resumes active container logs stream if container still exists" do
    profile =
      Profile.new(%{
        host_pattern: "reconnect-resume-server",
        host_name: "10.0.0.2",
        user: "root",
        port: 22
      })

    test_pid = self()

    # First attempt: connection succeeds, then docker ps channel closes, then log stream channel opens
    Mock
    # First connect
    |> expect(:connect, fn "10.0.0.2", 22, _ -> {:ok, :dummy_conn} end)
    |> expect(:open_channel, fn :dummy_conn ->
      send(test_pid, :opened_list_channel1)
      {:ok, :dummy_list_channel}
    end)
    |> expect(:exec, fn :dummy_conn, :dummy_list_channel, "docker ps --format '{{json .}}'" ->
      :ok
    end)
    |> expect(:open_channel, fn :dummy_conn ->
      {:ok, :dummy_server_log_channel}
    end)
    |> expect(:exec, fn :dummy_conn, :dummy_server_log_channel, "tail -F /var/log/messages" ->
      :ok
    end)
    |> expect(:close_channel, fn :dummy_conn, :dummy_server_log_channel ->
      :ok
    end)
    # Then log stream channel open
    |> expect(:open_channel, fn :dummy_conn -> {:ok, :dummy_log_channel} end)
    |> expect(:exec, fn :dummy_conn,
                        :dummy_log_channel,
                        "docker logs --follow --tail 100 container1" ->
      :ok
    end)
    # Reconnect attempt starts:
    |> expect(:connect, fn "10.0.0.2", 22, _ -> {:ok, :dummy_conn2} end)
    |> expect(:open_channel, fn :dummy_conn2 ->
      send(test_pid, :opened_list_channel2)
      {:ok, :dummy_list_channel2}
    end)
    |> expect(:exec, fn :dummy_conn2, :dummy_list_channel2, "docker ps --format '{{json .}}'" ->
      :ok
    end)
    # Expect resuming log streaming on the new connection!
    |> expect(:open_channel, fn :dummy_conn2 ->
      send(test_pid, :resumed_log_channel)
      {:ok, :dummy_log_channel2}
    end)
    |> expect(:exec, fn :dummy_conn2,
                        :dummy_log_channel2,
                        "docker logs --follow --tail 100 container1" ->
      :ok
    end)
    # Cleanup calls
    |> expect(:close_channel, fn :dummy_conn, :dummy_log_channel -> :ok end)
    |> expect(:close_channel, fn :dummy_conn2, :dummy_log_channel2 -> :ok end)
    |> expect(:close, fn :dummy_conn -> :ok end)
    |> expect(:close, fn :dummy_conn2 -> :ok end)

    Phoenix.PubSub.subscribe(Caudata.PubSub, "servers")

    # Start the worker
    {:ok, worker_pid} = start_supervised({ServerWorker, {profile, ssh_client: Mock}})

    # Wait for list channel open
    assert_receive :opened_list_channel1, 1000

    # Simulate container listing completion
    send(
      worker_pid,
      {:ssh_cm, :dummy_conn,
       {:data, :dummy_list_channel, 0, "{\"ID\":\"container1\",\"Names\":\"test-container\"}\n"}}
    )

    send(worker_pid, {:ssh_cm, :dummy_conn, {:closed, :dummy_list_channel}})

    assert_receive {:status_updated, "reconnect-resume-server", :connected}, 1000

    # Start streaming
    assert :ok = GenServer.call(worker_pid, {:stream_container_logs, "container1"})

    # Simulate connection close by SSH manager
    send(worker_pid, {:ssh_cm, :dummy_conn, {:closed, :dummy_conn}})

    # Expect worker to transition to :connecting status broadcast
    assert_receive {:status_updated, "reconnect-resume-server", :connecting}, 1000

    # Wait for the reconnect connection to be established and the list channel to open
    assert_receive :opened_list_channel2, 2000

    # Simulate docker ps output that STILL lists container1
    send(
      worker_pid,
      {:ssh_cm, :dummy_conn2,
       {:data, :dummy_list_channel2, 0, "{\"ID\":\"container1\",\"Names\":\"test-container\"}\n"}}
    )

    send(worker_pid, {:ssh_cm, :dummy_conn2, {:closed, :dummy_list_channel2}})

    # Verify that log streaming was resumed on the new connection
    assert_receive :resumed_log_channel, 1000
    assert_receive {:status_updated, "reconnect-resume-server", :connected}, 2000

    stop_supervised(ServerWorker)
    assert_receive {:status_updated, "reconnect-resume-server", :disconnected}, 1000
  end
end
