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
      selected_profile ->
        displayed_logs = ViewHelper.get_displayed_logs(state)
        log_lines = Enum.map(displayed_logs, fn line -> Line.new([Span.new(line)]) end)

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

        inner_area = ViewHelper.inner_rect(logs_area)

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

            inner_width = max(0, state.width - 27)
            wrapped_lines_count = ViewHelper.count_wrapped_lines(displayed_logs, inner_width)
            max_scroll = max(0, wrapped_lines_count - logs_content_rect.height)

            scroll_y =
              case state.logs_scroll_y do
                :bottom -> max_scroll
                val -> min(val, max_scroll)
              end

            logs_widget = %Paragraph{
              text: log_lines,
              scroll: {scroll_y, 0},
              wrap: true
            }

            [
              {logs_widget, logs_content_rect},
              {divider_widget, logs_filter_divider_rect},
              {filter_widget, logs_filter_rect}
            ]
          else
            inner_width = max(0, state.width - 27)
            wrapped_lines_count = ViewHelper.count_wrapped_lines(displayed_logs, inner_width)
            max_scroll = max(0, wrapped_lines_count - inner_area.height)

            scroll_y =
              case state.logs_scroll_y do
                :bottom -> max_scroll
                val -> min(val, max_scroll)
              end

            logs_widget = %Paragraph{
              text: log_lines,
              scroll: {scroll_y, 0},
              wrap: true
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
        inner_width = max(0, model.width - 27)
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
          source_id =
            if model.selected_container_id do
              "#{model.selected_profile_id}/#{model.selected_container_id}"
            else
              model.selected_profile_id
            end

          stats = Caudata.LogStore.get_stats(source_id)
          current_len = length(model.logs)

          displayed_logs = ViewHelper.get_displayed_logs(model)
          logs_height = ViewHelper.get_logs_pane_height(model)
          inner_width = max(0, model.width - 27)
          current_visual_len = ViewHelper.count_wrapped_lines(displayed_logs, inner_width)
          max_scroll = max(0, current_visual_len - logs_height)

          effective_scroll =
            case model.logs_scroll_y do
              :bottom -> max_scroll
              val when is_integer(val) -> val
            end

          if effective_scroll == 0 do
            if current_len < stats.size do
              # More logs exist in LogStore, fetch them directly
              new_limit = model.logs_fetch_limit + 1000
              new_logs = Caudata.LogStore.get_snapshot(Caudata.LogStore, source_id, new_limit)

              new_model = %{model | logs: new_logs}
              new_displayed_logs = ViewHelper.get_displayed_logs(new_model)
              new_visual_len = ViewHelper.count_wrapped_lines(new_displayed_logs, inner_width)
              m_visual = new_visual_len - current_visual_len

              new_max_scroll = max(0, new_visual_len - logs_height)
              new_scroll = min(new_max_scroll, max(0, m_visual - 3))

              {%{
                 model
                 | logs: new_logs,
                   logs_fetch_limit: new_limit,
                   logs_scroll_y: new_scroll
               }, []}
            else
              # LogStore fully loaded, query remote server/container for more history
              if model.logs_fetch_limit < 5000 do
                new_limit = model.logs_fetch_limit + 1000

                worker_res =
                  if model.selected_container_id do
                    lookup_container_worker(
                      model.selected_profile_id,
                      model.selected_container_id
                    )
                  else
                    Caudata.ServerSupervisor.lookup_worker(model.selected_profile_id)
                  end

                case worker_res do
                  {:ok, pid} ->
                    Caudata.LogStore.set_capacity(Caudata.LogStore, new_limit)
                    GenServer.cast(pid, {:restart_with_tail_limit, new_limit})

                    {%{
                       model
                       | logs_fetch_limit: new_limit,
                         loading_history: true,
                         loading_history_ticks: 0,
                         logs_len_before_history_load: current_len
                     }, []}

                  _ ->
                    {model, []}
                end
              else
                {model, []}
              end
            end
          else
            new_scroll =
              case model.logs_scroll_y do
                :bottom -> max_scroll - 3
                val when is_integer(val) -> val - 3
              end

            new_scroll = max(0, new_scroll)
            {%{model | logs_scroll_y: new_scroll}, []}
          end
        else
          {model, []}
        end

      "/" ->
        {%{model | mode: :searching, active_field: :filter_regex}, []}

      _ ->
        {model, []}
    end
  end

  defp lookup_container_worker(profile_id, container_id) do
    case Registry.lookup(Caudata.ServerRegistry, {:container, profile_id, container_id}) do
      [{pid, _value}] -> {:ok, pid}
      _ -> {:error, :not_found}
    end
  end
end
