defmodule Caudata.SSH.Agent do
  @moduledoc """
  Manages discovery, validation, and liveness probing of SSH Agent UNIX domain sockets.

  Inspired by the socket validation and fail-fast probing mechanisms in tools like Herdr,
  this module ensures that Caudata only attempts to communicate with an SSH Agent if the
  socket actually exists, is of type S_IFSOCK, and is actively responding to connections.
  """

  import Bitwise
  require Logger

  @default_probe_timeout_ms 300
  @s_ifsock 0o140000
  @s_ifmt 0o170000

  @doc """
  Returns a list of candidate SSH agent socket paths in order of preference:
  1. An explicit custom socket path (if provided)
  2. The `$SSH_AUTH_SOCK` environment variable
  3. Well-known standard agent paths (e.g. 1Password SSH Agent on macOS)
  """
  @spec candidate_socket_paths(String.t() | nil) :: [String.t()]
  def candidate_socket_paths(custom_path \\ nil) do
    explicit =
      case custom_path do
        path when is_binary(path) and path != "" -> [Path.expand(path)]
        _ -> []
      end

    env_sock =
      case System.get_env("SSH_AUTH_SOCK") do
        path when is_binary(path) and path != "" -> [Path.expand(path)]
        _ -> []
      end

    # Standard fallback paths for environments where $SSH_AUTH_SOCK is not inherited
    known_paths =
      case :os.type() do
        {:unix, :darwin} ->
          [Path.expand("~/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock")]

        {:unix, :linux} ->
          [Path.expand("~/.1password/agent.sock")]

        _ ->
          []
      end

    (explicit ++ env_sock ++ known_paths)
    |> Enum.uniq()
  end

  @doc """
  Checks if the path exists, is a UNIX domain socket (S_IFSOCK), and is accessible.
  """
  @spec usable_socket?(String.t()) :: boolean()
  def usable_socket?(path) when is_binary(path) do
    expanded = Path.expand(path)

    case File.stat(expanded) do
      {:ok, %File.Stat{mode: mode}} when band(mode, @s_ifmt) == @s_ifsock ->
        true

      _ ->
        false
    end
  rescue
    _ -> false
  end

  def usable_socket?(_), do: false

  @doc """
  Probes whether an active process is listening on the UNIX domain socket.
  Performs a fast TCP local connect with a short timeout (default 300ms) to ensure
  stale or dead sockets are detected immediately without blocking.
  """
  @spec live_socket?(String.t(), non_neg_integer()) :: boolean()
  def live_socket?(path, timeout_ms \\ @default_probe_timeout_ms)

  def live_socket?(path, timeout_ms) when is_binary(path) do
    expanded = Path.expand(path)

    if usable_socket?(expanded) do
      char_path = to_charlist(expanded)

      case :gen_tcp.connect({:local, char_path}, 0, [:binary, active: false], timeout_ms) do
        {:ok, socket} ->
          :gen_tcp.close(socket)
          true

        {:error, reason} ->
          Logger.debug("SSH Agent socket #{expanded} failed liveness probe: #{inspect(reason)}")
          false
      end
    else
      false
    end
  rescue
    e ->
      Logger.debug("SSH Agent socket #{path} probe exception: #{inspect(e)}")
      false
  end

  def live_socket?(_, _), do: false

  @doc """
  Finds the first usable and live SSH Agent socket from the candidate list.
  Returns `{:ok, socket_path}` or `:none`.
  """
  @spec get_live_socket(String.t() | nil, non_neg_integer()) :: {:ok, String.t()} | :none
  def get_live_socket(custom_path \\ nil, timeout_ms \\ @default_probe_timeout_ms) do
    candidate_socket_paths(custom_path)
    |> Enum.find_value(:none, fn path ->
      if live_socket?(path, timeout_ms) do
        {:ok, path}
      else
        nil
      end
    end)
  end
end
