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
        status = Map.get(state.statuses, profile.id, :disconnected)
        status_color = ViewHelper.status_color(status)

        status_icon =
          case status do
            :connected -> "● "
            :connecting -> "◌ "
            _ -> "○ "
          end

        server_selected =
          state.selected_profile_id == profile.id && is_nil(state.selected_container_id)

        prefix = if server_selected, do: "> ", else: "  "
        server_color = if server_selected, do: :green, else: :white

        server_row =
          Line.new([
            Span.new(prefix),
            Span.new(status_icon, style: %Style{fg: status_color}),
            Span.new(profile.id, style: %Style{fg: server_color})
          ])

        containers = Map.get(state.containers, profile.id, [])

        container_rows =
          Enum.with_index(containers)
          |> Enum.map(fn {container, idx} ->
            is_last = idx == length(containers) - 1
            branch = if is_last, do: "└── ", else: "├── "

            container_selected =
              state.selected_profile_id == profile.id &&
                state.selected_container_id == container.id

            c_prefix = if container_selected, do: "> ", else: "  "
            c_color = if container_selected, do: :green, else: :white

            Line.new([
              Span.new(c_prefix),
              Span.new("  " <> branch <> container.name, style: %Style{fg: c_color})
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
        if is_nil(model.selected_container_id) and model.selected_profile_id do
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
      server_item = {:server, profile.id}
      containers = Map.get(model.containers, profile.id, [])
      container_items = Enum.map(containers, fn c -> {:container, profile.id, c.id, c.name} end)
      [server_item | container_items]
    end)
  end

  @doc """
  Applies state updates when a profile or container is selected, and instructs workers to stream.
  """
  def select_item(item, model) do
    case item do
      {:server, server_id} ->
        case Caudata.ServerSupervisor.lookup_worker(server_id) do
          {:ok, pid} ->
            _ = GenServer.call(pid, :stream_server_logs)
            :ok

          _ ->
            :ok
        end

        logs = Caudata.LogStore.get_snapshot(Caudata.LogStore, server_id, 1000)

        {%{
           model
           | selected_profile_id: server_id,
             selected_container_id: nil,
             logs: logs,
             logs_scroll_y: :bottom,
             logs_fetch_limit: 1000,
             loading_history: false,
             loading_history_ticks: 0,
             logs_len_before_history_load: 0
         }, []}

      {:container, server_id, container_id, _name} ->
        case Caudata.ServerSupervisor.lookup_worker(server_id) do
          {:ok, pid} ->
            _ = GenServer.call(pid, {:stream_container_logs, container_id})
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

            _ ->
              false
          end)
        else
          {:server, model.selected_profile_id}
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

            _ ->
              false
          end)
        else
          {:server, model.selected_profile_id}
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
