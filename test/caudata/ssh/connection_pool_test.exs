defmodule Caudata.SSH.ConnectionPoolTest do
  use ExUnit.Case, async: false
  import Mox
  alias Caudata.Profile
  alias Caudata.SSH.ConnectionPool
  alias Caudata.SSHClient.Mock

  setup :verify_on_exit!

  setup do
    set_mox_global()

    profile =
      Profile.new(%{
        host_pattern: "pool-test-server",
        host_name: "10.0.0.100",
        user: "root",
        port: 22
      })

    {:ok, profile: profile}
  end

  test "acquires and releases channels on a primary connection", %{profile: profile} do
    test_pid = self()

    Mock
    |> expect(:open_channel, fn :primary_conn ->
      send(test_pid, :opened_ch_1)
      {:ok, :chan_1}
    end)
    |> expect(:close_channel, fn :primary_conn, :chan_1 ->
      send(test_pid, :closed_ch_1)
      :ok
    end)

    {:ok, pool} =
      ConnectionPool.start_link(
        profile: profile,
        ssh_client: Mock,
        primary_conn: :primary_conn,
        max_channels_per_conn: 3
      )

    assert {:ok, :primary_conn, :chan_1} = ConnectionPool.acquire_channel(pool)
    assert_receive :opened_ch_1, 500

    status = ConnectionPool.get_status(pool)
    assert status.connection_count == 1
    assert [%{conn_ref: :primary_conn, active_channels: 1, is_primary: true}] = status.connections

    assert :ok = ConnectionPool.release_channel(pool, :primary_conn, :chan_1)
    assert_receive :closed_ch_1, 500

    status = ConnectionPool.get_status(pool)
    assert [%{conn_ref: :primary_conn, active_channels: 0, is_primary: true}] = status.connections

    GenServer.stop(pool)
  end

  test "automatically scales to a new connection when max channels reached", %{profile: profile} do
    test_pid = self()

    # Connection 1: Connect + 2 channels
    Mock
    |> expect(:connect, fn "10.0.0.100", 22, _ ->
      send(test_pid, :connected_conn_1)
      {:ok, :conn_1}
    end)
    |> expect(:open_channel, fn :conn_1 -> {:ok, :chan_1} end)
    |> expect(:open_channel, fn :conn_1 -> {:ok, :chan_2} end)

    # Connection 2: Connect + 1 channel (since max_channels_per_conn: 2)
    Mock
    |> expect(:connect, fn "10.0.0.100", 22, _ ->
      send(test_pid, :connected_conn_2)
      {:ok, :conn_2}
    end)
    |> expect(:open_channel, fn :conn_2 -> {:ok, :chan_3} end)

    # Closing channels & secondary connection
    Mock
    |> expect(:close_channel, fn :conn_2, :chan_3 -> :ok end)
    |> expect(:close, fn :conn_2 ->
      send(test_pid, :closed_conn_2)
      :ok
    end)
    |> stub(:close_channel, fn _conn, _chan -> :ok end)
    |> stub(:close, fn _conn -> :ok end)

    {:ok, pool} =
      ConnectionPool.start_link(
        profile: profile,
        ssh_client: Mock,
        max_channels_per_conn: 2
      )

    # 1. First channel -> triggers conn_1
    assert {:ok, :conn_1, :chan_1} = ConnectionPool.acquire_channel(pool)
    assert_receive :connected_conn_1, 500

    # 2. Second channel -> reuses conn_1 (capacity: 2/2)
    assert {:ok, :conn_1, :chan_2} = ConnectionPool.acquire_channel(pool)

    status = ConnectionPool.get_status(pool)
    assert status.connection_count == 1
    assert [%{conn_ref: :conn_1, active_channels: 2}] = status.connections

    # 3. Third channel -> conn_1 is full, scales up to conn_2!
    assert {:ok, :conn_2, :chan_3} = ConnectionPool.acquire_channel(pool)
    assert_receive :connected_conn_2, 500

    status = ConnectionPool.get_status(pool)
    assert status.connection_count == 2

    assert [
             %{conn_ref: :conn_1, active_channels: 2, is_primary: true},
             %{conn_ref: :conn_2, active_channels: 1, is_primary: false}
           ] = status.connections

    # 4. Release chan_3 on conn_2 -> secondary conn_2 becomes idle and closes
    assert :ok = ConnectionPool.release_channel(pool, :conn_2, :chan_3)
    assert_receive :closed_conn_2, 500

    status = ConnectionPool.get_status(pool)
    assert status.connection_count == 1
    assert [%{conn_ref: :conn_1, active_channels: 2, is_primary: true}] = status.connections

    GenServer.stop(pool)
  end

  test "automatically cleans up channels when caller process dies", %{profile: profile} do
    Mock
    |> expect(:open_channel, fn :primary_conn -> {:ok, :chan_leak_test} end)
    |> expect(:close_channel, fn :primary_conn, :chan_leak_test -> :ok end)
    |> stub(:close, fn _conn -> :ok end)

    {:ok, pool} =
      ConnectionPool.start_link(
        profile: profile,
        ssh_client: Mock,
        primary_conn: :primary_conn,
        max_channels_per_conn: 5
      )

    test_pid = self()

    # Spawn a task that acquires a channel and holds it
    task =
      Task.async(fn ->
        {:ok, :primary_conn, :chan_leak_test} = ConnectionPool.acquire_channel(pool)
        send(test_pid, :channel_acquired)
        Process.sleep(5000)
      end)

    assert_receive :channel_acquired, 500

    status = ConnectionPool.get_status(pool)
    assert [%{conn_ref: :primary_conn, active_channels: 1}] = status.connections

    # Kill the task process unexpectedly
    Task.shutdown(task, :brutal_kill)

    # Allow pool to handle :DOWN message
    Process.sleep(50)

    # Active channels should be automatically back to 0
    status = ConnectionPool.get_status(pool)
    assert [%{conn_ref: :primary_conn, active_channels: 0}] = status.connections

    GenServer.stop(pool)
  end
end
