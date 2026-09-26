defmodule Caudata.SSH.AgentTest do
  use ExUnit.Case, async: false

  alias Caudata.SSH.Agent

  setup do
    unique_id = System.unique_integer([:positive])
    sock_path = "/tmp/caudata_agent_test_#{unique_id}.sock"
    File.rm(sock_path)

    on_exit(fn ->
      File.rm(sock_path)
    end)

    {:ok, sock_path: sock_path}
  end

  test "usable_socket? returns false for non-existent path" do
    refute Agent.usable_socket?("/tmp/non_existent_#{System.unique_integer([:positive])}.sock")
    refute Agent.usable_socket?(nil)
    refute Agent.usable_socket?("")
  end

  test "usable_socket? returns false for regular file" do
    refute Agent.usable_socket?("mix.exs")
  end

  test "usable_socket? returns true for real UNIX domain socket", %{sock_path: sock_path} do
    {:ok, listen_socket} =
      :gen_tcp.listen(0, [:binary, ifaddr: {:local, to_charlist(sock_path)}, active: false])

    assert Agent.usable_socket?(sock_path)

    :gen_tcp.close(listen_socket)
  end

  test "live_socket? returns false for non-existent socket" do
    refute Agent.live_socket?("/tmp/non_existent_#{System.unique_integer([:positive])}.sock")
    refute Agent.live_socket?(nil)
  end

  test "live_socket? returns true for listening socket and false when server closes", %{
    sock_path: sock_path
  } do
    {:ok, listen_socket} =
      :gen_tcp.listen(0, [:binary, ifaddr: {:local, to_charlist(sock_path)}, active: false])

    # 1. Socket is listening -> live_socket? is true
    assert Agent.live_socket?(sock_path, 500)

    # 2. Server closes listening socket (file still on disk as stale socket)
    :gen_tcp.close(listen_socket)

    # File still exists on disk
    assert File.exists?(sock_path)
    assert Agent.usable_socket?(sock_path)

    # But it is no longer listening -> live_socket? must return false
    refute Agent.live_socket?(sock_path, 500)
  end

  test "candidate_socket_paths respects custom_path and environment variable" do
    custom = "/custom/path/agent.sock"
    paths = Agent.candidate_socket_paths(custom)
    assert hd(paths) == custom

    orig_sock = System.get_env("SSH_AUTH_SOCK")

    on_exit(fn ->
      if orig_sock do
        System.put_env("SSH_AUTH_SOCK", orig_sock)
      else
        System.delete_env("SSH_AUTH_SOCK")
      end
    end)

    System.put_env("SSH_AUTH_SOCK", "/env/agent.sock")
    paths_with_env = Agent.candidate_socket_paths()
    assert "/env/agent.sock" in paths_with_env
  end

  test "get_live_socket returns :none when no sockets are live" do
    assert Agent.get_live_socket(
             "/tmp/non_existent_#{System.unique_integer([:positive])}.sock",
             100
           ) ==
             :none
  end

  test "get_live_socket returns {:ok, path} when socket is active", %{sock_path: sock_path} do
    {:ok, listen_socket} =
      :gen_tcp.listen(0, [:binary, ifaddr: {:local, to_charlist(sock_path)}, active: false])

    assert Agent.get_live_socket(sock_path, 500) == {:ok, sock_path}

    :gen_tcp.close(listen_socket)
  end
end
