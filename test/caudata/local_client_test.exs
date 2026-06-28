defmodule Caudata.LocalClientTest do
  use ExUnit.Case, async: true
  alias Caudata.LocalClient

  test "local client lifecycle and execution" do
    # 1. Connect
    assert {:ok, conn_ref} = LocalClient.connect("local", 0, password: nil)
    assert match?({:local_conn, nil}, conn_ref)

    # 2. Open channel
    assert {:ok, channel_pid} = LocalClient.open_channel(conn_ref)
    assert is_pid(channel_pid)

    # 3. Exec command
    # We will run a simple echo command
    assert :ok = LocalClient.exec(conn_ref, channel_pid, "echo 'hello local'")

    # 4. Check that data is streamed back to self()
    assert_receive {:ssh_cm, ^conn_ref, {:data, ^channel_pid, 0, "hello local\n"}}, 2000
    assert_receive {:ssh_cm, ^conn_ref, {:eof, ^channel_pid}}, 2000
    assert_receive {:ssh_cm, ^conn_ref, {:exit_status, ^channel_pid, 0}}, 2000
    assert_receive {:ssh_cm, ^conn_ref, {:closed, ^channel_pid}}, 2000

    # Clean up
    assert :ok = LocalClient.close_channel(conn_ref, channel_pid)
  end

  test "local client streams standard error" do
    assert {:ok, conn_ref} = LocalClient.connect("local", 0, password: nil)
    assert {:ok, channel_pid} = LocalClient.open_channel(conn_ref)

    # Run a command that prints to stderr and exits with non-zero status
    assert :ok = LocalClient.exec(conn_ref, channel_pid, "echo 'error message' >&2; exit 42")

    # The local port runner uses :stderr_to_stdout option.
    assert_receive {:ssh_cm, ^conn_ref, {:data, ^channel_pid, 0, "error message\n"}}, 2000
    assert_receive {:ssh_cm, ^conn_ref, {:eof, ^channel_pid}}, 2000
    assert_receive {:ssh_cm, ^conn_ref, {:exit_status, ^channel_pid, 42}}, 2000
    assert_receive {:ssh_cm, ^conn_ref, {:closed, ^channel_pid}}, 2000

    assert :ok = LocalClient.close_channel(conn_ref, channel_pid)
  end

  test "closing channel terminates command" do
    assert {:ok, conn_ref} = LocalClient.connect("local", 0, password: nil)
    assert {:ok, channel_pid} = LocalClient.open_channel(conn_ref)

    # Run a long running sleep command
    assert :ok = LocalClient.exec(conn_ref, channel_pid, "sleep 10")

    # Close the channel immediately
    assert :ok = LocalClient.close_channel(conn_ref, channel_pid)

    # The process should terminate and the loop should finish.
    # Wait a bit and check if process is alive
    Process.sleep(100)
    refute Process.alive?(channel_pid)
  end
end
