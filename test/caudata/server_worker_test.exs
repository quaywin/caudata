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
    |> expect(:exec, fn :dummy_conn, :dummy_list_channel, "docker ps --format '{{json .}}'" ->
      :ok
    end)
    |> expect(:open_channel, fn :dummy_conn ->
      {:ok, :dummy_log_channel}
    end)
    |> expect(:exec, fn :dummy_conn,
                        :dummy_log_channel,
                        "sh -c 'docker logs -t --follow --tail 1000 container1 & pid=$!; trap \"kill $pid 2>/dev/null\" EXIT HUP INT TERM; read -r _; kill $pid 2>/dev/null'" ->
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
    |> expect(:exec, fn :dummy_conn, :dummy_list_channel, "docker ps --format '{{json .}}'" ->
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
    |> expect(:exec, fn :dummy_conn2, :dummy_list_channel2, "docker ps --format '{{json .}}'" ->
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
    |> expect(:exec, fn :dummy_conn, :dummy_list_channel, "docker ps --format '{{json .}}'" ->
      :ok
    end)
    # Refresh 1:
    |> expect(:open_channel, fn :dummy_conn ->
      send(test_pid, :opened_list_channel2)
      {:ok, :dummy_list_channel2}
    end)
    |> expect(:exec, fn :dummy_conn, :dummy_list_channel2, "docker ps --format '{{json .}}'" ->
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
    |> expect(:exec, fn :dummy_conn, :dummy_list_channel3, "docker ps --format '{{json .}}'" ->
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
    |> expect(:exec, fn :dummy_conn, :dummy_list_channel, "docker ps --format '{{json .}}'" ->
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
    |> expect(:exec, fn :dummy_conn2, :dummy_list_channel2, "docker ps --format '{{json .}}'" ->
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
    |> expect(:exec, fn :dummy_conn, :dummy_list_channel, "docker ps --format '{{json .}}'" ->
      :ok
    end)
    # Validation channel expectations
    |> expect(:open_channel, fn :dummy_conn ->
      send(test_pid, :val_channel_opened)
      {:ok, :dummy_val_channel}
    end)
    |> expect(:exec, fn :dummy_conn,
                        :dummy_val_channel,
                        "if [ -r \"/var/log/syslog\" ]; then echo \"valid\"; else echo \"invalid\"; fi" ->
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
    |> expect(:exec, fn :dummy_conn, :dummy_list_channel, "docker ps --format '{{json .}}'" ->
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
    |> expect(:exec, fn :dummy_conn, :dummy_list_channel, "docker ps --format '{{json .}}'" ->
      :ok
    end)
    # 2. Docker events channel (opened after list channel closes)
    |> expect(:open_channel, fn :dummy_conn ->
      send(test_pid, :opened_events_channel)
      {:ok, :dummy_events_channel}
    end)
    |> expect(:exec, fn :dummy_conn, :dummy_events_channel, cmd ->
      assert String.starts_with?(cmd, "docker events")
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
    # 4. Stream logs for container2 (after rebuild)
    |> expect(:open_channel, fn :dummy_conn ->
      send(test_pid, :opened_log_channel_2)
      {:ok, :dummy_log_channel_2}
    end)
    |> expect(:exec, fn :dummy_conn, :dummy_log_channel_2, cmd ->
      assert String.contains?(cmd, "docker logs")
      :ok
    end)
    # 5. Cleanup calls
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

    # Now container2 starts (rebuilt)
    start_event =
      "{\"status\":\"start\",\"id\":\"container2\",\"Actor\":{\"Attributes\":{\"name\":\"test-container\",\"image\":\"nginx\"}}}\n"

    send(worker_pid, {:ssh_cm, :dummy_conn, {:data, :dummy_events_channel, 0, start_event}})

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
    |> expect(:exec, fn :dummy_conn, :dummy_list_channel, "docker ps --format '{{json .}}'" ->
      :ok
    end)
    # 2. Docker events channel (opened after list channel closes)
    |> expect(:open_channel, fn :dummy_conn ->
      send(test_pid, :opened_events_channel)
      {:ok, :dummy_events_channel}
    end)
    |> expect(:exec, fn :dummy_conn, :dummy_events_channel, cmd ->
      assert String.starts_with?(cmd, "docker events")
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
    # 4. Stream logs for container1 (after restart, same ID)
    |> expect(:open_channel, fn :dummy_conn ->
      send(test_pid, :opened_log_channel_1_again)
      {:ok, :dummy_log_channel_1_again}
    end)
    |> expect(:exec, fn :dummy_conn, :dummy_log_channel_1_again, cmd ->
      assert String.contains?(cmd, "docker logs")
      :ok
    end)
    # 5. Cleanup calls
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

    # Now container1 starts again (restart)
    start_event =
      "{\"status\":\"start\",\"id\":\"container1\",\"Actor\":{\"Attributes\":{\"name\":\"test-container\",\"image\":\"nginx\"}}}\n"

    send(worker_pid, {:ssh_cm, :dummy_conn, {:data, :dummy_events_channel, 0, start_event}})

    # We expect to receive :opened_log_channel_1_again as it auto-reconnects logs stream
    assert_receive :opened_log_channel_1_again, 1000

    # Verify that the active container status is back to running
    assert ServerWorker.get_containers(worker_pid)
           |> Enum.find(&(&1.id == "container1" && &1.status == "Up"))

    stop_supervised(ServerWorker)
  end
end
