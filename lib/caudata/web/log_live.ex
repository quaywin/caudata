defmodule Caudata.Web.LogLive do
  use PhoenixExRatatui.LiveView

  # We override the default tui_* functions injected by the macro.

  def tui_mount(opts) do
    Caudata.UI.App.mount(opts)
  end

  def tui_render(state, frame) do
    Caudata.UI.App.render(state, frame)
  end

  def tui_handle_event(event, state) do
    Caudata.UI.App.handle_event(event, state)
  end

  def tui_handle_info(msg, state) do
    Caudata.UI.App.handle_info(msg, state)
  end

  def tui_terminate(reason, state) do
    Caudata.UI.App.terminate(reason, state)
  end
end
