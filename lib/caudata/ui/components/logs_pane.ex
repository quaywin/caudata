defmodule Caudata.UI.Components.LogsPane do
  @moduledoc """
  Renders the main logs panel and delegates its keyboard events to `LogsPane.EventHandler`.
  """
  alias ExRatatui.Layout
  alias ExRatatui.Style
  alias ExRatatui.Text.Line
  alias ExRatatui.Text.Span
  alias ExRatatui.Widgets.Block
  alias ExRatatui.Widgets.Paragraph

  alias Caudata.UI.ViewHelper
  alias Caudata.UI.LogFormatter
  alias Caudata.UI.Components.LogsPane.EventHandler

  @doc """
  Main render function for the logs pane.
  """
  def render(state, logs_area) do
    selected_profile = Enum.find(state.profiles, fn p -> p.id == state.selected_profile_id end)

    cond do
      selected_profile && not Map.get(selected_profile, :enabled, true) ->
        render_disabled_pane(selected_profile, logs_area)

      selected_profile ->
        render_active_pane(state, logs_area, selected_profile)

      true ->
        render_empty_pane(logs_area)
    end
  end

  @doc """
  Delegates keyboard events to the Event Handler.
  """
  def handle_key(key, key_data, model) do
    EventHandler.handle_key(key, key_data, model)
  end

  # ── Private Rendering Helpers ───────────────────────────────────────

  defp render_disabled_pane(selected_profile, logs_area) do
    outer = %Block{
      title: " Logs: #{selected_profile.id} (disabled) ",
      borders: [:all],
      border_type: :rounded
    }

    inner_area = ViewHelper.inner_rect(logs_area)

    logs_widget = %Paragraph{
      text: [
        Line.new([Span.new("This server is currently disabled.")]),
        Line.new([Span.new("Enable it in Settings [s] to connect and view logs.")])
      ],
      alignment: :center
    }

    {outer, [{logs_widget, inner_area}]}
  end

  defp render_empty_pane(logs_area) do
    outer = %Block{
      title: " Caudata Logs ",
      borders: [:all],
      border_type: :rounded
    }

    inner_area = ViewHelper.inner_rect(logs_area)

    logs_widget = %Paragraph{
      text: [
        Line.new([Span.new("No active server target.")]),
        Line.new([Span.new("Press [a] to add a server from ~/.ssh/config or manually.")])
      ],
      alignment: :center
    }

    {outer, [{logs_widget, inner_area}]}
  end

  defp render_active_pane(state, logs_area, selected_profile) do
    inner_area = ViewHelper.inner_rect(logs_area)
    inner_width = inner_area.width
    displayed_logs = ViewHelper.get_displayed_logs(state)

    prefix_width = if Map.get(state, :show_timestamps, false), do: 22, else: 2
    wrap_width = max(1, inner_width - prefix_width)

    # Build wrapped lines with raw-log-index tracking
    wrapped_with_indices =
      displayed_logs
      |> Enum.with_index()
      |> Enum.flat_map(fn {%{timestamp: ts, stream: stream, message: line}, idx} ->
        spans = LogFormatter.format_line(line)
        is_error = stream == :stderr or error_line?(line)

        ViewHelper.wrap_spans(spans, wrap_width)
        |> Enum.with_index()
        |> Enum.map(fn {chunk_spans, chunk_idx} ->
          prefix_span =
            cond do
              is_error ->
                Span.new("┃ ", style: %Style{fg: :red, modifiers: [:bold]})

              true ->
                Span.new("  ", style: %Style{})
            end

          final_spans =
            if Map.get(state, :show_timestamps, false) do
              ts_span =
                if chunk_idx == 0 and ts do
                  Span.new(format_docker_timestamp(ts) <> " ", style: %Style{fg: :dark_gray})
                else
                  Span.new(String.duplicate(" ", 20), style: %Style{})
                end

              [prefix_span, ts_span | chunk_spans]
            else
              [prefix_span | chunk_spans]
            end

          {final_spans, idx}
        end)
      end)

    selection_range = ViewHelper.get_selection_range(state)
    log_lines = build_log_lines(wrapped_with_indices, state, selection_range)

    title = build_title(state, selected_profile, selection_range)

    outer = %Block{
      title: title,
      borders: [:all],
      border_type: :rounded
    }

    content =
      if state.mode == :searching or state.filter_regex != "" do
        [logs_content_rect, logs_filter_divider_rect, logs_filter_rect] =
          Layout.split(inner_area, :vertical, [
            {:min, 0},
            {:length, 1},
            {:length, 1}
          ])

        filter_widget = render_filter_widget(state)

        divider_widget = %Paragraph{
          text: String.duplicate("─", logs_filter_divider_rect.width),
          style: %Style{fg: :dark_gray}
        }

        wrapped_lines_count = length(wrapped_with_indices)
        max_scroll = max(0, wrapped_lines_count - logs_content_rect.height)

        scroll_y = get_scroll_y(state.logs_scroll_y, max_scroll)

        logs_widget = %Paragraph{
          text: log_lines,
          scroll: {scroll_y, 0}
        }

        [
          {logs_widget, logs_content_rect},
          {divider_widget, logs_filter_divider_rect},
          {filter_widget, logs_filter_rect}
        ]
      else
        wrapped_lines_count = length(wrapped_with_indices)
        max_scroll = max(0, wrapped_lines_count - inner_area.height)

        scroll_y = get_scroll_y(state.logs_scroll_y, max_scroll)

        logs_widget = %Paragraph{
          text: log_lines,
          scroll: {scroll_y, 0}
        }

        [{logs_widget, inner_area}]
      end

    {outer, content}
  end

  defp build_log_lines(wrapped_with_indices, state, selection_range) do
    Enum.map(wrapped_with_indices, fn {spans, raw_idx} ->
      is_cursor = state.mode == :selecting and raw_idx == state.visual_cursor

      is_selected =
        state.mode == :selecting and selection_range != nil and raw_idx in selection_range

      line_style =
        cond do
          is_cursor -> %Style{bg: {:indexed, 67}}
          is_selected -> %Style{bg: {:indexed, 24}}
          true -> %Style{}
        end

      Line.new(spans, style: line_style)
    end)
  end

  defp build_title(state, selected_profile, selection_range) do
    base =
      if state.selected_container_id do
        containers = Map.get(state.containers, selected_profile.id, [])

        container =
          Enum.find(containers, &(to_string(&1.id) == to_string(state.selected_container_id)))

        container_name = if container, do: container.name, else: state.selected_container_id
        " Logs: #{selected_profile.id} (container: #{container_name})"
      else
        " Logs: #{selected_profile.id}"
      end

    visual_suffix =
      if state.mode == :selecting and selection_range != nil do
        count = Enum.count(selection_range)
        " [VISUAL: #{count} lines]"
      else
        ""
      end

    freeze_suffix =
      if Map.get(state, :freeze, false) do
        " [PAUSED]"
      else
        ""
      end

    suffix =
      case {visual_suffix, freeze_suffix} do
        {"", ""} -> " "
        {vis, ""} -> " " <> vis <> " "
        {"", frz} -> " " <> frz <> " "
        {vis, frz} -> " " <> vis <> frz <> " "
      end

    base <> suffix
  end

  defp render_filter_widget(state) do
    cond do
      state.mode == :searching ->
        fg = if state.filter_error, do: :red, else: :cyan

        %Paragraph{
          text: [
            Line.new([
              Span.new(" Filter (regex): /", style: %Style{fg: fg, modifiers: [:bold]}),
              Span.new(state.filter_regex, style: %Style{fg: :white}),
              if(state.filter_error,
                do: Span.new(" (invalid regex)", style: %Style{fg: :red}),
                else: Span.new("")
              )
            ])
          ]
        }

      state.filter_regex != "" ->
        %Paragraph{
          text: [
            Line.new([
              Span.new(" Filter active: /", style: %Style{fg: :green}),
              Span.new(state.filter_regex, style: %Style{fg: :white}),
              Span.new(" (Press Esc to clear)", style: %Style{fg: :dark_gray})
            ])
          ]
        }

      true ->
        nil
    end
  end

  defp get_scroll_y(:bottom, max_scroll), do: max_scroll
  defp get_scroll_y(val, max_scroll) when is_integer(val), do: min(val, max_scroll)

  defp format_docker_timestamp(ts) when is_binary(ts) do
    ts
    |> String.slice(0, 19)
    |> String.replace("T", " ")
  end

  defp format_docker_timestamp(_), do: String.duplicate(" ", 19)

  defp error_line?(line) do
    case Regex.named_captures(LogFormatter.log_regex(), line) do
      %{
        "bracket_lvl" => bracket_lvl,
        "colon_lvl" => colon_lvl,
        "bare_lvl" => bare_lvl
      } ->
        lvl =
          cond do
            bracket_lvl != "" -> bracket_lvl
            colon_lvl != "" -> colon_lvl
            bare_lvl != "" -> bare_lvl
            true -> nil
          end

        if lvl, do: LogFormatter.error_level?(lvl), else: false

      _ ->
        false
    end
  end
end
