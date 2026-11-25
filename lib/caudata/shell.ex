defmodule Caudata.Shell do
  @moduledoc """
  Shared POSIX shell quoting and sudo-wrapping helpers for remote SSH and local execution.
  """

  @doc """
  Safely quotes an argument for POSIX `sh` using single quotes so no parameter
  expansion, command substitution, or globbing can occur.
  """
  @spec quote_arg(String.Chars.t() | nil) :: String.t()
  def quote_arg(nil), do: "''"

  def quote_arg(value) do
    str = to_string(value)
    "'" <> String.replace(str, "'", "'\\''") <> "'"
  end

  @doc """
  Wraps an inner POSIX `sh` script in `sh -c "..."` so non-POSIX login shells
  (such as fish or zsh) execute the inner script predictably.
  """
  @spec wrap_subshell(String.t()) :: String.t()
  def wrap_subshell(inner_script) when is_binary(inner_script) do
    escaped_for_dq =
      inner_script
      |> String.replace("\\", "\\\\")
      |> String.replace("\"", "\\\"")
      |> String.replace("$", "\\$")
      |> String.replace("`", "\\`")

    "sh -c \"#{escaped_for_dq}\""
  end

  @doc """
  Wraps a command with `sudo` when available (using `password` via stdin if provided,
  or `sudo -n` otherwise), falling back to plain `sh -c`.
  """
  @spec wrap_sudo(String.t(), String.t() | nil) :: String.t()
  def wrap_sudo(cmd, password \\ nil) when is_binary(cmd) do
    escaped_cmd = String.replace(cmd, "'", "'\\''")

    inner_script =
      if is_binary(password) and password != "" do
        escaped_password = String.replace(password, "'", "'\\''")

        "if command -v sudo >/dev/null 2>&1; then " <>
          "if true <&0 2>/dev/null; then exec 3<&0; fi; " <>
          "printf '%s\\n' '#{escaped_password}' | sudo -S -p '' sh -c 'if true <&3 2>/dev/null; then exec 0<&3 3<&-; fi; #{escaped_cmd}' 2>/dev/null || sh -c '#{escaped_cmd}'; " <>
          "else sh -c '#{escaped_cmd}'; fi"
      else
        "if command -v sudo >/dev/null 2>&1; then " <>
          "sudo -n sh -c '#{escaped_cmd}' 2>/dev/null || sh -c '#{escaped_cmd}'; " <>
          "else sh -c '#{escaped_cmd}'; fi"
      end

    wrap_subshell(inner_script)
  end

  @doc """
  Wraps a long-running streaming command with `sudo` and a signal trap so the remote
  child process is terminated promptly when the SSH channel closes.
  """
  @spec wrap_supervised_sudo(String.t(), String.t() | nil) :: String.t()
  def wrap_supervised_sudo(base_cmd, password \\ nil) when is_binary(base_cmd) do
    escaped_cmd = String.replace(base_cmd, "'", "'\\''")

    inner_script =
      if is_binary(password) and password != "" do
        escaped_password = String.replace(password, "'", "'\\''")

        "if command -v sudo >/dev/null 2>&1; then " <>
          "if true <&0 2>/dev/null; then exec 3<&0; fi; " <>
          "printf '%s\\n' '#{escaped_password}' | sudo -S -p '' sh -c 'if true <&3 2>/dev/null; then exec 0<&3 3<&-; fi; exec #{escaped_cmd}'; " <>
          "else sh -c 'exec #{escaped_cmd}'; fi & " <>
          "pid=$!; trap 'kill $pid 2>/dev/null' EXIT HUP INT TERM; wait $pid 2>/dev/null; rc=$?; kill $pid 2>/dev/null; exit $rc"
      else
        "if command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then " <>
          "exec sudo -n sh -c 'exec #{escaped_cmd}'; " <>
          "else exec sh -c 'exec #{escaped_cmd}'; fi & " <>
          "pid=$!; trap 'kill $pid 2>/dev/null' EXIT HUP INT TERM; wait $pid 2>/dev/null; rc=$?; kill $pid 2>/dev/null; exit $rc"
      end

    wrap_subshell(inner_script)
  end
end
