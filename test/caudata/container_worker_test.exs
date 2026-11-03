defmodule Caudata.ContainerWorkerTest do
  use ExUnit.Case, async: false
  import Mox
  alias Caudata.ContainerWorker
  alias Caudata.LogStore
  alias Caudata.SSHClient.Mock

  setup :verify_on_exit!

  setup do
    set_mox_global()
    stub(Mock, :adjust_window, fn _conn, _chan, _bytes -> :ok end)
    Caudata.LogStore.clear_logs("my-server/container123")
    :ok
  end

  test "lifecycle of ContainerWorker: info updates, streaming, logs ingestion, and stop" do
    container = %{
      id: "container123",
      name: "my-nginx",
      image: "nginx:latest",
      status: "Up 3 hours",
      state: "running"
    }

    # Expect calls on Mock SSH Client
    Mock
    |> expect(:open_channel, fn :dummy_conn ->
      {:ok, :dummy_channel}
    end)
    |> expect(:exec, fn :dummy_conn, :dummy_channel, cmd ->
      assert String.contains?(cmd, "docker logs")
      assert String.contains?(cmd, "container123")
      :ok
    end)
    |> expect(:close_channel, fn :dummy_conn, :dummy_channel ->
      :ok
    end)

    # Start ContainerWorker
    opts = [ssh_client: Mock]
    {:ok, pid} = start_supervised({ContainerWorker, {"my-server", container, opts}})

    # Test get_info
    assert ContainerWorker.get_info(pid) == %{
             id: "container123",
             name: "my-nginx",
             image: "nginx:latest",
             status: "Up 3 hours",
             state: "running"
           }

    # Test update_container_info
    updated_container = %{
      id: "container123",
      name: "my-nginx-updated",
      image: "nginx:alpine",
      status: "Up 4 hours",
      state: "running"
    }

    ContainerWorker.update_container_info(pid, updated_container)
    Process.sleep(20)

    assert ContainerWorker.get_info(pid) == %{
             id: "container123",
             name: "my-nginx-updated",
             image: "nginx:alpine",
             status: "Up 4 hours",
             state: "running"
           }

    # Test start_streaming
    assert :ok = ContainerWorker.start_streaming(pid, :dummy_conn)
    stream_pid = ContainerWorker.get_stream_channel(pid)

    # Subscribe to LogStore updates
    Phoenix.PubSub.subscribe(Caudata.PubSub, "logs:my-server/container123")

    # Simulate receiving incoming data chunk split across packets
    send(stream_pid, {:ssh_cm, :dummy_conn, {:data, :dummy_channel, 0, "log line 1\nlog line"}})
    send(stream_pid, {:ssh_cm, :dummy_conn, {:data, :dummy_channel, 0, " 2\n"}})

    # Expect log updates in LogStore
    assert_receive {:logs_updated, "my-server/container123", _}, 1000

    Process.sleep(50)
    snapshot = LogStore.get_snapshot("my-server/container123")

    assert snapshot == [
             %{timestamp: nil, stream: :stdout, message: "log line 1"},
             %{timestamp: nil, stream: :stdout, message: "log line 2"}
           ]

    # Test stop_streaming
    assert :ok = ContainerWorker.stop_streaming(pid)

    stop_supervised(ContainerWorker)
  end

  test "handles SSH disconnect and broadcasts PubSub message" do
    container = %{
      id: "container123",
      name: "my-nginx",
      image: "nginx:latest",
      status: "Up 3 hours",
      state: "running"
    }

    Mock
    |> expect(:open_channel, fn :dummy_conn ->
      {:ok, :dummy_channel}
    end)
    |> expect(:exec, fn :dummy_conn, :dummy_channel, cmd ->
      assert String.contains?(cmd, "docker logs")
      assert String.contains?(cmd, "container123")
      :ok
    end)
    |> expect(:close_channel, fn :dummy_conn, :dummy_channel ->
      :ok
    end)

    opts = [ssh_client: Mock]
    {:ok, pid} = start_supervised({ContainerWorker, {"my-server", container, opts}})

    assert :ok = ContainerWorker.start_streaming(pid, :dummy_conn)
    stream_pid = ContainerWorker.get_stream_channel(pid)

    # Subscribe to container logs disconnect topic
    Phoenix.PubSub.subscribe(Caudata.PubSub, "container_logs:my-server/container123")

    # Simulate channel closure from remote end
    send(stream_pid, {:ssh_cm, :dummy_conn, {:closed, :dummy_channel}})

    # Verify that container logs disconnect notification was broadcast
    assert_receive {:container_log_disconnected, "my-server", "container123", "Channel closed"},
                   1000

    stop_supervised(ContainerWorker)
  end

  test "concurrent stdout and stderr logs are stored in chronological receipt order" do
    container = %{
      id: "container123",
      name: "my-nginx",
      image: "nginx:latest",
      status: "Up 3 hours",
      state: "running"
    }

    # Clear logs to avoid leak
    Caudata.LogStore.clear_logs("my-server/container123")

    Mock
    |> expect(:open_channel, fn :dummy_conn ->
      {:ok, :dummy_channel}
    end)
    |> expect(:exec, fn :dummy_conn, :dummy_channel, cmd ->
      assert String.contains?(cmd, "docker logs -t")
      :ok
    end)
    |> expect(:close_channel, fn :dummy_conn, :dummy_channel ->
      :ok
    end)

    opts = [ssh_client: Mock, target_capacity: 1000]
    {:ok, pid} = start_supervised({ContainerWorker, {"my-server", container, opts}})

    assert :ok = ContainerWorker.start_streaming(pid, :dummy_conn)
    stream_pid = ContainerWorker.get_stream_channel(pid)

    # Subscribe to LogStore updates
    Phoenix.PubSub.subscribe(Caudata.PubSub, "logs:my-server/container123")

    # Simulate interleaved stdout (stream 0) and stderr (stream 1) chunks with ISO 8601 timestamps
    # Notice that stderr is received FIRST, but its timestamp is LATER (T12:00:01)
    # stdout is received SECOND, but its timestamp is EARLIER (T12:00:00)
    # The LogStore should sort them chronologically (stdout first, then stderr)!
    send(
      stream_pid,
      {:ssh_cm, :dummy_conn,
       {:data, :dummy_channel, 1, "2026-06-08T12:00:01.000000000Z stderr line\n"}}
    )

    send(
      stream_pid,
      {:ssh_cm, :dummy_conn,
       {:data, :dummy_channel, 0, "2026-06-08T12:00:00.000000000Z stdout line\n"}}
    )

    # Expect log updates in LogStore
    assert_receive {:logs_updated, "my-server/container123", _}, 1000

    Process.sleep(120)
    snapshot = LogStore.get_snapshot("my-server/container123")

    # Verify that the logs are sorted in chronological order!
    assert snapshot == [
             %{
               timestamp: "2026-06-08T12:00:00.000000000Z",
               stream: :stdout,
               message: "stdout line"
             },
             %{
               timestamp: "2026-06-08T12:00:01.000000000Z",
               stream: :stderr,
               message: "stderr line"
             }
           ]

    assert :ok = ContainerWorker.stop_streaming(pid)
    stop_supervised(ContainerWorker)
  end

  test "update_container_info closes log stream when container state changes to exited" do
    container = %{
      id: "container123",
      name: "my-nginx",
      image: "nginx:latest",
      status: "Up 3 hours",
      state: "running"
    }

    Mock
    |> expect(:open_channel, fn :dummy_conn ->
      {:ok, :dummy_channel}
    end)
    |> expect(:exec, fn :dummy_conn, :dummy_channel, _cmd ->
      :ok
    end)
    |> expect(:close_channel, fn :dummy_conn, :dummy_channel ->
      :ok
    end)

    opts = [ssh_client: Mock]
    {:ok, pid} = start_supervised({ContainerWorker, {"my-server", container, opts}})
    assert :ok = ContainerWorker.start_streaming(pid, :dummy_conn)

    assert ContainerWorker.get_streaming_status(pid) == %{
             streaming?: true,
             opened_at: System.monotonic_time()
           } ||
             ContainerWorker.get_streaming_status(pid).streaming? == true

    exited_container = %{container | status: "Exited (0)", state: "exited"}
    ContainerWorker.update_container_info(pid, exited_container)

    status = ContainerWorker.get_streaming_status(pid)
    assert status.streaming? == false

    stop_supervised(ContainerWorker)
  end

  test "start_streaming uses --tail 0 when LogStore already has logs" do
    container = %{
      id: "container123",
      name: "my-nginx",
      image: "nginx:latest",
      status: "Up 3 hours",
      state: "running"
    }

    source_id = "my-server/container123"
    LogStore.append_logs(source_id, ["existing log line 1"])

    Mock
    |> expect(:open_channel, fn :dummy_conn ->
      {:ok, :dummy_channel}
    end)
    |> expect(:exec, fn :dummy_conn, :dummy_channel, cmd ->
      assert String.contains?(cmd, "--tail 0")
      :ok
    end)
    |> expect(:close_channel, fn :dummy_conn, :dummy_channel ->
      :ok
    end)

    opts = [ssh_client: Mock]
    {:ok, pid} = start_supervised({ContainerWorker, {"my-server", container, opts}})
    assert :ok = ContainerWorker.start_streaming(pid, :dummy_conn)

    assert :ok = ContainerWorker.stop_streaming(pid)
    stop_supervised(ContainerWorker)
  end

  test "start_streaming uses --since timestamp when LogStore has timestamped logs" do
    container = %{
      id: "container123",
      name: "my-nginx",
      image: "nginx:latest",
      status: "Up 3 hours",
      state: "running"
    }

    source_id = "my-server/container123"
    LogStore.append_logs(source_id, ["2026-08-04T14:40:00.000000000Z existing log line 1"])

    Mock
    |> expect(:open_channel, fn :dummy_conn ->
      {:ok, :dummy_channel}
    end)
    |> expect(:exec, fn :dummy_conn, :dummy_channel, cmd ->
      assert String.contains?(cmd, "--since")
      assert String.contains?(cmd, "--tail 1000")
      :ok
    end)
    |> expect(:close_channel, fn :dummy_conn, :dummy_channel ->
      :ok
    end)

    opts = [ssh_client: Mock]
    {:ok, pid} = start_supervised({ContainerWorker, {"my-server", container, opts}})
    assert :ok = ContainerWorker.start_streaming(pid, :dummy_conn)

    assert :ok = ContainerWorker.stop_streaming(pid)
    stop_supervised(ContainerWorker)
  end

  test "start_streaming skips opening channel when container is exited and logs exist" do
    container = %{
      id: "container123",
      name: "my-nginx",
      image: "nginx:latest",
      status: "Exited (0)",
      state: "exited"
    }

    source_id = "my-server/container123"
    LogStore.append_logs(source_id, ["existing log line 1"])

    # Expect NO calls to Mock open_channel or exec!

    opts = [ssh_client: Mock]
    {:ok, pid} = start_supervised({ContainerWorker, {"my-server", container, opts}})
    assert :ok = ContainerWorker.start_streaming(pid, :dummy_conn)

    status = ContainerWorker.get_streaming_status(pid)
    assert status.streaming? == false

    stop_supervised(ContainerWorker)
  end

  test "clamp_timestamp_max_age clamps timestamps older than max seconds" do
    old_ts = "2020-01-01T00:00:00.000Z"
    clamped = ContainerWorker.clamp_timestamp_max_age(old_ts, 3600)
    assert clamped != old_ts

    recent_ts = DateTime.utc_now() |> DateTime.add(-300, :second) |> DateTime.to_iso8601()
    clamped_recent = ContainerWorker.clamp_timestamp_max_age(recent_ts, 3600)
    assert clamped_recent == recent_ts
  end

  test "reconnect clears old logs if initial batch reaches tail limit" do
    container = %{
      id: "container123",
      name: "my-nginx",
      image: "nginx:latest",
      status: "Up 3 hours",
      state: "running"
    }

    source_id = "my-server/container123"
    LogStore.append_logs(source_id, ["2026-08-04T14:40:00.000000000Z old log 1"])

    Mock
    |> expect(:open_channel, fn :dummy_conn -> {:ok, :dummy_channel} end)
    |> expect(:exec, fn :dummy_conn, :dummy_channel, _cmd -> :ok end)
    |> expect(:close_channel, fn :dummy_conn, :dummy_channel -> :ok end)

    opts = [ssh_client: Mock]
    {:ok, pid} = start_supervised({ContainerWorker, {"my-server", container, opts}})
    assert :ok = ContainerWorker.start_streaming(pid, :dummy_conn)
    stream_pid = ContainerWorker.get_stream_channel(pid)

    # Send 1000 lines (reaches tail limit)
    Enum.each(1..1000, fn i ->
      send(
        stream_pid,
        {:ssh_cm, :dummy_conn,
         {:data, :dummy_channel, 0, "2026-08-04T15:00:00.000000000Z new log #{i}\n"}}
      )
    end)

    _ = :sys.get_state(stream_pid)
    send(pid, :flush_logs)
    Process.sleep(50)

    snapshot = LogStore.get_snapshot(source_id)
    # Verify old log was cleared because 1000 lines reached limit
    refute Enum.any?(snapshot, fn msg -> String.contains?(to_string(msg.message), "old log 1") end)

    assert length(snapshot) == 1000

    assert :ok = ContainerWorker.stop_streaming(pid)
    stop_supervised(ContainerWorker)
  end

  test "reconnect merges logs if initial batch is below tail limit" do
    container = %{
      id: "container123",
      name: "my-nginx",
      image: "nginx:latest",
      status: "Up 3 hours",
      state: "running"
    }

    source_id = "my-server/container123"
    LogStore.append_logs(source_id, ["2026-08-04T14:40:00.000000000Z old log 1"])

    Mock
    |> expect(:open_channel, fn :dummy_conn -> {:ok, :dummy_channel} end)
    |> expect(:exec, fn :dummy_conn, :dummy_channel, _cmd -> :ok end)
    |> expect(:close_channel, fn :dummy_conn, :dummy_channel -> :ok end)

    opts = [ssh_client: Mock]
    {:ok, pid} = start_supervised({ContainerWorker, {"my-server", container, opts}})
    assert :ok = ContainerWorker.start_streaming(pid, :dummy_conn)
    stream_pid = ContainerWorker.get_stream_channel(pid)

    # Send 5 lines (under limit)
    Enum.each(1..5, fn i ->
      send(
        stream_pid,
        {:ssh_cm, :dummy_conn,
         {:data, :dummy_channel, 0, "2026-08-04T15:00:00.000000000Z new log #{i}\n"}}
      )
    end)

    _ = :sys.get_state(stream_pid)
    send(pid, :flush_logs)
    Process.sleep(50)

    snapshot = LogStore.get_snapshot(source_id)
    # Verify old log was preserved and merged with 5 new lines
    assert Enum.any?(snapshot, fn msg -> String.contains?(to_string(msg.message), "old log 1") end)

    assert length(snapshot) == 6

    assert :ok = ContainerWorker.stop_streaming(pid)
    stop_supervised(ContainerWorker)
  end

  test "adjust_window is called on incoming data chunks" do
    container = %{
      id: "container123",
      name: "my-nginx",
      image: "nginx:latest",
      status: "Up 3 hours",
      state: "running"
    }

    test_pid = self()

    Mock
    |> expect(:open_channel, fn :dummy_conn -> {:ok, :dummy_channel} end)
    |> expect(:exec, fn :dummy_conn, :dummy_channel, _cmd -> :ok end)
    |> expect(:adjust_window, fn :dummy_conn, :dummy_channel, bytes ->
      send(test_pid, {:adjusted_window, bytes})
      :ok
    end)
    |> expect(:close_channel, fn :dummy_conn, :dummy_channel -> :ok end)

    opts = [ssh_client: Mock]
    {:ok, pid} = start_supervised({ContainerWorker, {"my-server", container, opts}})
    assert :ok = ContainerWorker.start_streaming(pid, :dummy_conn)
    stream_pid = ContainerWorker.get_stream_channel(pid)

    send(stream_pid, {:ssh_cm, :dummy_conn, {:data, :dummy_channel, 0, "hello world\n"}})
    assert_receive {:adjusted_window, 12}, 1000

    assert :ok = ContainerWorker.stop_streaming(pid)
    stop_supervised(ContainerWorker)
  end

  test "auto-reconnects stream when channel is closed unexpectedly and container is running" do
    container = %{
      id: "container123",
      name: "my-nginx",
      image: "nginx:latest",
      status: "Up 3 hours",
      state: "running"
    }

    test_pid = self()

    Mock
    # Initial streaming
    |> expect(:open_channel, fn :dummy_conn -> {:ok, :dummy_channel_1} end)
    |> expect(:exec, fn :dummy_conn, :dummy_channel_1, _cmd -> :ok end)
    # Channel 1 close
    |> expect(:close_channel, fn :dummy_conn, :dummy_channel_1 ->
      send(test_pid, :closed_channel_1)
      :ok
    end)
    # Auto-reconnect stream
    |> expect(:open_channel, fn :dummy_conn ->
      send(test_pid, :reconnected_channel_2)
      {:ok, :dummy_channel_2}
    end)
    |> expect(:exec, fn :dummy_conn, :dummy_channel_2, _cmd -> :ok end)
    |> expect(:close_channel, fn :dummy_conn, :dummy_channel_2 -> :ok end)

    opts = [ssh_client: Mock]
    {:ok, pid} = start_supervised({ContainerWorker, {"my-server", container, opts}})
    assert :ok = ContainerWorker.start_streaming(pid, :dummy_conn)
    stream_pid = ContainerWorker.get_stream_channel(pid)

    # Simulate unexpected remote EOF
    send(stream_pid, {:ssh_cm, :dummy_conn, {:eof, :dummy_channel_1}})

    assert_receive :closed_channel_1, 1000
    # Wait for auto-reconnect timer (1000ms)
    assert_receive :reconnected_channel_2, 2000

    assert :ok = ContainerWorker.stop_streaming(pid)
    stop_supervised(ContainerWorker)
  end

  test "start_streaming is idempotent when using ConnectionPool" do
    container = %{
      id: "container123",
      name: "my-nginx",
      image: "nginx:latest",
      status: "Up 3 hours",
      state: "running"
    }

    test_pid = self()

    # We expect only ONE open_channel and ONE exec call despite multiple start_streaming calls
    Mock
    |> expect(:open_channel, 1, fn :pool_data_conn ->
      send(test_pid, :pool_channel_opened)
      {:ok, :pool_chan_1}
    end)
    |> expect(:exec, 1, fn :pool_data_conn, :pool_chan_1, _cmd ->
      send(test_pid, :pool_cmd_execed)
      :ok
    end)
    |> expect(:close_channel, 1, fn :pool_data_conn, :pool_chan_1 ->
      send(test_pid, :pool_channel_closed)
      :ok
    end)

    profile =
      Caudata.Profile.new(%{
        host_pattern: "cw-pool-server",
        host_name: "10.0.0.101",
        user: "root",
        port: 22
      })

    {:ok, pool} =
      Caudata.SSH.ConnectionPool.start_link(
        profile: profile,
        ssh_client: Mock,
        primary_conn: :pool_data_conn,
        max_channels_per_conn: 5
      )

    opts = [ssh_client: Mock, pool: pool]
    {:ok, pid} = start_supervised({ContainerWorker, {"cw-pool-server", container, opts}})

    # First start_streaming call
    assert :ok = ContainerWorker.start_streaming(pid, :server_control_conn)
    assert_receive :pool_channel_opened, 1000
    assert_receive :pool_cmd_execed, 1000

    # Second start_streaming call with different conn_ref (control conn) - must be a no-op!
    assert :ok = ContainerWorker.start_streaming(pid, :server_control_conn)
    refute_receive :pool_channel_opened, 200

    # Third start_streaming call with nil conn_ref - still a no-op!
    assert :ok = ContainerWorker.start_streaming(pid, nil)
    refute_receive :pool_channel_opened, 200

    # Stopping releases channel cleanly
    assert :ok = ContainerWorker.stop_streaming(pid)
    assert_receive :pool_channel_closed, 1000

    stop_supervised(ContainerWorker)
    GenServer.stop(pool)
  end

  test "initiates two-phase backfill stream after first log batch and prepends historical logs" do
    container = %{
      id: "container123",
      name: "my-nginx",
      image: "nginx:latest",
      status: "Up 3 hours",
      state: "running"
    }

    source_id = "my-server/container123"
    LogStore.clear_logs(source_id)

    test_pid = self()

    # Channel 1: primary follow stream
    Mock
    |> expect(:open_channel, fn :dummy_conn ->
      send(test_pid, :follow_channel_opened)
      {:ok, :follow_channel}
    end)
    |> expect(:exec, fn :dummy_conn, :follow_channel, cmd ->
      assert String.contains?(cmd, "--follow")
      assert String.contains?(cmd, "--tail 1000")
      send(test_pid, :follow_exec_done)
      :ok
    end)
    # Channel 2: Phase 2 backfill stream
    |> expect(:open_channel, fn :dummy_conn ->
      send(test_pid, :backfill_channel_opened)
      {:ok, :backfill_channel}
    end)
    |> expect(:exec, fn :dummy_conn, :backfill_channel, cmd ->
      assert String.contains?(cmd, "--tail 9000")
      assert String.contains?(cmd, "--until")
      assert String.contains?(cmd, "2026-06-08T12:00:10.000000000Z")
      send(test_pid, :backfill_exec_done)
      :ok
    end)
    |> expect(:close_channel, fn :dummy_conn, :backfill_channel ->
      send(test_pid, :backfill_closed)
      :ok
    end)
    |> expect(:close_channel, fn :dummy_conn, :follow_channel ->
      send(test_pid, :follow_closed)
      :ok
    end)

    opts = [
      ssh_client: Mock,
      initial_tail_limit: 1000,
      target_capacity: 10000
    ]

    {:ok, pid} = start_supervised({ContainerWorker, {"my-server", container, opts}})
    assert :ok = ContainerWorker.start_streaming(pid, :dummy_conn)

    assert_receive :follow_channel_opened, 1000
    assert_receive :follow_exec_done, 1000
    follow_stream_pid = ContainerWorker.get_stream_channel(pid)

    # Send initial live follow log
    send(
      follow_stream_pid,
      {:ssh_cm, :dummy_conn,
       {:data, :follow_channel, 0, "2026-06-08T12:00:10.000000000Z follow line 1\n"}}
    )

    # Verify Phase 2 backfill was triggered automatically
    assert_receive :backfill_channel_opened, 1500
    assert_receive :backfill_exec_done, 1500

    # Locate the backfill stream channel PID from worker state
    worker_state = :sys.get_state(pid)
    backfill_pid = worker_state.backfill_channel
    assert is_pid(backfill_pid)

    # Backfill channel sends older historical logs and closes
    send(
      backfill_pid,
      {:ssh_cm, :dummy_conn,
       {:data, :backfill_channel, 0, "2026-06-08T12:00:00.000000000Z older line 0\n"}}
    )

    send(backfill_pid, {:ssh_cm, :dummy_conn, {:closed, :backfill_channel}})
    assert_receive :backfill_closed, 1500

    Process.sleep(100)
    snapshot = LogStore.get_snapshot(source_id)

    # Verify both older line 0 and follow line 1 are present in chronological order!
    assert snapshot == [
             %{
               timestamp: "2026-06-08T12:00:00.000000000Z",
               stream: :stdout,
               message: "older line 0"
             },
             %{
               timestamp: "2026-06-08T12:00:10.000000000Z",
               stream: :stdout,
               message: "follow line 1"
             }
           ]

    assert :ok = ContainerWorker.stop_streaming(pid)
    assert_receive :follow_closed, 1000
    stop_supervised(ContainerWorker)
  end

  test "skips backfill if container logs have no timestamps" do
    container = %{
      id: "container123",
      name: "my-nginx",
      image: "nginx:latest",
      status: "Up 3 hours",
      state: "running"
    }

    source_id = "my-server/container123"
    LogStore.clear_logs(source_id)

    Mock
    |> expect(:open_channel, 1, fn :dummy_conn -> {:ok, :follow_channel} end)
    |> expect(:exec, 1, fn :dummy_conn, :follow_channel, _cmd -> :ok end)
    |> expect(:close_channel, 1, fn :dummy_conn, :follow_channel -> :ok end)

    opts = [
      ssh_client: Mock,
      initial_tail_limit: 1000,
      target_capacity: 10000
    ]

    {:ok, pid} = start_supervised({ContainerWorker, {"my-server", container, opts}})
    assert :ok = ContainerWorker.start_streaming(pid, :dummy_conn)
    follow_stream_pid = ContainerWorker.get_stream_channel(pid)

    # Send lines without timestamp
    send(
      follow_stream_pid,
      {:ssh_cm, :dummy_conn,
       {:data, :follow_channel, 0, "log line without any timestamp\n"}}
    )

    # Allow worker to flush logs
    Process.sleep(100)

    # Check worker state: backfill_status should be :done without opening second channel
    worker_state = :sys.get_state(pid)
    assert worker_state.backfill_status == :done
    assert is_nil(worker_state.backfill_channel)

    assert :ok = ContainerWorker.stop_streaming(pid)
    stop_supervised(ContainerWorker)
  end

  test "stale or unknown channel closed event does not disconnect primary stream" do
    container = %{
      id: "container-stale",
      name: "my-nginx",
      image: "nginx:latest",
      status: "Up 3 hours",
      state: "running"
    }

    Mock
    |> expect(:open_channel, 1, fn :dummy_conn -> {:ok, :follow_channel} end)
    |> expect(:exec, 1, fn :dummy_conn, :follow_channel, _cmd -> :ok end)
    |> expect(:close_channel, 1, fn :dummy_conn, :follow_channel -> :ok end)

    opts = [ssh_client: Mock, target_capacity: 1000]
    {:ok, pid} = start_supervised({ContainerWorker, {"my-server", container, opts}})
    assert :ok = ContainerWorker.start_streaming(pid, :dummy_conn)

    # Send a stream_closed event from an unknown / stale pid
    fake_pid = spawn(fn -> :ok end)
    send(pid, {:stream_closed, fake_pid})

    Process.sleep(50)
    status = ContainerWorker.get_streaming_status(pid)
    assert status.streaming? == true

    assert :ok = ContainerWorker.stop_streaming(pid)
    stop_supervised(ContainerWorker)
  end

  test "backfill command with non-zero exit status discards backfill logs and sets status to failed" do
    container = %{
      id: "container-fail-backfill",
      name: "my-nginx",
      image: "nginx:latest",
      status: "Up 3 hours",
      state: "running"
    }

    source_id = "my-server/container-fail-backfill"
    LogStore.clear_logs(source_id)

    test_pid = self()

    Mock
    |> expect(:open_channel, fn :dummy_conn -> {:ok, :follow_channel} end)
    |> expect(:exec, fn :dummy_conn, :follow_channel, _cmd -> :ok end)
    |> expect(:open_channel, fn :dummy_conn ->
      send(test_pid, :backfill_channel_opened)
      {:ok, :backfill_channel}
    end)
    |> expect(:exec, fn :dummy_conn, :backfill_channel, _cmd ->
      send(test_pid, :backfill_exec_done)
      :ok
    end)
    |> expect(:close_channel, fn :dummy_conn, :backfill_channel ->
      send(test_pid, :backfill_closed)
      :ok
    end)
    |> expect(:close_channel, fn :dummy_conn, :follow_channel -> :ok end)

    opts = [
      ssh_client: Mock,
      initial_tail_limit: 1000,
      target_capacity: 10000
    ]

    {:ok, pid} = start_supervised({ContainerWorker, {"my-server", container, opts}})
    assert :ok = ContainerWorker.start_streaming(pid, :dummy_conn)

    follow_stream_pid = ContainerWorker.get_stream_channel(pid)

    send(
      follow_stream_pid,
      {:ssh_cm, :dummy_conn,
       {:data, :follow_channel, 0, "2026-06-08T12:00:10.000000000Z live line\n"}}
    )

    assert_receive :backfill_channel_opened, 1500
    assert_receive :backfill_exec_done, 1500

    worker_state = :sys.get_state(pid)
    backfill_pid = worker_state.backfill_channel
    assert is_pid(backfill_pid)

    # Send an error output and non-zero exit status
    send(
      backfill_pid,
      {:ssh_cm, :dummy_conn,
       {:data, :backfill_channel, 1, "unknown flag: --until\n"}}
    )

    send(backfill_pid, {:ssh_cm, :dummy_conn, {:exit_status, :backfill_channel, 1}})
    send(backfill_pid, {:ssh_cm, :dummy_conn, {:closed, :backfill_channel}})

    assert_receive :backfill_closed, 1500
    Process.sleep(100)

    # Verify backfill status is :failed and error message was NOT prepended
    status = ContainerWorker.get_streaming_status(pid)
    assert status.backfill_status == :failed

    snapshot = LogStore.get_snapshot(source_id)
    assert length(snapshot) == 1
    assert hd(snapshot).message == "live line"

    assert :ok = ContainerWorker.stop_streaming(pid)
    stop_supervised(ContainerWorker)
  end
end
