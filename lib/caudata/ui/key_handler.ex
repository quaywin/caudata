defmodule Caudata.UI.KeyHandler do
  @moduledoc """
  Event router that intercepts global keypresses and dispatches them via
  Caudata.UI.KeyRegistry depending on the active state.
  """

  alias Caudata.UI.KeyRegistry
  alias Caudata.UI.Components.Sidebar

  @doc """
  Normalizes an incoming Ratatui key code and modifiers into standard key_data.
  """
  def normalize_key(code, modifiers \\ [])

  def normalize_key(code, modifiers) when is_binary(code) do
    if String.length(code) == 1 do
      %{key: :char, char: code, modifiers: modifiers}
    else
      mapped_key =
        case String.downcase(code) do
          "up" -> :up
          "down" -> :down
          "left" -> :left
          "right" -> :right
          "tab" -> :tab
          "enter" -> :enter
          "esc" -> :escape
          "escape" -> :escape
          "backspace" -> :backspace
          "f2" -> :f2
          "insert" -> :insert
          "pageup" -> :page_up
          "page_up" -> :page_up
          "pagedown" -> :page_down
          "page_down" -> :page_down
          _ -> nil
        end

      %{key: mapped_key, modifiers: modifiers}
    end
  end

  @doc """
  Main dispatch function for key events.
  Routes events based on modal visibility, active mode, and key type via KeyRegistry.
  """
  def handle_key_event(key_data, model) do
    KeyRegistry.dispatch_key(key_data, model)
  end

  @doc """
  Opens container action modal for active selected container.
  """
  def open_container_action_modal(model) do
    KeyRegistry.open_container_action_modal(model)
  end

  # Backwards compatibility delegators for App module/tests
  def select_item(item, model), do: Sidebar.select_item(item, model)
  def select_next_item(model), do: Sidebar.select_next_item(model)
  def select_prev_item(model), do: Sidebar.select_prev_item(model)
  def list_visible_items(model), do: Sidebar.list_visible_items(model)
end
