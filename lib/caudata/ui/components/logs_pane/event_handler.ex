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
      # j/k or ↑/↓: move cursor line-by-line (extends selection if anchor != nil)
      k when k in ["j", :down] ->
        anchor = model.visual_anchor
        new_cursor = min(model.visual_cursor + 1, last_idx)
        new_model = %{model | visual_cursor: new_cursor, visual_anchor: anchor}
        {auto_scroll_to_cursor(new_model, displayed_logs), []}

      k when k in ["k", :up] ->
        anchor = model.visual_anchor
        move_cursor_up(model, displayed_logs, anchor)

      # v or Space: toggle selection anchor (Start / Stop selection at current cursor)
      k when k in ["v", " ", :space] ->
        if model.visual_anchor == nil do
          {%{model | visual_anchor: model.visual_cursor}, []}
        else
          {%{model | visual_anchor: nil}, []}
        end

      "y" ->
        copy_selected_logs(model, displayed_logs)

      "o" ->
        # Swap anchor and cursor (Vim standard visual mode toggle end)
        if model.visual_anchor != nil do
          new_model = %{
            model
            | visual_cursor: model.visual_anchor,
              visual_anchor: model.visual_cursor
          }

          {auto_scroll_to_cursor(new_model, displayed_logs), []}
        else
          {model, []}
        end

      _ ->
        {model, []}
    end
  end

  defp move_cursor_up(model, displayed_logs, anchor) do
    new_cursor = max(model.visual_cursor - 1, 0)
    new_model = %{model | visual_cursor: new_cursor, visual_anchor: anchor}
    scrolled = auto_scroll_to_cursor(new_model, displayed_logs)

    if new_cursor == 0 do
      max_scroll = get_max_scroll(model, displayed_logs)

      current_scroll =
        case model.logs_scroll_y do
          :bottom -> max_scroll
          val -> val
        end

      maybe_trigger_history_fetch(model, scrolled, current_scroll, max_scroll, fn ->
        {scrolled, []}
      end)
    else
      {scrolled, []}
    end
  end

  defp copy_selected_logs(model, displayed_logs) do
    case ViewHelper.get_selection_range(model) do
      nil ->
        case Enum.at(displayed_logs, model.visual_cursor) do
          nil ->
            {model, []}

          entry ->
            text = extract_log_text(entry)
            copy_text_to_clipboard(text, 1, model)
        end

      range ->
        selected_logs = Enum.slice(displayed_logs, range)
        text = selected_logs |> Enum.map(&extract_log_text/1) |> Enum.join("\n")
        copy_text_to_clipboard(text, Enum.count(range), model)
    end
  end

  defp copy_text_to_clipboard(text, count, model) do
    notification_msg =
      case ViewHelper.copy_to_clipboard(text) do
        :ok -> "Copied #{count} log line#{if count > 1, do: "s", else: ""} to clipboard!"
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

  defp extract_log_text(%{message: line}), do: line
  defp extract_log_text(line) when is_binary(line), do: line
  defp extract_log_text(other), do: to_string(other)

  defp auto_scroll_to_cursor(model, displayed_logs) do
    inner_width = ViewHelper.get_logs_inner_width(model)
    logs_height = ViewHelper.get_logs_pane_height(model)

    raw_cursor = model.visual_cursor || 0
    cursor_idx = max(0, min(raw_cursor, max(0, length(displayed_logs) - 1)))

    cursor_wrapped_start =
      displayed_logs
      |> Enum.take(cursor_idx)
      |> Enum.reduce(0, fn line, acc ->
        acc + ViewHelper.visual_line_count(line, inner_width)
      end)

    cursor_line_count =
      ViewHelper.visual_line_count(Enum.at(displayed_logs, cursor_idx, ""), inner_width)

    cursor_wrapped_end = cursor_wrapped_start + cursor_line_count - 1
    max_scroll = get_max_scroll(model, displayed_logs)

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
    %{model | logs_scroll_y: new_scroll}
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
      k when k in ["j", :down] ->
        displayed_logs = ViewHelper.get_displayed_logs(model)
        max_scroll = get_max_scroll(model, displayed_logs)

        case model.logs_scroll_y do
          :bottom ->
            {model, []}

          val when is_integer(val) ->
            new_scroll = val + scroll_step
            new_scroll = if new_scroll >= max_scroll, do: :bottom, else: new_scroll
            {%{model | logs_scroll_y: new_scroll}, []}
        end

      k when k in ["k", :up] ->
        if model.selected_profile_id do
          displayed_logs = ViewHelper.get_displayed_logs(model)
          max_scroll = get_max_scroll(model, displayed_logs)

          effective_scroll =
            case model.logs_scroll_y do
              :bottom -> max_scroll
              val when is_integer(val) -> min(val, max_scroll)
            end

          maybe_trigger_history_fetch(
            model,
            %{model | logs_scroll_y: effective_scroll},
            effective_scroll,
            max_scroll,
            fn ->
              new_scroll = max(0, effective_scroll - scroll_step)

              final_scroll =
                if model.logs_scroll_y == :bottom and new_scroll == max_scroll,
                  do: :bottom,
                  else: new_scroll

              {%{model | logs_scroll_y: final_scroll}, []}
            end
          )
        else
          {model, []}
        end

      "g" ->
        # Go to top of logs
        {%{model | logs_scroll_y: 0}, []}

      "G" ->
        # Go to bottom of logs
        {%{model | logs_scroll_y: :bottom}, []}

      k when k in [:page_up, :pageup] ->
        displayed_logs = ViewHelper.get_displayed_logs(model)
        logs_height = ViewHelper.get_logs_pane_height(model)
        max_scroll = get_max_scroll(model, displayed_logs)

        case model.logs_scroll_y do
          :bottom ->
            new_scroll = max(0, max_scroll - logs_height)
            {%{model | logs_scroll_y: new_scroll}, []}

          val when is_integer(val) ->
            new_scroll = max(0, val - logs_height)
            {%{model | logs_scroll_y: new_scroll}, []}
        end

      k when k in [:page_down, :pagedown] ->
        displayed_logs = ViewHelper.get_displayed_logs(model)
        logs_height = ViewHelper.get_logs_pane_height(model)
        max_scroll = get_max_scroll(model, displayed_logs)

        case model.logs_scroll_y do
          :bottom ->
            {model, []}

          val when is_integer(val) ->
            new_scroll = val + logs_height
            new_scroll = if new_scroll >= max_scroll, do: :bottom, else: new_scroll
            {%{model | logs_scroll_y: new_scroll}, []}
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
          max_scroll = get_max_scroll(model, displayed_logs)

          cursor_idx =
            case model.logs_scroll_y do
              :bottom ->
                last_idx

              val when is_integer(val) ->
                scroll_y = min(val, max_scroll)
                get_raw_index_at_scroll(displayed_logs, scroll_y, inner_width)
            end

          new_model =
            %{
              model
              | mode: :selecting,
                visual_anchor: nil,
                visual_cursor: cursor_idx
            }
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
      text = displayed_logs |> Enum.map(&extract_log_text/1) |> Enum.join("\n")
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
        update_filter_regex(model, model.filter_regex <> text)

      :backspace ->
        new_val = String.slice(model.filter_regex, 0..-2//1)
        update_filter_regex(model, new_val)

      :enter ->
        {%{model | mode: :browsing, active_field: nil}, []}

      :char ->
        char = Map.get(key_data, :char, "")

        if is_binary(char) and char != "" do
          update_filter_regex(model, model.filter_regex <> char)
        else
          {model, []}
        end

      ch when is_binary(ch) and byte_size(ch) == 1 ->
        update_filter_regex(model, model.filter_regex <> ch)

      _ ->
        {model, []}
    end
  end

  defp update_filter_regex(model, new_val) do
    error =
      case Regex.compile(new_val) do
        {:ok, _} -> false
        _ -> true
      end

    {%{model | filter_regex: new_val, filter_error: error}, []}
  end

  # ── Helpers ─────────────────────────────────────────────────────────

  defp get_max_scroll(model, displayed_logs) do
    inner_width = ViewHelper.get_logs_inner_width(model)
    logs_height = ViewHelper.get_logs_pane_height(model)
    wrapped_lines_count = ViewHelper.count_wrapped_lines(displayed_logs, inner_width)
    max(0, wrapped_lines_count - logs_height)
  end

  defp maybe_trigger_history_fetch(model, return_model, current_scroll, max_scroll, fallback_fn) do
    if current_scroll == 0 and max_scroll > 0 and model.logs_fetch_limit < 10000 and
         not model.loading_history do
      new_limit = min(model.logs_fetch_limit + 1000, 10000)

      load_model = %{
        return_model
        | logs_fetch_limit: new_limit,
          loading_history: true,
          logs_len_before_history_load: length(model.logs)
      }

      {load_model, [{:command, {:load_history, new_limit}}]}
    else
      fallback_fn.()
    end
  end

  def get_raw_index_at_scroll(displayed_logs, scroll_y, inner_width) do
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
