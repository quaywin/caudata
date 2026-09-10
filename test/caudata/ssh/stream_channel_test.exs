defmodule Caudata.SSH.StreamChannelTest do
  use ExUnit.Case, async: false
  import Mox
  alias Caudata.SSH.StreamChannel
  alias Caudata.SSH.ConnectionPool
  alias Caudata.Profile
  alias Caudata.SSHClient.Mock

  setup :verify_on_exit!

  setup do
    set_mox_global()
    :ok
  end

  test "opens channel, executes command, buffers and delivers stream lines with adjust_window" do
    test_pid = self()

    Mock
    |> expect(:open_channel, fn :dummy_conn -> {:ok, :dummy_chan} end)
    |> expect(:exec, fn :dummy_conn, :dummy_chan, "docker logs -f my_app" -> :ok end)
    |> expect(:adjust_window, 2, fn :dummy_conn, :dummy_chan, bytes ->
      send(test_pid, {:adjusted_window, bytes})
      :ok
    end)
    |> expect(:close_channel, fn :dummy_conn, :dummy_chan -> :ok end)

    {:ok, stream_pid} =
      StreamChannel.start_link(
        conn_ref: :dummy_conn,
        cmd: "docker logs -f my_app",
        notify_to: test_pid,
        ssh_client: Mock
      )

    # Chunk 1: "line 1\npart"
    send(stream_pid, {:ssh_cm, :dummy_conn, {:data, :dummy_chan, 0, "line 1\npart"}})
    assert_receive {:stream_lines, ^stream_pid, :stdout, ["line 1"]}, 500
    assert_receive {:adjusted_window, 11}, 500

    # Chunk 2: "ial line 2\n"
    send(stream_pid, {:ssh_cm, :dummy_conn, {:data, :dummy_chan, 0, "ial line 2\n"}})
    assert_receive {:stream_lines, ^stream_pid, :stdout, ["partial line 2"]}, 500
    assert_receive {:adjusted_window, 11}, 500

    # Stop stream channel
    StreamChannel.stop(stream_pid)
  end

  test "handles stderr stream separately with stream_type :stderr" do
    test_pid = self()

    Mock
    |> expect(:open_channel, fn :dummy_conn -> {:ok, :dummy_chan} end)
    |> expect(:exec, fn :dummy_conn, :dummy_chan, "journalctl -f" -> :ok end)
    |> expect(:adjust_window, fn :dummy_conn, :dummy_chan, _bytes -> :ok end)
    |> expect(:close_channel, fn :dummy_conn, :dummy_chan -> :ok end)

    {:ok, stream_pid} =
      StreamChannel.start_link(
        conn_ref: :dummy_conn,
        cmd: "journalctl -f",
        notify_to: test_pid,
        ssh_client: Mock
      )

    # stream_id = 1 means stderr
    send(stream_pid, {:ssh_cm, :dummy_conn, {:data, :dummy_chan, 1, "error line\n"}})
    assert_receive {:stream_lines, ^stream_pid, :stderr, ["error line"]}, 500

    StreamChannel.stop(stream_pid)
  end

  test "integrates seamlessly with ConnectionPool" do
    profile =
      Profile.new(%{
        host_pattern: "stream-pool-server",
        host_name: "10.0.0.101",
        user: "root",
        port: 22
      })

    test_pid = self()

    Mock
    |> expect(:open_channel, fn :dummy_conn -> {:ok, :pool_chan} end)
    |> expect(:exec, fn :dummy_conn, :pool_chan, "tail -F /var/log/syslog" -> :ok end)
    |> expect(:close_channel, fn :dummy_conn, :pool_chan ->
      send(test_pid, :channel_closed_to_pool)
      :ok
    end)
    |> stub(:close, fn _conn -> :ok end)

    {:ok, pool} =
      ConnectionPool.start_link(
        profile: profile,
        ssh_client: Mock,
        primary_conn: :dummy_conn
      )

    {:ok, stream_pid} =
      StreamChannel.start_link(
        pool: pool,
        cmd: "tail -F /var/log/syslog",
        notify_to: test_pid,
        ssh_client: Mock
      )

    # Verify channel info
    assert %{conn_ref: :dummy_conn, channel_id: :pool_chan} = StreamChannel.get_info(stream_pid)

    # Verify connection pool has 1 active channel
    status = ConnectionPool.get_status(pool)
    assert [%{conn_ref: :dummy_conn, active_channels: 1}] = status.connections

    # Stopping the stream releases the channel in the pool
    StreamChannel.stop(stream_pid)
    assert_receive :channel_closed_to_pool, 500

    status = ConnectionPool.get_status(pool)
    assert [%{conn_ref: :dummy_conn, active_channels: 0}] = status.connections

    GenServer.stop(pool)
  end
end
