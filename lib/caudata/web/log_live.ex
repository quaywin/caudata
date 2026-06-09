defmodule Caudata.Web.LogLive do
  use PhoenixExRatatui.LiveView

  # We override the default tui_* functions injected by the macro.
  # Guard with Code.ensure_loaded/1 to avoid crashing when Caudata.UI.App
  # is not available (e.g. code reloader purge, non-TUI env).

  def tui_mount(opts) do
    if loaded?(), do: Caudata.UI.App.mount(opts), else: {:ok, %{}}
  end

  def tui_render(state, frame) do
    if loaded?(), do: Caudata.UI.App.render(state, frame), else: []
  end

  def tui_handle_event(event, state) do
    if loaded?(), do: Caudata.UI.App.handle_event(event, state), else: {:noreply, state}
  end

  def tui_handle_info(msg, state) do
    if loaded?(), do: Caudata.UI.App.handle_info(msg, state), else: {:noreply, state}
  end

  def tui_terminate(reason, state) do
    if loaded?(), do: Caudata.UI.App.terminate(reason, state), else: :ok
  end

  defp loaded? do
    match?({:module, _}, Code.ensure_loaded(Caudata.UI.App))
  end
end
