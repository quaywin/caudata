defmodule Caudata.UI.Components.Sidebar do
  @moduledoc """
  Renders the server sidebar panel and handles its keyboard navigation events.
  """
  alias ExRatatui.Style
  alias ExRatatui.Text.Line
  alias ExRatatui.Text.Span
  alias ExRatatui.Widgets.Block
  alias ExRatatui.Widgets.Paragraph

  alias Caudata.UI.ViewHelper

  @doc """
  Renders the sidebar widget populated with connection profiles and active containers.
  """
  def render(state) do
    # Sidebar items
    sidebar_lines =
      Enum.flat_map(state.profiles, fn profile ->
        status =
          if Map.get(profile, :enabled, true) do
            Map.get(state.statuses, profile.id, :disconnected)
          else
            :disabled
          end

        status_color = ViewHelper.status_color(status)

        status_icon =
          case status do
            :connected -> "● "
            :connecting -> "◌ "
            :disabled -> "⊘ "
            _ -> "○ "
          end

        server_row =
          Line.new([
            Span.new("  "),
            Span.new(status_icon, style: %Style{fg: status_color}),
            Span.new(profile.id,
              style: %Style{fg: if(status == :disabled, do: :dark_gray, else: :white)}
            )
          ])

        containers = Map.get(state.containers, profile.id, [])

        enabled_containers =
          Enum.filter(containers, fn c ->
            c.id not in profile.disabled_containers and c.name not in profile.disabled_containers
          end)

        container_rows =
          Enum.with_index(enabled_containers)
          |> Enum.map(fn {container, idx} ->
            is_last = idx == length(enabled_containers) - 1
            branch = if is_last, do: "└── ", else: "├── "

            container_selected =
              state.selected_profile_id == profile.id &&
                state.selected_container_id == container.id

            c_prefix = if container_selected, do: "> ", else: "  "
            c_color = if container_selected, do: :green, else: :white

            is_file = container.image == "file" or String.starts_with?(container.id, "file:")
            icon = if is_file, do: "📄 ", else: "🐳 "
            icon_color = if is_file, do: :yellow, else: :cyan

            Line.new([
              Span.new(c_prefix),
              Span.new("  " <> branch, style: %Style{fg: c_color}),
              Span.new(icon, style: %Style{fg: icon_color}),
              Span.new(container.name, style: %Style{fg: c_color})
            ])
          end)

        [server_row | container_rows]
      end)

    %Paragraph{
      text: sidebar_lines,
      block: %Block{
        title: " Servers ",
        borders: [:all],
        border_type: :rounded
      }
    }
  end

  @doc """
  Handles navigation key events for the sidebar.
  """
  def handle_key(key, _key_data, model) do
    case key do
      :up ->
        select_prev_item(model)

      :down ->
        select_next_item(model)

      :enter ->
        if model.selected_profile_id do
          case Enum.find(model.profiles, &(&1.id == model.selected_profile_id)) do
            nil ->
              {model, []}

            profile ->
              case Caudata.ServerSupervisor.lookup_worker(profile.id) do
                {:ok, pid} ->
                  GenServer.cast(pid, :refresh_containers)
                  {model, []}

                _ ->
                  ViewHelper.start_worker_if_needed(profile)
                  {model, []}
              end
          end
        else
          {model, []}
        end

      _ ->
        {model, []}
    end
  end

  @doc """
  Lists the items currently visible in the sidebar hierarchy (servers and expanded containers).
  """
  def list_visible_items(model) do
    Enum.flat_map(model.profiles, fn profile ->
      containers = Map.get(model.containers, profile.id, [])

      enabled_containers =
        Enum.filter(containers, fn c ->
          c.id not in profile.disabled_containers and c.name not in profile.disabled_containers
        end)

      Enum.map(enabled_containers, fn c -> {:container, profile.id, c.id, c.name} end)
    end)
  end

  @doc """
  Applies state updates when a profile or container is selected, and instructs workers to stream.
  """
  def select_item(item, model) do
    case item do
      {:server, server_id} ->
        {%{
           model
           | selected_profile_id: server_id,
             selected_container_id: nil,
             logs: [],
             logs_scroll_y: :bottom,
             logs_fetch_limit: 1000,
             loading_history: false,
             loading_history_ticks: 0,
             logs_len_before_history_load: 0
         }, []}

      {:container, server_id, container_id, _name} ->
        case Caudata.ServerSupervisor.lookup_worker(server_id) do
          {:ok, pid} ->
            Task.start(fn ->
              GenServer.call(pid, {:stream_container_logs, container_id})
            end)

            :ok

          _ ->
            :ok
        end

        source_id = "#{server_id}/#{container_id}"
        logs = Caudata.LogStore.get_snapshot(Caudata.LogStore, source_id, 1000)

        {%{
           model
           | selected_profile_id: server_id,
             selected_container_id: container_id,
             logs: logs,
             logs_scroll_y: :bottom,
             logs_fetch_limit: 1000,
             loading_history: false,
             loading_history_ticks: 0,
             logs_len_before_history_load: 0
         }, []}
    end
  end

  @doc """
  Selects the next visible item down in the sidebar tree.
  """
  def select_next_item(model) do
    items = list_visible_items(model)

    if items != [] do
      current_item =
        if model.selected_container_id do
          Enum.find(items, fn
            {:container, s_id, c_id, _name} ->
              s_id == model.selected_profile_id and c_id == model.selected_container_id
          end)
        else
          nil
        end

      index = Enum.find_index(items, &(&1 == current_item))
      next_index = if index, do: min(index + 1, length(items) - 1), else: 0

      case Enum.at(items, next_index) do
        nil -> {model, []}
        item -> select_item(item, model)
      end
    else
      {model, []}
    end
  end

  @doc """
  Selects the previous visible item up in the sidebar tree.
  """
  def select_prev_item(model) do
    items = list_visible_items(model)

    if items != [] do
      current_item =
        if model.selected_container_id do
          Enum.find(items, fn
            {:container, s_id, c_id, _name} ->
              s_id == model.selected_profile_id and c_id == model.selected_container_id
          end)
        else
          nil
        end

      index = Enum.find_index(items, &(&1 == current_item))
      prev_index = if index, do: max(index - 1, 0), else: 0

      case Enum.at(items, prev_index) do
        nil -> {model, []}
        item -> select_item(item, model)
      end
    else
      {model, []}
    end
  end
end
