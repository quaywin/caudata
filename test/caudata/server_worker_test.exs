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
    stub(Mock, :adjust_window, fn _conn, _chan, _bytes -> :ok end)
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
        port: 2222
      })

    test_pid = self()

    # Expect calls on Mock SSH Client
    Mock
    |> expect(:connect, fn "127.0.0.1",
                           2222,
                           [user: "test-user", identity_file: nil, password: nil] ->
      {:ok, :dummy_conn}
    end)
    |> expect(:open_channel, fn :dummy_conn ->
      send(test_pid, :opened_list_channel)
      {:ok, :dummy_list_channel}
    end)
    |> expect(:exec, fn :dummy_conn, :dummy_list_channel, cmd ->
      assert String.contains?(cmd, "docker ps")
      :ok
    end)
    |> expect(:open_channel, fn :dummy_conn ->
      {:ok, :dummy_log_channel}
    end)
    |> expect(:exec, fn :dummy_conn, :dummy_log_channel, cmd ->
      assert String.contains?(cmd, "docker logs")
      assert String.contains?(cmd, "container1")
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

    assert snapshot == [
             %{message: "line 1", stream: :stdout, timestamp: nil},
             %{message: "part 2", stream: :stdout, timestamp: nil},
             %{message: "line 3", stream: :stdout, timestamp: nil}
           ]

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
    |> expect(:exec, fn :dummy_conn, :dummy_list_channel, cmd ->
      assert String.contains?(cmd, "docker ps")
      :ok
    end)
    # Then log stream channel open
    |> expect(:open_channel, fn :dummy_conn -> {:ok, :dummy_log_channel} end)
    |> expect(:exec, fn :dummy_conn, :dummy_log_channel, cmd ->
      assert String.contains?(cmd, "docker logs")
      :ok
    end)
    # Reconnect attempt starts:
    |> expect(:connect, fn "10.0.0.1", 22, _ -> {:ok, :dummy_conn2} end)
    |> expect(:open_channel, fn :dummy_conn2 ->
      send(test_pid, :opened_list_channel2)
      {:ok, :dummy_list_channel2}
    end)
    |> expect(:exec, fn :dummy_conn2, :dummy_list_channel2, cmd ->
      assert String.contains?(cmd, "docker ps")
      :ok
    end)
    # Cleanup calls
    |> expect(:close_channel, fn :dummy_conn, :dummy_log_channel -> :ok end)
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

  test "voluntary channel closure does not trigger reconnection" do
    profile =
      Profile.new(%{
        host_pattern: "toggle-logs-server",
        host_name: "10.0.0.9",
        user: "root",
        port: 22
      })

    test_pid = self()

    Mock
    # Initial connection sequence
    |> expect(:connect, fn "10.0.0.9", 22, _ -> {:ok, :dummy_conn} end)
    |> expect(:open_channel, fn :dummy_conn ->
      send(test_pid, :opened_list_channel)
      {:ok, :dummy_list_channel}
    end)
    |> expect(:exec, fn :dummy_conn, :dummy_list_channel, cmd ->
      assert String.contains?(cmd, "docker ps")
      :ok
    end)
    # Refresh 1:
    |> expect(:open_channel, fn :dummy_conn ->
      send(test_pid, :opened_list_channel2)
      {:ok, :dummy_list_channel2}
    end)
    |> expect(:exec, fn :dummy_conn, :dummy_list_channel2, cmd ->
      assert String.contains?(cmd, "docker ps")
      :ok
    end)
    # Refresh 2 (closes channel 2, opens channel 3):
    |> expect(:close_channel, fn :dummy_conn, :dummy_list_channel2 ->
      send(test_pid, :closed_list_channel2)
      :ok
    end)
    |> expect(:open_channel, fn :dummy_conn ->
      send(test_pid, :opened_list_channel3)
      {:ok, :dummy_list_channel3}
    end)
    |> expect(:exec, fn :dummy_conn, :dummy_list_channel3, cmd ->
      assert String.contains?(cmd, "docker ps")
      :ok
    end)
    # Terminate:
    |> expect(:close_channel, fn :dummy_conn, :dummy_list_channel3 ->
      :ok
    end)
    |> expect(:close, fn :dummy_conn ->
      :ok
    end)

    Phoenix.PubSub.subscribe(Caudata.PubSub, "servers")

    # Start the worker
    {:ok, worker_pid} = start_supervised({ServerWorker, {profile, ssh_client: Mock}})

    # Consume the initial connecting status
    assert_receive {:status_updated, "toggle-logs-server", :connecting}, 1000

    # Wait for list channel open
    assert_receive :opened_list_channel, 1000

    # Simulate container listing completion (closes list channel)
    send(worker_pid, {:ssh_cm, :dummy_conn, {:closed, :dummy_list_channel}})

    assert_receive {:status_updated, "toggle-logs-server", :connected}, 1000

    # Act: manually trigger refresh_containers, which opens list channel 2
    GenServer.cast(worker_pid, :refresh_containers)
    assert_receive :opened_list_channel2, 1000

    # Act: trigger refresh_containers AGAIN, which calls close_list_channel for :dummy_list_channel2
    GenServer.cast(worker_pid, :refresh_containers)
    assert_receive :closed_list_channel2, 1000
    assert_receive :opened_list_channel3, 1000

    # Send the {:closed, :dummy_list_channel2} message to simulate SSH closed message for the inactive channel
    send(worker_pid, {:ssh_cm, :dummy_conn, {:closed, :dummy_list_channel2}})

    # Assert that we DO NOT receive a transition to :connecting status
    refute_receive {:status_updated, "toggle-logs-server", :connecting}, 1000

    stop_supervised(ServerWorker)
    assert_receive {:status_updated, "toggle-logs-server", :disconnected}, 1000
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
    |> expect(:exec, fn :dummy_conn, :dummy_list_channel, cmd ->
      assert String.contains?(cmd, "docker ps")
      :ok
    end)
    # Then log stream channel open
    |> expect(:open_channel, fn :dummy_conn -> {:ok, :dummy_log_channel} end)
    |> expect(:exec, fn :dummy_conn, :dummy_log_channel, cmd ->
      assert String.contains?(cmd, "docker logs")
      :ok
    end)
    # Reconnect attempt starts:
    |> expect(:connect, fn "10.0.0.2", 22, _ -> {:ok, :dummy_conn2} end)
    |> expect(:open_channel, fn :dummy_conn2 ->
      send(test_pid, :opened_list_channel2)
      {:ok, :dummy_list_channel2}
    end)
    |> expect(:exec, fn :dummy_conn2, :dummy_list_channel2, cmd ->
      assert String.contains?(cmd, "docker ps")
      :ok
    end)
    # Expect resuming log streaming on the new connection!
    |> expect(:open_channel, fn :dummy_conn2 ->
      send(test_pid, :resumed_log_channel)
      {:ok, :dummy_log_channel2}
    end)
    |> expect(:exec, fn :dummy_conn2, :dummy_log_channel2, cmd ->
      assert String.contains?(cmd, "docker logs")
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

  test "validate_path command flow" do
    profile =
      Profile.new(%{
        host_pattern: "validation-server",
        host_name: "10.0.0.3",
        user: "root",
        port: 22
      })

    test_pid = self()

    Mock
    |> expect(:connect, fn "10.0.0.3", 22, _ -> {:ok, :dummy_conn} end)
    |> expect(:open_channel, fn :dummy_conn ->
      send(test_pid, :opened_list_channel)
      {:ok, :dummy_list_channel}
    end)
    |> expect(:exec, fn :dummy_conn, :dummy_list_channel, cmd ->
      assert String.contains?(cmd, "docker ps")
      :ok
    end)
    # Validation channel expectations
    |> expect(:open_channel, fn :dummy_conn ->
      send(test_pid, :val_channel_opened)
      {:ok, :dummy_val_channel}
    end)
    |> expect(:exec, fn :dummy_conn, :dummy_val_channel, cmd ->
      assert String.contains?(cmd, "/var/log/syslog")
      :ok
    end)
    |> expect(:close, fn :dummy_conn ->
      :ok
    end)

    {:ok, worker_pid} = start_supervised({ServerWorker, {profile, ssh_client: Mock}})

    # Complete initial connection
    assert_receive :opened_list_channel, 1000
    send(worker_pid, {:ssh_cm, :dummy_conn, {:closed, :dummy_list_channel}})

    # Now run validation
    task =
      Task.async(fn ->
        GenServer.call(worker_pid, {:validate_path, "/var/log/syslog"}, 1000)
      end)

    assert_receive :val_channel_opened, 1000

    # Simulate data chunk coming from SSH client for validation channel
    send(worker_pid, {:ssh_cm, :dummy_conn, {:data, :dummy_val_channel, 0, "valid\n"}})
    # Simulate channel closure
    send(worker_pid, {:ssh_cm, :dummy_conn, {:closed, :dummy_val_channel}})

    # Assert validation returns :ok
    assert Task.await(task) == :ok

    stop_supervised(ServerWorker)
  end

  test "closes oldest channel when exceeding max_active_streams limit" do
    profile =
      Profile.new(%{
        host_pattern: "limit-test-server",
        host_name: "10.0.0.9",
        user: "root",
        port: 22
      })

    test_pid = self()

    # Stub connect
    Mock
    |> expect(:connect, fn "10.0.0.9", 22, _ -> {:ok, :dummy_conn} end)
    # 1. list channel
    |> expect(:open_channel, fn :dummy_conn ->
      send(test_pid, :opened_list_channel)
      {:ok, :dummy_list_channel}
    end)
    |> expect(:exec, fn :dummy_conn, :dummy_list_channel, cmd ->
      assert String.contains?(cmd, "docker ps")
      :ok
    end)

    # 2. Expect 5 container log channels to be opened in order
    Enum.each(1..5, fn i ->
      ch_id = :"dummy_log_channel_#{i}"

      Mock
      |> expect(:open_channel, fn :dummy_conn -> {:ok, ch_id} end)
      |> expect(:exec, fn :dummy_conn, ^ch_id, _cmd -> :ok end)
    end)

    # 4. Expect closing of the oldest channel (dummy_log_channel_1) when container 6 starts streaming
    Mock
    |> expect(:close_channel, fn :dummy_conn, :dummy_log_channel_1 ->
      send(test_pid, :closed_container_1)
      :ok
    end)

    # Then opening channel for container 6
    Mock
    |> expect(:open_channel, fn :dummy_conn -> {:ok, :dummy_log_channel_6} end)
    |> expect(:exec, fn :dummy_conn, :dummy_log_channel_6, _cmd -> :ok end)

    # General stub for other close_channel calls during termination
    Mock
    |> stub(:close_channel, fn _conn, _chan -> :ok end)
    |> stub(:close, fn _conn -> :ok end)

    {:ok, worker_pid} = start_supervised({ServerWorker, {profile, ssh_client: Mock}})

    # Complete initial connection and container discovery
    assert_receive :opened_list_channel, 1000

    containers_json =
      1..6
      |> Enum.map(fn i ->
        "{\"ID\":\"container#{i}\",\"Names\":\"test-container-#{i}\",\"Image\":\"nginx\",\"Status\":\"Up\"}"
      end)
      |> Enum.join("\n")
      |> Kernel.<>("\n")

    send(worker_pid, {:ssh_cm, :dummy_conn, {:data, :dummy_list_channel, 0, containers_json}})
    send(worker_pid, {:ssh_cm, :dummy_conn, {:closed, :dummy_list_channel}})

    # Wait for status to become connected
    Process.sleep(100)

    # Start streaming logs for first 5 containers
    # Wait a bit between calls to guarantee monotonic time difference
    Enum.each(1..5, fn i ->
      assert :ok = GenServer.call(worker_pid, {:stream_container_logs, "container#{i}"})
      Process.sleep(10)
    end)

    # Verify container 1 is currently streaming
    {:ok, pid1} =
      Caudata.ServerSupervisor.lookup_container_worker("limit-test-server", "container1")

    assert %{streaming?: true} = Caudata.ContainerWorker.get_streaming_status(pid1)

    # Start streaming logs for container 6 - this should trigger closing container 1 logs
    assert :ok = GenServer.call(worker_pid, {:stream_container_logs, "container6"})

    # Check if container 1 logs were closed
    assert_receive :closed_container_1, 1000
    assert %{streaming?: false} = Caudata.ContainerWorker.get_streaming_status(pid1)

    stop_supervised(ServerWorker)
  end

  test "auto-reconnects logs stream when container is rebuilt (docker events)" do
    profile =
      Profile.new(%{
        host_pattern: "rebuild-server",
        host_name: "10.0.0.5",
        user: "root",
        port: 22
      })

    test_pid = self()

    # Mox expectations
    Mock
    |> expect(:connect, fn "10.0.0.5", 22, _ -> {:ok, :dummy_conn} end)
    # 1. Docker ps channel
    |> expect(:open_channel, fn :dummy_conn ->
      send(test_pid, :opened_list_channel)
      {:ok, :dummy_list_channel}
    end)
    |> expect(:exec, fn :dummy_conn, :dummy_list_channel, cmd ->
      assert String.contains?(cmd, "docker ps")
      :ok
    end)
    # 2. Docker events channel (opened after list channel closes)
    |> expect(:open_channel, fn :dummy_conn ->
      send(test_pid, :opened_events_channel)
      {:ok, :dummy_events_channel}
    end)
    |> expect(:exec, fn :dummy_conn, :dummy_events_channel, cmd ->
      assert String.contains?(cmd, "docker events")
      :ok
    end)
    # 3. Stream logs for container1 (initial)
    |> expect(:open_channel, fn :dummy_conn ->
      {:ok, :dummy_log_channel_1}
    end)
    |> expect(:exec, fn :dummy_conn, :dummy_log_channel_1, cmd ->
      assert String.contains?(cmd, "docker logs")
      :ok
    end)
    # 4. Refresh ps channel (the rebuild `start` event triggers a full refresh)
    |> expect(:open_channel, fn :dummy_conn ->
      send(test_pid, :opened_refresh_channel)
      {:ok, :dummy_refresh_channel}
    end)
    |> expect(:exec, fn :dummy_conn, :dummy_refresh_channel, cmd ->
      assert String.contains?(cmd, "docker ps")
      :ok
    end)
    # 5. Stream logs for container2 (resumed by the refresh's closed-list handler)
    |> expect(:open_channel, fn :dummy_conn ->
      send(test_pid, :opened_log_channel_2)
      {:ok, :dummy_log_channel_2}
    end)
    |> expect(:exec, fn :dummy_conn, :dummy_log_channel_2, cmd ->
      assert String.contains?(cmd, "docker logs")
      :ok
    end)
    # 6. Cleanup calls
    |> stub(:close_channel, fn _conn, _chan -> :ok end)
    |> stub(:close, fn _conn -> :ok end)

    # Sub to PubSub
    Phoenix.PubSub.subscribe(Caudata.PubSub, "servers")

    # Start ServerWorker with enable_events: true
    {:ok, worker_pid} =
      start_supervised({ServerWorker, {profile, ssh_client: Mock, enable_events: true}})

    # Wait for connection setup to open list channel
    assert_receive :opened_list_channel, 1000

    # Bootstrap the container list
    send(
      worker_pid,
      {:ssh_cm, :dummy_conn,
       {:data, :dummy_list_channel, 0,
        "{\"ID\":\"container1\",\"Names\":\"test-container\",\"Image\":\"nginx\",\"Status\":\"Up\",\"State\":\"running\"}\n"}}
    )

    send(worker_pid, {:ssh_cm, :dummy_conn, {:closed, :dummy_list_channel}})

    assert_receive {:status_updated, "rebuild-server", :connected}, 1000
    assert_receive :opened_events_channel, 1000

    # Start streaming container1
    assert :ok = GenServer.call(worker_pid, {:stream_container_logs, "container1"})

    # Simulate container1 going down (die -> destroy)
    die_event =
      "{\"status\":\"die\",\"id\":\"container1\",\"Actor\":{\"Attributes\":{\"name\":\"test-container\"}}}\n"

    destroy_event =
      "{\"status\":\"destroy\",\"id\":\"container1\",\"Actor\":{\"Attributes\":{\"name\":\"test-container\"}}}\n"

    send(worker_pid, {:ssh_cm, :dummy_conn, {:data, :dummy_events_channel, 0, die_event}})
    send(worker_pid, {:ssh_cm, :dummy_conn, {:data, :dummy_events_channel, 0, destroy_event}})

    # Wait for status sync
    Process.sleep(50)

    # Now container2 starts (rebuilt). This triggers a full list refresh; the
    # refresh's closed-list handler resumes streaming for the new container id.
    start_event =
      "{\"status\":\"start\",\"id\":\"container2\",\"Actor\":{\"Attributes\":{\"name\":\"test-container\",\"image\":\"nginx\"}}}\n"

    send(worker_pid, {:ssh_cm, :dummy_conn, {:data, :dummy_events_channel, 0, start_event}})

    # Feed the authoritative `docker ps` result (container2 replaces container1)
    assert_receive :opened_refresh_channel, 1000

    refresh_ps =
      "{\"ID\":\"container2\",\"Names\":\"test-container\",\"Image\":\"nginx\",\"Status\":\"Up\",\"State\":\"running\"}\n"

    send(
      worker_pid,
      {:ssh_cm, :dummy_conn, {:data, :dummy_refresh_channel, 0, refresh_ps}}
    )

    send(worker_pid, {:ssh_cm, :dummy_conn, {:closed, :dummy_refresh_channel}})

    # We expect to receive :opened_log_channel_2 as it auto-reconnects logs stream
    assert_receive :opened_log_channel_2, 1000

    # Verify that the active container has been updated to container2 in ServerWorker
    assert ServerWorker.get_containers(worker_pid) |> Enum.find(&(&1.id == "container2"))

    stop_supervised(ServerWorker)
  end

  test "auto-reconnects logs stream when container stops and starts again with same ID (docker events)" do
    profile =
      Profile.new(%{
        host_pattern: "restart-server",
        host_name: "10.0.0.6",
        user: "root",
        port: 22
      })

    test_pid = self()

    # Mox expectations
    Mock
    |> expect(:connect, fn "10.0.0.6", 22, _ -> {:ok, :dummy_conn} end)
    # 1. Docker ps channel
    |> expect(:open_channel, fn :dummy_conn ->
      send(test_pid, :opened_list_channel)
      {:ok, :dummy_list_channel}
    end)
    |> expect(:exec, fn :dummy_conn, :dummy_list_channel, cmd ->
      assert String.contains?(cmd, "docker ps")
      :ok
    end)
    # 2. Docker events channel (opened after list channel closes)
    |> expect(:open_channel, fn :dummy_conn ->
      send(test_pid, :opened_events_channel)
      {:ok, :dummy_events_channel}
    end)
    |> expect(:exec, fn :dummy_conn, :dummy_events_channel, cmd ->
      assert String.contains?(cmd, "docker events")
      :ok
    end)
    # 3. Stream logs for container1 (initial)
    |> expect(:open_channel, fn :dummy_conn ->
      send(test_pid, :opened_log_channel_1)
      {:ok, :dummy_log_channel_1}
    end)
    |> expect(:exec, fn :dummy_conn, :dummy_log_channel_1, cmd ->
      assert String.contains?(cmd, "docker logs")
      :ok
    end)
    # 4. Refresh ps channel (the `start` event triggers a full refresh)
    |> expect(:open_channel, fn :dummy_conn ->
      send(test_pid, :opened_refresh_channel)
      {:ok, :dummy_refresh_channel}
    end)
    |> expect(:exec, fn :dummy_conn, :dummy_refresh_channel, cmd ->
      assert String.contains?(cmd, "docker ps")
      :ok
    end)
    # 5. Stream logs for container1 (resumed by the refresh's closed-list handler)
    |> expect(:open_channel, fn :dummy_conn ->
      send(test_pid, :opened_log_channel_1_again)
      {:ok, :dummy_log_channel_1_again}
    end)
    |> expect(:exec, fn :dummy_conn, :dummy_log_channel_1_again, cmd ->
      assert String.contains?(cmd, "docker logs")
      :ok
    end)
    # 6. Cleanup calls
    |> stub(:close_channel, fn _conn, _chan -> :ok end)
    |> stub(:close, fn _conn -> :ok end)

    # Sub to PubSub
    Phoenix.PubSub.subscribe(Caudata.PubSub, "servers")

    # Start ServerWorker with enable_events: true
    {:ok, worker_pid} =
      start_supervised({ServerWorker, {profile, ssh_client: Mock, enable_events: true}})

    # Wait for connection setup to open list channel
    assert_receive :opened_list_channel, 1000

    # Bootstrap the container list
    send(
      worker_pid,
      {:ssh_cm, :dummy_conn,
       {:data, :dummy_list_channel, 0,
        "{\"ID\":\"container1\",\"Names\":\"test-container\",\"Image\":\"nginx\",\"Status\":\"Up\",\"State\":\"running\"}\n"}}
    )

    send(worker_pid, {:ssh_cm, :dummy_conn, {:closed, :dummy_list_channel}})

    assert_receive {:status_updated, "restart-server", :connected}, 1000
    assert_receive :opened_events_channel, 1000

    # Start streaming container1
    assert :ok = GenServer.call(worker_pid, {:stream_container_logs, "container1"})
    assert_receive :opened_log_channel_1, 1000

    # Simulate container1 stopping (die only, ID remains container1)
    die_event =
      "{\"status\":\"die\",\"id\":\"container1\",\"Actor\":{\"Attributes\":{\"name\":\"test-container\"}}}\n"

    send(worker_pid, {:ssh_cm, :dummy_conn, {:data, :dummy_events_channel, 0, die_event}})

    # Wait for status sync
    Process.sleep(50)

    # Verify container is marked exited
    assert ServerWorker.get_containers(worker_pid)
           |> Enum.find(&(&1.id == "container1" && &1.status == "Exited"))

    # Now container1 starts again (restart). This triggers a full list refresh;
    # the refresh's closed-list handler resumes streaming for container1.
    start_event =
      "{\"status\":\"start\",\"id\":\"container1\",\"Actor\":{\"Attributes\":{\"name\":\"test-container\",\"image\":\"nginx\"}}}\n"

    send(worker_pid, {:ssh_cm, :dummy_conn, {:data, :dummy_events_channel, 0, start_event}})

    # Feed the authoritative `docker ps` result (container1 back to running)
    assert_receive :opened_refresh_channel, 1000

    refresh_ps =
      "{\"ID\":\"container1\",\"Names\":\"test-container\",\"Image\":\"nginx\",\"Status\":\"Up\",\"State\":\"running\"}\n"

    send(
      worker_pid,
      {:ssh_cm, :dummy_conn, {:data, :dummy_refresh_channel, 0, refresh_ps}}
    )

    send(worker_pid, {:ssh_cm, :dummy_conn, {:closed, :dummy_refresh_channel}})

    # We expect to receive :opened_log_channel_1_again as it auto-reconnects logs stream
    assert_receive :opened_log_channel_1_again, 1000

    # Verify that the active container status is back to running
    assert ServerWorker.get_containers(worker_pid)
           |> Enum.find(&(&1.id == "container1" && &1.status == "Up"))

    stop_supervised(ServerWorker)
  end

  test "preserves container ordering and custom logs position during rebuild and new additions" do
    profile =
      Profile.new(%{
        id: "order-test-server",
        host_pattern: "order-server",
        host_name: "10.0.0.10",
        user: "root",
        port: 22,
        custom_logs: ["/var/log/app.log"]
      })

    test_pid = self()

    Mock
    |> expect(:connect, fn "10.0.0.10", 22, _ -> {:ok, :dummy_conn} end)
    # Docker ps channel (initial discovery)
    |> expect(:open_channel, fn :dummy_conn ->
      send(test_pid, :opened_list_channel)
      {:ok, :dummy_list_channel}
    end)
    |> expect(:exec, fn :dummy_conn, :dummy_list_channel, cmd ->
      assert String.contains?(cmd, "docker ps")
      :ok
    end)
    # Docker events channel
    |> expect(:open_channel, fn :dummy_conn ->
      send(test_pid, :opened_events_channel)
      {:ok, :dummy_events_channel}
    end)
    |> expect(:exec, fn :dummy_conn, :dummy_events_channel, cmd ->
      assert String.contains?(cmd, "docker events")
      :ok
    end)
    # Refresh ps channel (triggered by the rebuild `start` event)
    |> expect(:open_channel, fn :dummy_conn ->
      send(test_pid, :opened_refresh_channel_1)
      {:ok, :dummy_refresh_channel_1}
    end)
    |> expect(:exec, fn :dummy_conn, :dummy_refresh_channel_1, cmd ->
      assert String.contains?(cmd, "docker ps")
      :ok
    end)
    # Refresh ps channel (triggered by the new-container `start` event)
    |> expect(:open_channel, fn :dummy_conn ->
      send(test_pid, :opened_refresh_channel_2)
      {:ok, :dummy_refresh_channel_2}
    end)
    |> expect(:exec, fn :dummy_conn, :dummy_refresh_channel_2, cmd ->
      assert String.contains?(cmd, "docker ps")
      :ok
    end)
    |> stub(:close_channel, fn _conn, _chan -> :ok end)
    |> stub(:close, fn _conn -> :ok end)

    # Subscribe to status changes
    Phoenix.PubSub.subscribe(Caudata.PubSub, "servers")

    # Start the worker with the Mock client and enable_events
    {:ok, worker_pid} =
      start_supervised({ServerWorker, {profile, ssh_client: Mock, enable_events: true}})

    assert_receive :opened_list_channel, 1000

    # 1. Bootstrap: send two docker containers
    containers_json =
      "{\"ID\":\"c1\",\"Names\":\"web-container\",\"Image\":\"nginx\",\"Status\":\"Up\",\"State\":\"running\"}\n" <>
        "{\"ID\":\"c2\",\"Names\":\"db-container\",\"Image\":\"postgres\",\"Status\":\"Up\",\"State\":\"running\"}\n"

    send(
      worker_pid,
      {:ssh_cm, :dummy_conn, {:data, :dummy_list_channel, 0, containers_json}}
    )

    send(worker_pid, {:ssh_cm, :dummy_conn, {:closed, :dummy_list_channel}})

    assert_receive {:status_updated, "order-test-server", :connected}, 1000
    assert_receive :opened_events_channel, 1000

    # Verify initial containers list: sorted alphabetically (db-container, web-container), then file logs
    initial_conts = ServerWorker.get_containers(worker_pid)
    assert length(initial_conts) == 3
    assert Enum.at(initial_conts, 0).id == "c2"
    assert Enum.at(initial_conts, 0).name == "db-container"
    assert Enum.at(initial_conts, 1).id == "c1"
    assert Enum.at(initial_conts, 1).name == "web-container"
    assert Enum.at(initial_conts, 2).id == "file:/var/log/app.log"
    assert Enum.at(initial_conts, 2).name == "/var/log/app.log"

    # 2. Simulate rebuilding: c1 (web-container) dies and is destroyed
    die_event =
      "{\"status\":\"die\",\"id\":\"c1\",\"Actor\":{\"Attributes\":{\"name\":\"web-container\"}}}\n"

    destroy_event =
      "{\"status\":\"destroy\",\"id\":\"c1\",\"Actor\":{\"Attributes\":{\"name\":\"web-container\"}}}\n"

    send(worker_pid, {:ssh_cm, :dummy_conn, {:data, :dummy_events_channel, 0, die_event}})
    send(worker_pid, {:ssh_cm, :dummy_conn, {:data, :dummy_events_channel, 0, destroy_event}})

    Process.sleep(50)

    # Rebuilt container start: web-container gets new ID c3. This triggers a
    # full list refresh, so we feed back the authoritative `docker ps` output.
    start_event =
      "{\"status\":\"start\",\"id\":\"c3\",\"Actor\":{\"Attributes\":{\"name\":\"web-container\",\"image\":\"nginx\"}}}\n"

    send(worker_pid, {:ssh_cm, :dummy_conn, {:data, :dummy_events_channel, 0, start_event}})

    assert_receive :opened_refresh_channel_1, 1000

    rebuilt_ps =
      "{\"ID\":\"c3\",\"Names\":\"web-container\",\"Image\":\"nginx\",\"Status\":\"Up\",\"State\":\"running\"}\n" <>
        "{\"ID\":\"c2\",\"Names\":\"db-container\",\"Image\":\"postgres\",\"Status\":\"Up\",\"State\":\"running\"}\n"

    send(
      worker_pid,
      {:ssh_cm, :dummy_conn, {:data, :dummy_refresh_channel_1, 0, rebuilt_ps}}
    )

    send(worker_pid, {:ssh_cm, :dummy_conn, {:closed, :dummy_refresh_channel_1}})

    Process.sleep(50)

    # Verify that the order is sorted alphabetically: db-container (c2) at Index 0, web-container (now c3) at Index 1, and log file at Index 2
    rebuilt_conts = ServerWorker.get_containers(worker_pid)
    assert length(rebuilt_conts) == 3
    assert Enum.at(rebuilt_conts, 0).id == "c2"
    assert Enum.at(rebuilt_conts, 0).name == "db-container"
    assert Enum.at(rebuilt_conts, 1).id == "c3"
    assert Enum.at(rebuilt_conts, 1).name == "web-container"
    assert Enum.at(rebuilt_conts, 2).id == "file:/var/log/app.log"

    # 3. Add a new container: mail-container (c4) starts. Again triggers a refresh.
    new_start_event =
      "{\"status\":\"start\",\"id\":\"c4\",\"Actor\":{\"Attributes\":{\"name\":\"mail-container\",\"image\":\"mail\"}}}\n"

    send(
      worker_pid,
      {:ssh_cm, :dummy_conn, {:data, :dummy_events_channel, 0, new_start_event}}
    )

    assert_receive :opened_refresh_channel_2, 1000

    final_ps =
      rebuilt_ps <>
        "{\"ID\":\"c4\",\"Names\":\"mail-container\",\"Image\":\"mail\",\"Status\":\"Up\",\"State\":\"running\"}\n"

    send(
      worker_pid,
      {:ssh_cm, :dummy_conn, {:data, :dummy_refresh_channel_2, 0, final_ps}}
    )

    send(worker_pid, {:ssh_cm, :dummy_conn, {:closed, :dummy_refresh_channel_2}})

    Process.sleep(50)

    # Verify that the containers are sorted alphabetically: db-container, mail-container, web-container, and custom log file at the bottom
    final_conts = ServerWorker.get_containers(worker_pid)
    assert length(final_conts) == 4
    assert Enum.at(final_conts, 0).name == "db-container"
    assert Enum.at(final_conts, 1).name == "mail-container"
    assert Enum.at(final_conts, 1).id == "c4"
    assert Enum.at(final_conts, 2).name == "web-container"
    assert Enum.at(final_conts, 2).id == "c3"
    assert Enum.at(final_conts, 3).id == "file:/var/log/app.log"

    stop_supervised(ServerWorker)
  end

  test "refreshing containers does not inject nil cpu_text/ram_text" do
    # Regression: sync_container_workers preserved cpu_text/ram_text via
    # Map.put(:cpu_text, Map.get(old_c, :cpu_text)), which injects `cpu_text: nil`
    # (key present, value nil) when the old container had no metrics yet. That
    # nil then crashed the info pane (Span.new/2 rejects nil) after every rebuild.
    profile =
      Profile.new(%{
        id: "metrics-regression-server",
        host_pattern: "metrics-regression",
        host_name: "10.0.0.20",
        user: "root",
        port: 22
      })

    test_pid = self()

    Mock
    |> expect(:connect, fn "10.0.0.20", 22, _ -> {:ok, :dummy_conn} end)
    # Initial docker ps channel
    |> expect(:open_channel, fn :dummy_conn ->
      send(test_pid, :opened_list_channel)
      {:ok, :dummy_list_channel}
    end)
    |> expect(:exec, fn :dummy_conn, :dummy_list_channel, cmd ->
      assert String.contains?(cmd, "docker ps")
      :ok
    end)
    # Docker events channel
    |> expect(:open_channel, fn :dummy_conn ->
      send(test_pid, :opened_events_channel)
      {:ok, :dummy_events_channel}
    end)
    |> expect(:exec, fn :dummy_conn, :dummy_events_channel, cmd ->
      assert String.contains?(cmd, "docker events")
      :ok
    end)
    # Refresh ps channel (triggered by the rebuild `start` event)
    |> expect(:open_channel, fn :dummy_conn ->
      send(test_pid, :opened_refresh_channel)
      {:ok, :dummy_refresh_channel}
    end)
    |> expect(:exec, fn :dummy_conn, :dummy_refresh_channel, cmd ->
      assert String.contains?(cmd, "docker ps")
      :ok
    end)
    |> stub(:close_channel, fn _conn, _chan -> :ok end)
    |> stub(:close, fn _conn -> :ok end)

    Phoenix.PubSub.subscribe(Caudata.PubSub, "servers")

    {:ok, worker_pid} =
      start_supervised({ServerWorker, {profile, ssh_client: Mock, enable_events: true}})

    assert_receive :opened_list_channel, 1000

    # Bootstrap with a single container (no metrics, so no cpu_text/ram_text yet)
    bootstrap_ps =
      "{\"ID\":\"c1\",\"Names\":\"web\",\"Image\":\"nginx\",\"Status\":\"Up\",\"State\":\"running\"}\n"

    send(worker_pid, {:ssh_cm, :dummy_conn, {:data, :dummy_list_channel, 0, bootstrap_ps}})
    send(worker_pid, {:ssh_cm, :dummy_conn, {:closed, :dummy_list_channel}})

    assert_receive {:status_updated, "metrics-regression-server", :connected}, 1000
    assert_receive :opened_events_channel, 1000

    [initial] = ServerWorker.get_containers(worker_pid)
    refute Map.has_key?(initial, :cpu_text)
    refute Map.has_key?(initial, :ram_text)

    # A start event triggers a full refresh. Feed back the same container.
    start_event =
      "{\"status\":\"start\",\"id\":\"c1\",\"Actor\":{\"Attributes\":{\"name\":\"web\",\"image\":\"nginx\"}}}\n"

    send(worker_pid, {:ssh_cm, :dummy_conn, {:data, :dummy_events_channel, 0, start_event}})
    assert_receive :opened_refresh_channel, 1000

    send(worker_pid, {:ssh_cm, :dummy_conn, {:data, :dummy_refresh_channel, 0, bootstrap_ps}})
    send(worker_pid, {:ssh_cm, :dummy_conn, {:closed, :dummy_refresh_channel}})

    Process.sleep(50)

    # After the refresh, cpu_text/ram_text must NOT be injected as nil keys.
    [refreshed] = ServerWorker.get_containers(worker_pid)

    refute Map.has_key?(refreshed, :cpu_text),
           "refresh must not inject cpu_text: nil (crashes the info pane)"

    refute Map.has_key?(refreshed, :ram_text),
           "refresh must not inject ram_text: nil (crashes the info pane)"

    stop_supervised(ServerWorker)
  end

  test "macOS/Linux metrics line parsing and broadcasting" do
    profile =
      Profile.new(%{
        id: "metrics-test-server",
        host_pattern: "metrics-test",
        host_name: "10.0.0.30",
        user: "root",
        port: 22
      })

    test_pid = self()

    Mock
    |> expect(:connect, fn "10.0.0.30", 22, _ -> {:ok, :dummy_conn} end)
    # Container list channel
    |> expect(:open_channel, fn :dummy_conn ->
      send(test_pid, :opened_list_channel)
      {:ok, :dummy_list_channel}
    end)
    |> expect(:exec, fn :dummy_conn, :dummy_list_channel, _cmd ->
      :ok
    end)
    # Metrics channel
    |> expect(:open_channel, fn :dummy_conn ->
      send(test_pid, :opened_metrics_channel)
      {:ok, :dummy_metrics_channel}
    end)
    |> expect(:exec, fn :dummy_conn, :dummy_metrics_channel, cmd ->
      assert String.contains?(cmd, "METRICS:")
      assert String.contains?(cmd, "is_darwin")
      :ok
    end)
    |> stub(:close_channel, fn _conn, _chan -> :ok end)
    |> stub(:close, fn _conn -> :ok end)

    Phoenix.PubSub.subscribe(Caudata.PubSub, "servers")

    {:ok, worker_pid} =
      start_supervised(
        {ServerWorker, {profile, ssh_client: Mock, enable_metrics: true, enable_events: false}}
      )

    assert_receive :opened_list_channel, 1000
    send(worker_pid, {:ssh_cm, :dummy_conn, {:closed, :dummy_list_channel}})

    assert_receive :opened_metrics_channel, 1000

    metrics_data = "METRICS: 15 50 8388608 4194304 104857600 20971520 20\n"

    send(
      worker_pid,
      {:ssh_cm, :dummy_conn, {:data, :dummy_metrics_channel, 0, metrics_data}}
    )

    expected_metrics = {15, 50, 4.0, 8.0, 20, 20.0, 100}

    assert_receive {:metrics_updated, "metrics-test-server", ^expected_metrics}, 1000

    stop_supervised(ServerWorker)
  end

  test "successful discovery of systemd and launchd services" do
    profile =
      Profile.new(%{
        host_pattern: "service-test-server",
        host_name: "127.0.0.1",
        user: "test-user",
        port: 2222
      })

    test_pid = self()

    Mock
    |> expect(:connect, fn "127.0.0.1", 2222, _ -> {:ok, :dummy_conn} end)
    |> expect(:open_channel, fn :dummy_conn ->
      send(test_pid, :opened_list_channel)
      {:ok, :dummy_list_channel}
    end)
    |> expect(:exec, fn :dummy_conn, :dummy_list_channel, _cmd -> :ok end)
    |> expect(:close, fn :dummy_conn -> :ok end)

    Phoenix.PubSub.subscribe(Caudata.PubSub, "servers")

    {:ok, worker_pid} =
      start_supervised(
        {ServerWorker, {profile, ssh_client: Mock, enable_metrics: false, enable_events: false}}
      )

    assert_receive :opened_list_channel, 1000

    # Simulate discovery output chunk
    chunk = """
    ===DOCKER===
    {"ID":"container1","Names":"test-container","Image":"nginx","Status":"Up"}
    ===OS===
    Linux
    ===SYSTEMD===
    nginx.service loaded active running nginx server
    ssh.service loaded active running ssh daemon
    ===LAUNCHD===
    - 0 com.apple.Finder
    """

    send(
      worker_pid,
      {:ssh_cm, :dummy_conn, {:data, :dummy_list_channel, 0, chunk}}
    )

    send(worker_pid, {:ssh_cm, :dummy_conn, {:closed, :dummy_list_channel}})

    assert_receive {:status_updated, "service-test-server", :connected}, 1000

    containers = ServerWorker.get_containers(worker_pid)

    # Check that it parsed both docker containers and systemd/launchd services
    assert Enum.any?(containers, &(&1.id == "container1" && &1.image == "nginx"))
    assert Enum.any?(containers, &(&1.id == "systemd:nginx.service" && &1.image == "systemd"))
    assert Enum.any?(containers, &(&1.id == "systemd:ssh.service" && &1.image == "systemd"))
    assert Enum.any?(containers, &(&1.id == "launchd:com.apple.Finder" && &1.image == "launchd"))

    # Verify sorting order: Docker containers first, then services
    assert length(containers) == 4
    assert Enum.at(containers, 0).id == "container1"
    assert Enum.at(containers, 1).id == "launchd:com.apple.Finder"
    assert Enum.at(containers, 2).id == "systemd:nginx.service"
    assert Enum.at(containers, 3).id == "systemd:ssh.service"

    stop_supervised(ServerWorker)
  end

  test "container-specific stats streaming, parsing, and debouncing" do
    profile =
      Profile.new(%{
        id: "container-stats-test-server",
        host_pattern: "stats-test",
        host_name: "10.0.0.40",
        user: "root",
        port: 22
      })

    test_pid = self()
    {:ok, counter_pid} = Agent.start_link(fn -> 0 end)

    # Mox expectations
    Mock
    |> expect(:connect, fn "10.0.0.40", 22, _ -> {:ok, :dummy_conn} end)
    |> stub(:open_channel, fn :dummy_conn ->
      channel =
        Agent.get_and_update(counter_pid, fn count ->
          channel =
            case count do
              0 -> :dummy_list_channel
              1 -> :dummy_metrics_channel
              2 -> :dummy_log_channel
              3 -> :dummy_stats_channel
              _ -> :dummy_other_channel
            end

          {channel, count + 1}
        end)

      {:ok, channel}
    end)
    |> stub(:exec, fn :dummy_conn, _chan_id, cmd ->
      cond do
        String.contains?(cmd, "docker ps") ->
          send(test_pid, :opened_list_channel)
          :ok

        String.contains?(cmd, "docker stats") ->
          send(test_pid, :opened_stats_channel)
          :ok

        String.contains?(cmd, "METRICS:") ->
          send(test_pid, :opened_metrics_channel)
          :ok

        String.contains?(cmd, "docker logs") ->
          send(test_pid, :opened_log_channel)
          :ok

        true ->
          :ok
      end
    end)
    # Cleanup stubs
    |> stub(:close_channel, fn _conn, _chan -> :ok end)
    |> stub(:close, fn _conn -> :ok end)

    Phoenix.PubSub.subscribe(Caudata.PubSub, "servers")

    # Start worker with enable_metrics: true, and custom debounce delays for test
    {:ok, worker_pid} =
      start_supervised(
        {ServerWorker,
         {profile,
          ssh_client: Mock,
          enable_metrics: true,
          enable_events: false,
          log_debounce_delay: 300,
          stats_debounce_delay: 300}}
      )

    assert_receive :opened_list_channel, 1000

    # Bootstrap the container list with 1 container
    bootstrap_ps =
      "{\"ID\":\"container1\",\"Names\":\"web\",\"Image\":\"nginx\",\"Status\":\"Up\",\"State\":\"running\"}\n"

    send(worker_pid, {:ssh_cm, :dummy_conn, {:data, :dummy_list_channel, 0, bootstrap_ps}})
    send(worker_pid, {:ssh_cm, :dummy_conn, {:closed, :dummy_list_channel}})

    assert_receive {:status_updated, "container-stats-test-server", :connected}, 1000
    assert_receive :opened_metrics_channel, 1000
    assert_receive {:containers_updated, "container-stats-test-server", _}, 1000

    # Initially stats_channel should NOT be opened since no active container is set
    refute_receive :opened_stats_channel, 200

    # Select container1
    assert :ok = GenServer.call(worker_pid, {:stream_container_logs, "container1"})

    # Wait for debounce timer (300ms) to fire and open the stats channel
    assert_receive :opened_stats_channel, 1000

    # Get the actual stats channel ID from the worker state
    worker_state = :sys.get_state(worker_pid)
    stats_channel = worker_state.container_stats_channel_id

    # Send container stats data chunk via stats channel
    stats_data = "CONTAINER_METRICS: container1 25.5% 512MiB / 4GiB\n"

    send(
      worker_pid,
      {:ssh_cm, :dummy_conn, {:data, stats_channel, 0, stats_data}}
    )

    # Verify that containers updated message is broadcast and container is updated in ServerWorker
    assert_receive {:containers_updated, "container-stats-test-server", updated_containers}, 1000
    c1 = Enum.find(updated_containers, &(&1.id == "container1"))
    assert c1.cpu_text == "25.5%"
    assert c1.ram_text == "512MiB / 4GiB"

    stop_supervised(ServerWorker)
  end

  test "exec_container_action executes docker command and returns result" do
    profile = Profile.new(%{"id" => "action-test-server", "host_name" => "10.0.0.99", "host_pattern" => "action-test-server", "port" => 22, "user" => "root"})
    test_pid = self()

    Mock
    |> expect(:connect, fn "10.0.0.99", 22, _opts -> {:ok, :dummy_conn} end)
    |> expect(:open_channel, fn :dummy_conn ->
      send(test_pid, :opened_list_channel)
      {:ok, :dummy_list_channel}
    end)
    |> expect(:exec, fn :dummy_conn, :dummy_list_channel, cmd ->
      assert String.contains?(cmd, "docker ps -a")
      :ok
    end)
    |> expect(:open_channel, fn :dummy_conn ->
      send(test_pid, :opened_action_channel)
      {:ok, :dummy_action_channel}
    end)
    |> expect(:exec, fn :dummy_conn, :dummy_action_channel, cmd ->
      assert String.contains?(cmd, "docker stop")
      :ok
    end)
    |> stub(:open_channel, fn _conn -> {:ok, :dummy_channel} end)
    |> stub(:exec, fn _conn, _chan, _cmd -> :ok end)
    |> stub(:close_channel, fn _conn, _chan -> :ok end)
    |> stub(:close, fn _conn -> :ok end)

    {:ok, worker_pid} =
      start_supervised({ServerWorker, {profile, ssh_client: Mock, enable_events: false}})

    assert_receive :opened_list_channel, 1000

    task =
      Task.async(fn ->
        ServerWorker.exec_container_action(worker_pid, :stop, "c1")
      end)

    assert_receive :opened_action_channel, 1000

    send(worker_pid, {:ssh_cm, :dummy_conn, {:data, :dummy_action_channel, 0, "c1\n"}})
    send(worker_pid, {:ssh_cm, :dummy_conn, {:closed, :dummy_action_channel}})

    res = Task.await(task)
    assert res == {:ok, "c1"}

    stop_supervised(ServerWorker)
  end

  test "recovers and reconnects when SSH connect fails with timeout" do
    profile =
      Profile.new(%{
        host_pattern: "conn-fail-server",
        host_name: "10.0.0.89",
        user: "root",
        port: 22
      })

    test_pid = self()

    # First connect fails with :timeout
    Mock
    |> expect(:connect, fn "10.0.0.89", 22, _ ->
      send(test_pid, :first_connect_failed)
      {:error, :timeout}
    end)
    # Second connect succeeds
    |> expect(:connect, fn "10.0.0.89", 22, _ ->
      send(test_pid, :second_connect_succeeded)
      {:ok, :dummy_conn2}
    end)
    |> stub(:open_channel, fn _conn -> {:ok, :dummy_chan} end)
    |> stub(:exec, fn _conn, _chan, _cmd -> :ok end)
    |> stub(:close_channel, fn _conn, _chan -> :ok end)
    |> stub(:close, fn _conn -> :ok end)

    Phoenix.PubSub.subscribe(Caudata.PubSub, "servers")

    {:ok, _worker_pid} =
      start_supervised({ServerWorker, {profile, ssh_client: Mock, enable_events: false}})

    assert_receive :first_connect_failed, 1000
    assert_receive {:status_updated, "conn-fail-server", :connecting}, 1000
    assert_receive :second_connect_succeeded, 2500

    stop_supervised(ServerWorker)
  end

  test "Native SSHClient connects without invalid option errors" do
    # When connecting to a closed port, it should return a connection/network error, NOT {:error, {:options, ...}}
    result =
      Caudata.SSHClient.Native.connect("127.0.0.1", 59999,
        user: "testuser",
        password: "testpassword"
      )

    case result do
      {:error, {:options, _}} ->
        flunk("Native.connect passed invalid options to :ssh.connect: #{inspect(result)}")

      {:error, _network_reason} ->
        :ok

      {:ok, conn} ->
        Caudata.SSHClient.Native.close(conn)
        :ok
    end
  end
end
