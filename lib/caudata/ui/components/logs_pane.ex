defmodule Caudata.UI.Components.LogsPane do
  @moduledoc """
  Renders the main logs panel and handles its keyboard events (scrolling, searching, and filtering).
  """
  alias ExRatatui.Layout
  alias ExRatatui.Style
  alias ExRatatui.Text.Line
  alias ExRatatui.Text.Span
  alias ExRatatui.Widgets.Block
  alias ExRatatui.Widgets.Paragraph

  alias Caudata.UI.ViewHelper

  @doc """
  Renders the logs outer block and inner widgets for streaming logs.
  """
  def render(state, logs_area) do
    selected_profile = Enum.find(state.profiles, fn p -> p.id == state.selected_profile_id end)

    cond do
      selected_profile && not Map.get(selected_profile, :enabled, true) ->
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

      selected_profile ->
        inner_area = ViewHelper.inner_rect(logs_area)
        inner_width = inner_area.width
        displayed_logs = ViewHelper.get_displayed_logs(state)

        wrapped_logs =
          Enum.flat_map(displayed_logs, fn line ->
            ViewHelper.wrap_text(line, inner_width)
          end)

        log_lines = Enum.map(wrapped_logs, fn line -> Line.new(format_line(line)) end)

        title =
          if state.selected_container_id do
            containers = Map.get(state.containers, selected_profile.id, [])
            container = Enum.find(containers, &(&1.id == state.selected_container_id))
            container_name = if container, do: container.name, else: state.selected_container_id
            " Logs: #{selected_profile.id} (container: #{container_name}) "
          else
            " Logs: #{selected_profile.id} "
          end

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

            filter_widget =
              cond do
                state.mode == :searching ->
                  fg = if state.filter_error, do: :red, else: :cyan

                  %Paragraph{
                    text: [
                      Line.new([
                        Span.new(" Filter (regex): /",
                          style: %Style{fg: fg, modifiers: [:bold]}
                        ),
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

            divider_widget = %Paragraph{
              text: String.duplicate("─", logs_filter_divider_rect.width),
              style: %Style{fg: :dark_gray}
            }

            wrapped_lines_count = length(wrapped_logs)
            max_scroll = max(0, wrapped_lines_count - logs_content_rect.height)

            scroll_y =
              case state.logs_scroll_y do
                :bottom -> max_scroll
                val -> min(val, max_scroll)
              end

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
            wrapped_lines_count = length(wrapped_logs)
            max_scroll = max(0, wrapped_lines_count - inner_area.height)

            scroll_y =
              case state.logs_scroll_y do
                :bottom -> max_scroll
                val -> min(val, max_scroll)
              end

            logs_widget = %Paragraph{
              text: log_lines,
              scroll: {scroll_y, 0}
            }

            [{logs_widget, inner_area}]
          end

        {outer, content}

      true ->
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
  end

  @doc """
  Handles keys for scrolling logs and regex character typing.
  """
  def handle_key(key, key_data, model) do
    case model.mode do
      :searching ->
        handle_search_key(key, key_data, model)

      _ ->
        handle_normal_mode_key(key, key_data, model)
    end
  end

  defp handle_search_key(key, key_data, model) do
    case key do
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

  defp handle_normal_mode_key(key, key_data, model) do
    norm_key = if key == :char, do: Map.get(key_data, :char), else: key

    case norm_key do
      "j" ->
        displayed_logs = ViewHelper.get_displayed_logs(model)
        logs_height = ViewHelper.get_logs_pane_height(model)

        inner_width =
          if Map.get(model, :logs_full_screen, false) do
            max(0, model.width - 2)
          else
            max(0, model.width - 40)
          end

        wrapped_lines_count = ViewHelper.count_wrapped_lines(displayed_logs, inner_width)
        max_scroll = max(0, wrapped_lines_count - logs_height)

        case model.logs_scroll_y do
          :bottom ->
            {model, []}

          val when is_integer(val) ->
            new_scroll = val + 3
            new_scroll = if new_scroll >= max_scroll, do: :bottom, else: new_scroll
            {%{model | logs_scroll_y: new_scroll}, []}
        end

      "k" ->
        if model.selected_profile_id do
          displayed_logs = ViewHelper.get_displayed_logs(model)
          logs_height = ViewHelper.get_logs_pane_height(model)

          inner_width =
            if Map.get(model, :logs_full_screen, false) do
              max(0, model.width - 2)
            else
              max(0, model.width - 40)
            end

          current_visual_len = ViewHelper.count_wrapped_lines(displayed_logs, inner_width)
          max_scroll = max(0, current_visual_len - logs_height)

          effective_scroll =
            case model.logs_scroll_y do
              :bottom -> max_scroll
              val when is_integer(val) -> val
            end

          new_scroll = max(0, effective_scroll - 3)

          new_scroll =
            if model.logs_scroll_y == :bottom and new_scroll == max_scroll,
              do: :bottom,
              else: new_scroll

          {%{model | logs_scroll_y: new_scroll}, []}
        else
          {model, []}
        end

      "/" ->
        {%{model | mode: :searching, active_field: :filter_regex}, []}

      _ ->
        {model, []}
    end
  end

  @log_regex ~r/^(?:(?=\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}|\d{2}:\d{2}:\d{2}|\[[a-zA-Z0-9_-]+\]|\b(?:info|warn|warning|error|err|debug|fatal|trace|critical|crit|emerg|emergency|stderr|fail|failure)\b)(?:(?<ts>\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:?\d{2})?|\d{2}:\d{2}:\d{2}(?:\.\d+)?)\s)?(?:(?:\[(?<bracket_lvl>[a-zA-Z0-9_-]+)\]|(?<colon_lvl>\b(?:info|warn|warning|error|err|debug|fatal|trace|critical|crit|emerg|emergency|stderr|fail|failure)\b):|(?<bare_lvl>\b(?:info|warn|warning|error|err|debug|fatal|trace|critical|crit|emerg|emergency|stderr|fail|failure)\b))\s?)?)?(?<msg>.*)$/i

  defp format_line(line) do
    case Regex.named_captures(@log_regex, line) do
      %{
        "ts" => ts,
        "bracket_lvl" => bracket_lvl,
        "colon_lvl" => colon_lvl,
        "bare_lvl" => bare_lvl,
        "msg" => msg
      } ->
        {_level, lvl_style} =
          cond do
            bracket_lvl != "" -> {bracket_lvl, level_style(bracket_lvl)}
            colon_lvl != "" -> {colon_lvl, level_style(colon_lvl)}
            bare_lvl != "" -> {bare_lvl, level_style(bare_lvl)}
            true -> {nil, nil}
          end

        msg_style = %Style{fg: :white}

        spans = []

        spans =
          if ts != "" do
            spans ++ [Span.new(ts <> " ", style: %Style{fg: :dark_gray})]
          else
            spans
          end

        spans =
          cond do
            bracket_lvl != "" ->
              spans ++
                [Span.new("[" <> bracket_lvl <> "] ", style: %{lvl_style | modifiers: [:bold]})]

            colon_lvl != "" ->
              spans ++ [Span.new(colon_lvl <> ": ", style: %{lvl_style | modifiers: [:bold]})]

            bare_lvl != "" ->
              spans ++ [Span.new(bare_lvl <> " ", style: %{lvl_style | modifiers: [:bold]})]

            true ->
              spans
          end

        spans ++ [Span.new(msg, style: msg_style)]

      nil ->
        [Span.new(line, style: %Style{fg: :white})]
    end
  end

  defp level_style(level) do
    case String.downcase(level) do
      l when l in ["info"] ->
        %Style{fg: :green}

      l when l in ["warn", "warning"] ->
        %Style{fg: :yellow}

      l
      when l in [
             "error",
             "err",
             "fatal",
             "critical",
             "crit",
             "emerg",
             "emergency",
             "stderr",
             "fail",
             "failure"
           ] ->
        %Style{fg: :red}

      l when l in ["debug", "trace"] ->
        %Style{fg: :magenta}

      _ ->
        %Style{fg: :cyan}
    end
  end
end
