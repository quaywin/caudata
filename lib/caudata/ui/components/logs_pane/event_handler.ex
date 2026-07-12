defmodule Caudata.UI.Components.LogsPane.EventHandler do
  @moduledoc """
  Handles keyboard events and state transitions for the LogsPane component.
  """
  alias Caudata.UI.ViewHelper

  @doc """
  Handles keys for scrolling logs, regex character typing, visual selection, and clipboard copy.
  """
  def handle_key(key, key_data, model) do
    case model.mode do
      :searching ->
        handle_search_key(key, key_data, model)

      :selecting ->
        handle_visual_mode_key(key, key_data, model)

      _ ->
        handle_normal_mode_key(key, key_data, model)
    end
  end

  # ── Visual Select Mode ──────────────────────────────────────────────

  defp handle_visual_mode_key(key, key_data, model) do
    norm_key = if key == :char, do: Map.get(key_data, :char), else: key
    displayed_logs = ViewHelper.get_displayed_logs(model)
    last_idx = max(0, length(displayed_logs) - 1)

    case norm_key do
      # j/k: move cursor only, clear selection
      "j" ->
        new_cursor = min(model.visual_cursor + 1, last_idx)
        new_model = %{model | visual_cursor: new_cursor, visual_anchor: nil}
        {auto_scroll_to_cursor(new_model, displayed_logs), []}

      "k" ->
        move_cursor_up(model, displayed_logs, nil)

      # ↑/↓: start/extend selection from cursor
      :down ->
        anchor = model.visual_anchor || model.visual_cursor
        new_cursor = min(model.visual_cursor + 1, last_idx)
        new_model = %{model | visual_cursor: new_cursor, visual_anchor: anchor}
        {auto_scroll_to_cursor(new_model, displayed_logs), []}

      :up ->
        anchor = model.visual_anchor || model.visual_cursor
        move_cursor_up(model, displayed_logs, anchor)

      "y" ->
        copy_selected_logs(model, displayed_logs)

      _ ->
        {model, []}
    end
  end

  defp move_cursor_up(model, displayed_logs, anchor) do
    new_cursor = max(model.visual_cursor - 1, 0)
    new_model = %{model | visual_cursor: new_cursor, visual_anchor: anchor}
    scrolled = auto_scroll_to_cursor(new_model, displayed_logs)

    # Load more history when cursor is at top and scroll is at 0
    if new_cursor == 0 do
      inner_width = ViewHelper.get_logs_inner_width(model)
      wrapped_lines_count = ViewHelper.count_wrapped_lines(displayed_logs, inner_width)
      max_scroll = max(0, wrapped_lines_count - ViewHelper.get_logs_pane_height(model))

      current_scroll =
        case model.logs_scroll_y do
          :bottom -> max_scroll
          val -> val
        end

      if current_scroll == 0 and max_scroll > 0 and model.logs_fetch_limit < 1000 and
           not model.loading_history do
        new_limit = min(model.logs_fetch_limit + 100, 1000)

        load_model = %{
          scrolled
          | logs_fetch_limit: new_limit,
            loading_history: true,
            logs_len_before_history_load: length(model.logs)
        }

        {load_model, [{:command, {:load_history, new_limit}}]}
      else
        {scrolled, []}
      end
    else
      {scrolled, []}
    end
  end

  defp copy_selected_logs(model, displayed_logs) do
    case ViewHelper.get_selection_range(model) do
      nil ->
        # No selection: copy single line at cursor
        case Enum.at(displayed_logs, model.visual_cursor) do
          %{message: line} ->
            notification_msg =
              case ViewHelper.copy_to_clipboard(line) do
                :ok -> "Copied 1 log line to clipboard!"
                {:error, _reason} -> "Failed to copy to clipboard"
              end

            {%{
               model
               | notification: {notification_msg, 25},
                 mode: :browsing,
                 visual_anchor: nil,
                 visual_cursor: nil
             }, []}

          _ ->
            {model, []}
        end

      range ->
        count = Enum.count(range)
        selected_logs = Enum.slice(displayed_logs, range)

        text =
          selected_logs
          |> Enum.map(fn %{message: line} -> line end)
          |> Enum.join("\n")

        notification_msg =
          case ViewHelper.copy_to_clipboard(text) do
            :ok -> "Copied #{count} log lines to clipboard!"
            {:error, _reason} -> "Failed to copy to clipboard"
          end

        {%{
           model
           | notification: {notification_msg, 25},
             mode: :browsing,
             visual_anchor: nil,
             visual_cursor: nil
         }, []}
    end
  end

  defp auto_scroll_to_cursor(model, displayed_logs) do
    inner_width = ViewHelper.get_logs_inner_width(model)
    logs_height = ViewHelper.get_logs_pane_height(model)
    cursor_idx = model.visual_cursor

    # Calculate the wrapped line index where the cursor starts
    cursor_wrapped_start =
      displayed_logs
      |> Enum.take(cursor_idx)
      |> Enum.reduce(0, fn line, acc ->
        acc + ViewHelper.visual_line_count(line, inner_width)
      end)

    cursor_line_count =
      ViewHelper.visual_line_count(Enum.at(displayed_logs, cursor_idx, ""), inner_width)

    cursor_wrapped_end = cursor_wrapped_start + cursor_line_count - 1

    wrapped_lines_count = ViewHelper.count_wrapped_lines(displayed_logs, inner_width)
    max_scroll = max(0, wrapped_lines_count - logs_height)

    current_scroll =
      case model.logs_scroll_y do
        :bottom -> max_scroll
        val -> val
      end

    new_scroll =
      cond do
        cursor_wrapped_start < current_scroll ->
          cursor_wrapped_start

        cursor_wrapped_end >= current_scroll + logs_height ->
          max(0, cursor_wrapped_end - logs_height + 1)

        true ->
          current_scroll
      end

    new_scroll = min(new_scroll, max_scroll)

    if model.mode != :selecting and new_scroll >= max_scroll do
      %{model | logs_scroll_y: :bottom}
    else
      %{model | logs_scroll_y: new_scroll}
    end
  end

  # ── Normal / Browsing Mode ──────────────────────────────────────────

  defp handle_normal_mode_key(key, key_data, model) do
    norm_key = if key == :char, do: Map.get(key_data, :char), else: key

    consecutive = Map.get(model, :consecutive_key_count, 0)

    scroll_step =
      cond do
        consecutive > 15 -> 15
        consecutive > 5 -> 6
        true -> 3
      end

    case norm_key do
      "j" ->
        displayed_logs = ViewHelper.get_displayed_logs(model)
        logs_height = ViewHelper.get_logs_pane_height(model)

        inner_width = ViewHelper.get_logs_inner_width(model)

        wrapped_lines_count = ViewHelper.count_wrapped_lines(displayed_logs, inner_width)
        max_scroll = max(0, wrapped_lines_count - logs_height)

        case model.logs_scroll_y do
          :bottom ->
            {model, []}

          val when is_integer(val) ->
            new_scroll = val + scroll_step
            new_scroll = if new_scroll >= max_scroll, do: :bottom, else: new_scroll
            {%{model | logs_scroll_y: new_scroll}, []}
        end

      "k" ->
        if model.selected_profile_id do
          displayed_logs = ViewHelper.get_displayed_logs(model)
          logs_height = ViewHelper.get_logs_pane_height(model)

          inner_width = ViewHelper.get_logs_inner_width(model)

          current_visual_len = ViewHelper.count_wrapped_lines(displayed_logs, inner_width)
          max_scroll = max(0, current_visual_len - logs_height)

          effective_scroll =
            case model.logs_scroll_y do
              :bottom -> max_scroll
              val when is_integer(val) -> val
            end

          if effective_scroll == 0 and max_scroll > 0 and model.logs_fetch_limit < 1000 and
               not model.loading_history do
            new_limit = min(model.logs_fetch_limit + 100, 1000)

            new_model = %{
              model
              | logs_fetch_limit: new_limit,
                loading_history: true,
                logs_len_before_history_load: length(model.logs)
            }

            {new_model, [{:command, {:load_history, new_limit}}]}
          else
            new_scroll = max(0, effective_scroll - scroll_step)

            new_scroll =
              if model.logs_scroll_y == :bottom and new_scroll == max_scroll,
                do: :bottom,
                else: new_scroll

            {%{model | logs_scroll_y: new_scroll}, []}
          end
        else
          {model, []}
        end

      "/" ->
        {%{model | mode: :searching, active_field: :filter_regex}, []}

      "v" ->
        displayed_logs = ViewHelper.get_displayed_logs(model)

        # Only enter visual mode when there are real log lines
        has_real_logs? =
          model.selected_container_id != nil and model.logs != [] and
            displayed_logs not in [
              ["No logs captured yet."],
              ["No container selected. Select a container in the sidebar to view logs."]
            ]

        if has_real_logs? do
          last_idx = max(0, length(displayed_logs) - 1)
          inner_width = ViewHelper.get_logs_inner_width(model)
          logs_height = ViewHelper.get_logs_pane_height(model)
          wrapped_lines_count = ViewHelper.count_wrapped_lines(displayed_logs, inner_width)
          max_scroll = max(0, wrapped_lines_count - logs_height)

          cursor_idx =
            case model.logs_scroll_y do
              :bottom ->
                last_idx

              val when is_integer(val) ->
                scroll_y = min(val, max_scroll)
                get_raw_index_at_scroll(displayed_logs, scroll_y, inner_width)
            end

          new_model =
            %{model | mode: :selecting, visual_anchor: nil, visual_cursor: cursor_idx}
            |> auto_scroll_to_cursor(displayed_logs)

          {new_model, []}
        else
          {%{model | notification: {"No logs to select", 25}}, []}
        end

      "y" ->
        copy_all_logs(model)

      _ ->
        {model, []}
    end
  end

  defp copy_all_logs(model) do
    displayed_logs = ViewHelper.get_displayed_logs(model)

    has_real_logs? =
      model.selected_container_id != nil and
        model.logs != [] and
        displayed_logs not in [
          ["No logs captured yet."],
          ["No container selected. Select a container in the sidebar to view logs."]
        ]

    if has_real_logs? do
      text =
        displayed_logs
        |> Enum.map(fn %{message: line} -> line end)
        |> Enum.join("\n")

      count = length(displayed_logs)

      notification_msg =
        case ViewHelper.copy_to_clipboard(text) do
          :ok -> "Copied #{count} log lines to clipboard!"
          {:error, _reason} -> "Failed to copy to clipboard"
        end

      {%{model | notification: {notification_msg, 25}}, []}
    else
      {%{model | notification: {"No logs to copy", 25}}, []}
    end
  end

  # ── Search Mode ─────────────────────────────────────────────────────

  defp handle_search_key(key, key_data, model) do
    case key do
      :paste ->
        text = Map.get(key_data, :content, "")
        new_val = model.filter_regex <> text

        {error, _compiled} =
          case Regex.compile(new_val) do
            {:ok, re} -> {false, re}
            _ -> {true, nil}
          end

        {%{model | filter_regex: new_val, filter_error: error}, []}

      :backspace ->
        new_val = String.slice(model.filter_regex, 0..-2//1)

        {error, _compiled} =
          case Regex.compile(new_val) do
            {:ok, re} -> {false, re}
            _ -> {true, nil}
          end

        {%{model | filter_regex: new_val, filter_error: error}, []}

      :enter ->
        {%{model | mode: :browsing, active_field: nil}, []}

      :char ->
        char = Map.get(key_data, :char, "")

        if is_binary(char) and char != "" do
          new_val = model.filter_regex <> char

          {error, _compiled} =
            case Regex.compile(new_val) do
              {:ok, re} -> {false, re}
              _ -> {true, nil}
            end

          {%{model | filter_regex: new_val, filter_error: error}, []}
        else
          {model, []}
        end

      ch when is_binary(ch) and byte_size(ch) == 1 ->
        new_val = model.filter_regex <> ch

        {error, _compiled} =
          case Regex.compile(new_val) do
            {:ok, re} -> {false, re}
            _ -> {true, nil}
          end

        {%{model | filter_regex: new_val, filter_error: error}, []}

      _ ->
        {model, []}
    end
  end

  # ── Helpers ─────────────────────────────────────────────────────────

  defp get_raw_index_at_scroll(displayed_logs, scroll_y, inner_width) do
    displayed_logs
    |> Enum.reduce_while({0, 0}, fn line, {acc, idx} ->
      line_len = ViewHelper.visual_line_count(line, inner_width)

      if acc + line_len > scroll_y do
        {:halt, idx}
      else
        {:cont, {acc + line_len, idx + 1}}
      end
    end)
    |> case do
      {_acc, last_idx} -> max(0, last_idx - 1)
      idx -> idx
    end
  end
end
