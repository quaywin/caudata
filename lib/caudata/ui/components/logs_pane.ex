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
  alias ExRatatui.Widgets.Scrollbar

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
        render_disabled_pane(state, selected_profile, logs_area)

      selected_profile ->
        render_active_pane(state, logs_area, selected_profile)

      true ->
        render_empty_pane(state, logs_area)
    end
  end

  @doc """
  Delegates keyboard events to the Event Handler.
  """
  def handle_key(key, key_data, model) do
    EventHandler.handle_key(key, key_data, model)
  end

  # ── Private Rendering Helpers ───────────────────────────────────────

  defp render_disabled_pane(state, selected_profile, logs_area) do
    active_panel = Map.get(state, :active_panel, :sidebar)
    is_active = active_panel == :logs or Map.get(state, :logs_full_screen, false)
    border_color = if is_active, do: :cyan, else: :dark_gray
    title_prefix = if is_active, do: " [3]", else: " "

    outer = %Block{
      title: "#{title_prefix}Logs: #{selected_profile.id} (disabled) ",
      borders: [:all],
      border_type: :rounded,
      border_style: %Style{fg: border_color}
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

  defp render_empty_pane(state, logs_area) do
    active_panel = Map.get(state, :active_panel, :sidebar)
    is_active = active_panel == :logs or Map.get(state, :logs_full_screen, false)
    border_color = if is_active, do: :cyan, else: :dark_gray
    title_prefix = if is_active, do: " [3]", else: " "

    outer = %Block{
      title: "#{title_prefix}Caudata Logs ",
      borders: [:all],
      border_type: :rounded,
      border_style: %Style{fg: border_color}
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
    active_panel = Map.get(state, :active_panel, :sidebar)
    is_active = active_panel == :logs or Map.get(state, :logs_full_screen, false)
    border_color = if is_active, do: :cyan, else: :dark_gray
    title_prefix = if is_active, do: " [3]", else: " "

    inner_area = ViewHelper.inner_rect(logs_area)
    inner_width = inner_area.width
    displayed_logs = ViewHelper.get_displayed_logs(state)

    # Determine layout rects and available viewport height
    {logs_content_rect, extra_widgets} =
      if state.mode == :searching or state.filter_regex != "" do
        [content_rect, logs_filter_divider_rect, logs_filter_rect] =
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

        {content_rect,
         [
           {divider_widget, logs_filter_divider_rect},
           {filter_widget, logs_filter_rect}
         ]}
      else
        {inner_area, []}
      end

    viewport_height = max(1, logs_content_rect.height)
    total_count = length(displayed_logs)

    prefix_width = if Map.get(state, :show_timestamps, false), do: 22, else: 2
    wrap_width = max(1, inner_width - prefix_width)

    # Calculate Virtual Windowing slice parameters using exact wrapped line mapping
    visible_buffer = 10

    {start_idx, take_count, paragraph_scroll_y} =
      case state.logs_scroll_y do
        :bottom ->
          cnt = viewport_height + visible_buffer
          st = max(0, total_count - cnt)
          {st, cnt, :bottom}

        val when is_integer(val) ->
          total_wrapped_lines = ViewHelper.count_wrapped_lines(displayed_logs, wrap_width)
          max_scroll = max(0, total_wrapped_lines - viewport_height)
          target_line = min(max(0, val), max_scroll)

          find_slice_for_wrapped_line(
            displayed_logs,
            target_line,
            wrap_width,
            viewport_height,
            visible_buffer
          )
      end

    visible_logs = Enum.slice(displayed_logs, start_idx, take_count)

    # Build wrapped lines for ONLY the visible window slice with raw-log-index tracking
    wrapped_with_indices =
      visible_logs
      |> Enum.with_index(start_idx)
      |> Enum.flat_map(fn {%{timestamp: ts, stream: stream, message: line}, idx} ->
        {spans, is_err_level} = LogFormatter.format_line_with_meta(line)
        is_error = stream == :stderr or is_err_level

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

    title = build_title(state, selected_profile, selection_range, title_prefix)

    outer = %Block{
      title: title,
      borders: [:all],
      border_type: :rounded,
      border_style: %Style{fg: border_color}
    }

    wrapped_lines_count = length(wrapped_with_indices)

    scroll_y =
      case paragraph_scroll_y do
        :bottom -> max(0, wrapped_lines_count - viewport_height)
        val when is_integer(val) -> min(val, max(0, wrapped_lines_count - 1))
      end

    logs_widget = %Paragraph{
      text: log_lines,
      scroll: {scroll_y, 0}
    }

    total_wrapped_lines = ViewHelper.count_wrapped_lines(displayed_logs, wrap_width)

    content =
      if total_wrapped_lines > viewport_height do
        max_scroll = max(1, total_wrapped_lines - viewport_height)

        current_scroll_pos =
          case state.logs_scroll_y do
            :bottom -> max_scroll
            val when is_integer(val) -> min(max(0, val), max_scroll)
          end

        scrollbar_widget = %Scrollbar{
          orientation: :vertical_right,
          content_length: max_scroll,
          position: current_scroll_pos,
          thumb_style: %Style{fg: :cyan},
          track_style: %Style{fg: :dark_gray}
        }

        [{logs_widget, logs_content_rect}, {scrollbar_widget, inner_area} | extra_widgets]
      else
        [{logs_widget, logs_content_rect} | extra_widgets]
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

  defp build_title(state, selected_profile, selection_range, title_prefix) do
    base =
      if state.selected_container_id do
        containers = Map.get(state.containers, selected_profile.id, [])

        container =
          Enum.find(containers, &(to_string(&1.id) == to_string(state.selected_container_id)))

        container_name = if container, do: container.name, else: state.selected_container_id
        "#{title_prefix}Logs: #{selected_profile.id} (container: #{container_name})"
      else
        "#{title_prefix}Logs: #{selected_profile.id}"
      end

    visual_suffix =
      cond do
        state.mode == :selecting and selection_range != nil ->
          count = Enum.count(selection_range)
          " [VISUAL: #{count} lines]"

        state.mode == :selecting and is_integer(state.visual_cursor) ->
          " [CURSOR: line #{state.visual_cursor + 1}]"

        true ->
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


  defp format_docker_timestamp(ts) when is_binary(ts) do
    ts
    |> String.slice(0, 19)
    |> String.replace("T", " ")
  end

  defp format_docker_timestamp(_), do: String.duplicate(" ", 19)

  defp find_slice_for_wrapped_line(
         displayed_logs,
         target_line,
         wrap_width,
         viewport_height,
         visible_buffer
       ) do
    total_count = length(displayed_logs)

    {start_idx, line_offset} =
      displayed_logs
      |> Enum.reduce_while({0, 0}, fn item, {idx, accum_lines} ->
        item_lines = ViewHelper.visual_line_count(item, wrap_width)

        if accum_lines + item_lines > target_line do
          offset = max(0, target_line - accum_lines)
          {:halt, {idx, offset}}
        else
          {:cont, {idx + 1, accum_lines + item_lines}}
        end
      end)
      |> case do
        {:cont, {final_idx, _}} -> {max(0, final_idx - 1), 0}
        res -> res
      end

    start_idx = min(start_idx, max(0, total_count - 1))
    take_count = viewport_height + visible_buffer
    {start_idx, take_count, line_offset}
  end
end
