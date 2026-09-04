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
      Caudata.UI.ViewHelper.render_form_fields(
        fields_config,
        state.settings_connection_fields,
        state.settings_connection_focus_idx
      )

    num_fields = length(fields_config)
    save_active = state.settings_connection_focus_idx == num_fields
    cancel_active = state.settings_connection_focus_idx == num_fields + 1

    buttons_line = Caudata.UI.ViewHelper.render_action_buttons(save_active, cancel_active)

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
