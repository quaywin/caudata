defmodule Caudata.UI.Components.Footer do
  @moduledoc """
  Renders the shortcut guidelines and status stats at the bottom of the interface
  dynamically from Caudata.UI.KeyRegistry.
  """
  alias ExRatatui.Style
  alias ExRatatui.Text.Line
  alias ExRatatui.Text.Span
  alias ExRatatui.Widgets.Paragraph

  alias Caudata.UI.KeyRegistry

  @doc """
  Renders the footer paragraph displaying shortcuts dynamically based on the current state.
  """
  def render(state) do
    shortcuts = KeyRegistry.get_shortcuts(state)

    footer_spans =
      Enum.map(shortcuts, fn s ->
        modifiers = if Map.get(s, :bold, false), do: [:bold], else: []
        Span.new(s.key <> " " <> s.label, style: %Style{fg: s.color, modifiers: modifiers})
      end)

    # Append additional system status info (Update notice & line capacity)
    footer_spans =
      if Map.get(state, :update_available) do
        footer_spans ++
          [
            Span.new(
              " | Update #{state.update_available} available! Run 'caudata upgrade'",
              style: %Style{fg: :green}
            )
          ]
      else
        footer_spans
      end

    selected_profile_id = Map.get(state, :selected_profile_id)
    selected_container_id = Map.get(state, :selected_container_id)
    buffer_sizes = Map.get(state, :buffer_sizes, %{})

    current_src_id =
      cond do
        selected_profile_id && selected_container_id ->
          "#{selected_profile_id}/#{selected_container_id}"

        selected_profile_id ->
          selected_profile_id

        true ->
          nil
      end

    size = if current_src_id, do: Map.get(buffer_sizes, current_src_id, 0), else: 0

    capacity =
      if Process.whereis(Caudata.ConfigStore) do
        Caudata.ConfigStore.get_setting(Caudata.ConfigStore, :global, :capacity, 1000)
      else
        1000
      end

    final_spans =
      if size > 0 do
        footer_spans ++ [Span.new(" | Lines: #{size}/#{capacity}")]
      else
        footer_spans
      end

    %Paragraph{
      text: [Line.new(final_spans)]
    }
  end
end
