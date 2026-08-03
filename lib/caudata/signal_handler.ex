defmodule Caudata.SignalHandler do
  @moduledoc """
  Handles OS signals (SIGHUP, SIGTERM) when running in terminal (TUI) mode,
  ensuring the process exits cleanly if the terminal emulator window or SSH session is closed.
  """
  @behaviour :gen_event

  def init(state), do: {:ok, state}

  def handle_event(signal, state) when signal in [:sighup, :sigterm] do
    System.halt(0)
    {:ok, state}
  end

  def handle_event(_event, state), do: {:ok, state}
  def handle_call(_request, state), do: {:ok, :ok, state}
  def handle_info(_info, state), do: {:ok, state}
  def terminate(_reason, _state), do: :ok
end
