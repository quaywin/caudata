defmodule Caudata.ContainerWorkerTest do
  use ExUnit.Case, async: false
  import Mox
  alias Caudata.ContainerWorker
  alias Caudata.LogStore
  alias Caudata.SSHClient.Mock

  setup :verify_on_exit!

  setup do
    set_mox_global()
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

    # Subscribe to LogStore updates
    Phoenix.PubSub.subscribe(Caudata.PubSub, "logs:my-server/container123")

    # Simulate receiving incoming data chunk split across packets
    send(pid, {:ssh_cm, :dummy_conn, {:data, :dummy_channel, 0, "log line 1\nlog line"}})
    send(pid, {:ssh_cm, :dummy_conn, {:data, :dummy_channel, 0, " 2\n"}})

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

    # Subscribe to container logs disconnect topic
    Phoenix.PubSub.subscribe(Caudata.PubSub, "container_logs:my-server/container123")

    # Simulate channel closure from remote end
    send(pid, {:ssh_cm, :dummy_conn, {:closed, :dummy_channel}})

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

    opts = [ssh_client: Mock]
    {:ok, pid} = start_supervised({ContainerWorker, {"my-server", container, opts}})

    assert :ok = ContainerWorker.start_streaming(pid, :dummy_conn)

    # Subscribe to LogStore updates
    Phoenix.PubSub.subscribe(Caudata.PubSub, "logs:my-server/container123")

    # Simulate interleaved stdout (stream 0) and stderr (stream 1) chunks with ISO 8601 timestamps
    # Notice that stderr is received FIRST, but its timestamp is LATER (T12:00:01)
    # stdout is received SECOND, but its timestamp is EARLIER (T12:00:00)
    # The LogStore should sort them chronologically (stdout first, then stderr)!
    send(
      pid,
      {:ssh_cm, :dummy_conn,
       {:data, :dummy_channel, 1, "2026-06-08T12:00:01.000000000Z stderr line\n"}}
    )

    send(
      pid,
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

    assert ContainerWorker.get_streaming_status(pid) == %{streaming?: true, opened_at: System.monotonic_time()} ||
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
      assert String.contains?(cmd, "2026-08-04T14:40:00.000000000Z")
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
end
