defmodule Caudata.ContainerWorkerTest do
  use ExUnit.Case, async: false
  import Mox
  alias Caudata.ContainerWorker
  alias Caudata.LogStore
  alias Caudata.SSHClient.Mock

  setup :verify_on_exit!

  setup do
    set_mox_global()
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
    |> expect(:exec, fn :dummy_conn,
                        :dummy_channel,
                        "sh -c 'docker logs --follow --tail 1000 container123 & pid=$!; trap \"kill $pid 2>/dev/null\" EXIT HUP INT TERM; read -r _; kill $pid 2>/dev/null'" ->
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
    assert snapshot == ["log line 1", "log line 2"]

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
    |> expect(:exec, fn :dummy_conn,
                        :dummy_channel,
                        "sh -c 'docker logs --follow --tail 1000 container123 & pid=$!; trap \"kill $pid 2>/dev/null\" EXIT HUP INT TERM; read -r _; kill $pid 2>/dev/null'" ->
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
end
