defmodule Caudata.SSH.ConnectionPoolStressTest do
  use ExUnit.Case, async: false
  import Mox
  alias Caudata.Profile
  alias Caudata.ServerWorker
  alias Caudata.ContainerWorker
  alias Caudata.ServerSupervisor
  alias Caudata.SSHClient.Mock

  setup :verify_on_exit!

  setup do
    set_mox_global()
    stub(Mock, :adjust_window, fn _conn, _chan, _bytes -> :ok end)
    stub(Mock, :close_channel, fn _conn, _chan -> :ok end)
    stub(Mock, :close, fn _conn -> :ok end)
    :ok
  end

  test "scales across multiple SSH connections when streaming > 10 channels concurrently" do
    profile =
      Profile.new(%{
        host_pattern: "stress-test-server",
        host_name: "10.0.0.50",
        user: "root",
        port: 22
      })

    test_pid = self()

    # 1. Control Plane Connection: Handshake + list channel exclusively for ServerWorker
    Mock
    |> expect(:connect, fn "10.0.0.50", 22, _ ->
      send(test_pid, :connected_control)
      {:ok, :conn_control}
    end)
    |> expect(:open_channel, fn :conn_control ->
      send(test_pid, :opened_list_channel)
      {:ok, :ch_list}
    end)
    |> expect(:exec, fn :conn_control, :ch_list, _cmd -> :ok end)

    # 2. Data Plane Connection 1: Triggered when Container 1 starts streaming (pool capacity: 4 channels/conn)
    Mock
    |> expect(:connect, fn "10.0.0.50", 22, _ ->
      send(test_pid, :connected_data_1)
      {:ok, :conn_data_1}
    end)

    # Containers 1..4 stream logs on Data Plane Connection 1
    Enum.each(1..4, fn i ->
      ch_id = :"ch_c#{i}"

      Mock
      |> expect(:open_channel, fn :conn_data_1 -> {:ok, ch_id} end)
      |> expect(:exec, fn :conn_data_1, ^ch_id, _cmd -> :ok end)
    end)

    # 3. Data Plane Connection 2: Triggered when Container 5 starts streaming (since capacity: 4 ch/conn)
    Mock
    |> expect(:connect, fn "10.0.0.50", 22, _ ->
      send(test_pid, :connected_data_2)
      {:ok, :conn_data_2}
    end)

    # Containers 5..8 stream logs on Data Plane Connection 2
    Enum.each(5..8, fn i ->
      ch_id = :"ch_c#{i}"

      Mock
      |> expect(:open_channel, fn :conn_data_2 -> {:ok, ch_id} end)
      |> expect(:exec, fn :conn_data_2, ^ch_id, _cmd -> :ok end)
    end)

    # 4. Data Plane Connection 3: Triggered when Container 9 starts streaming
    Mock
    |> expect(:connect, fn "10.0.0.50", 22, _ ->
      send(test_pid, :connected_data_3)
      {:ok, :conn_data_3}
    end)

    # Containers 9..12 stream logs on Data Plane Connection 3
    Enum.each(9..12, fn i ->
      ch_id = :"ch_c#{i}"

      Mock
      |> expect(:open_channel, fn :conn_data_3 -> {:ok, ch_id} end)
      |> expect(:exec, fn :conn_data_3, ^ch_id, _cmd -> :ok end)
    end)

    # Start ServerWorker with use_pool: true, max_channels_per_conn: 4, max_active_streams: 20
    {:ok, worker_pid} =
      start_supervised(
        {ServerWorker,
         {profile,
          ssh_client: Mock, use_pool: true, max_channels_per_conn: 4, max_active_streams: 20}}
      )

    # 1. Verify primary control connection established
    assert_receive :connected_control, 1000
    assert_receive :opened_list_channel, 1000

    # 2. Discover 12 containers
    containers_json =
      1..12
      |> Enum.map(fn i ->
        "{\"ID\":\"container#{i}\",\"Names\":\"worker-#{i}\",\"Image\":\"alpine\",\"Status\":\"Up\"}"
      end)
      |> Enum.join("\n")
      |> Kernel.<>("\n")

    send(worker_pid, {:ssh_cm, :conn_control, {:data, :ch_list, 0, containers_json}})
    send(worker_pid, {:ssh_cm, :conn_control, {:closed, :ch_list}})

    Process.sleep(100)

    # 3. Start streaming logs on containers 1..4 (handled by Data Plane conn 1)
    Enum.each(1..4, fn i ->
      assert :ok = GenServer.call(worker_pid, {:stream_container_logs, "container#{i}"})
      Process.sleep(10)
    end)

    assert_receive :connected_data_1, 1000

    # 4. Start streaming logs on containers 5..8 -> triggers scaling to Data Plane conn 2!
    Enum.each(5..8, fn i ->
      assert :ok = GenServer.call(worker_pid, {:stream_container_logs, "container#{i}"})
      Process.sleep(10)
    end)

    assert_receive :connected_data_2, 1000

    # 5. Start streaming logs on containers 9..12 -> triggers scaling to Data Plane conn 3!
    Enum.each(9..12, fn i ->
      assert :ok = GenServer.call(worker_pid, {:stream_container_logs, "container#{i}"})
      Process.sleep(10)
    end)

    assert_receive :connected_data_3, 1000

    # 6. Verify that ALL 12 containers are streaming SIMULTANEOUSLY!
    # None of them were closed or evicted!
    Enum.each(1..12, fn i ->
      {:ok, c_pid} =
        ServerSupervisor.lookup_container_worker("stress-test-server", "container#{i}")

      assert %{streaming?: true} = ContainerWorker.get_streaming_status(c_pid)
    end)

    stop_supervised(ServerWorker)
  end
end
