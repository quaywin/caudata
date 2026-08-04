defmodule Caudata.UI.Components.SettingsModal.ConnectionTab do
  @moduledoc """
  Renders the 'SSH Connection' configuration tab in SettingsModal.
  """
  alias ExRatatui.Style
  alias ExRatatui.Text.Line
  alias ExRatatui.Text.Span

  @doc """
  Renders connection settings for the selected profile.
  """
  def render(_state, nil) do
    [
      Line.new([]),
      Line.new([
        Span.new("  No server selected. Go to Servers tab to select or add one.",
          style: %Style{fg: :yellow}
        )
      ])
    ]
  end

  def render(state, profile) do
    is_local = Map.get(profile, :is_local, false)

    fields_config =
      if is_local do
        [
          {"password", "Password:"}
        ]
      else
        [
          {"host_name", "Host/IP (required):"},
          {"port", "Port:"},
          {"user", "User:"},
          {"identity_file", "Identity File (path):"},
          {"password", "Password:"}
        ]
      end

    form_lines =
      Enum.with_index(fields_config)
      |> Enum.flat_map(fn {{key, label}, index} ->
        active = state.settings_connection_focus_idx == index
        prefix = if active, do: "> ", else: "  "
        label_color = if active, do: :cyan, else: :white
        value_color = if active, do: :green, else: :white
        value = Map.get(state.settings_connection_fields || %{}, key, "")

        masked_value =
          if key == "password", do: String.duplicate("*", String.length(value)), else: value

        display_value = if active, do: masked_value <> "█", else: masked_value

        [
          Line.new([Span.new(prefix), Span.new(label, style: %Style{fg: label_color})]),
          Line.new([
            Span.new("    "),
            Span.new(display_value, style: %Style{fg: value_color})
          ])
        ]
      end)

    num_fields = length(fields_config)
    save_active = state.settings_connection_focus_idx == num_fields
    cancel_active = state.settings_connection_focus_idx == num_fields + 1

    buttons_line =
      Line.new([
        Span.new(
          if(save_active, do: "> [ Save Connection ]   ", else: "  [ Save Connection ]   "),
          style: %Style{fg: if(save_active, do: :green, else: :white)}
        ),
        Span.new(if(cancel_active, do: "> [ Cancel ]", else: "  [ Cancel ]"),
          style: %Style{fg: if(cancel_active, do: :red, else: :white)}
        )
      ])

    status_lines =
      if state.settings_status_msg do
        color =
          if String.starts_with?(state.settings_status_msg, "Error"), do: :red, else: :yellow

        [
          Line.new([]),
          Line.new([
            Span.new("  ℹ ", style: %Style{fg: color}),
            Span.new(state.settings_status_msg, style: %Style{fg: color})
          ])
        ]
      else
        []
      end

    [Line.new([]) | form_lines] ++ [Line.new([]), buttons_line] ++ status_lines
  end
end
