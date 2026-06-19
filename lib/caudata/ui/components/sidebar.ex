defmodule Caudata.UI.Components.Sidebar do
  @moduledoc """
  Renders the server sidebar panel split into 4 boxes, and handles its keyboard navigation events.
  Delegates individual box rendering to sub-components.
  """
  alias ExRatatui.Layout

  alias Caudata.UI.ViewHelper
  alias Caudata.UI.Components.Sidebar.{ServerList, ContainerList, ContainerInfo, ServerMetrics}

  @doc """
  Renders the 4 vertical boxes inside the sidebar area by delegating to sub-components.
  Returns a list of `{widget, area}` tuples.
  """
  def render(state, sidebar_area) do
    # Determine the vertical heights based on overall height
    h = sidebar_area.height

    if h >= 18 do
      {h1, h3, h4} =
        cond do
          h >= 30 -> {8, 7, 5}
          h >= 24 -> {6, 6, 5}
          true -> {5, 5, 5}
        end

      [box1_area, box2_area, box3_area, box4_area] =
        Layout.split(sidebar_area, :vertical, [
          {:length, h1},
          {:min, 0},
          {:length, h3},
          {:length, h4}
        ])

      [
        ServerList.render(state, box1_area),
        ContainerList.render(state, box2_area),
        ContainerInfo.render(state, box3_area),
        ServerMetrics.render(state, box4_area)
      ]
    else
      servers_h = if h >= 10, do: 5, else: max(2, div(h, 2))

      [box1_area, box2_area] =
        Layout.split(sidebar_area, :vertical, [
          {:length, servers_h},
          {:min, 0}
        ])

      [
        ServerList.render(state, box1_area),
        ContainerList.render(state, box2_area)
      ]
    end
  end

  @doc """
  Handles navigation key events for the sidebar.
  """
  def handle_key(key, _key_data, model) do
    focus = Map.get(model, :sidebar_focus, :servers)

    case key do
      :up ->
        if focus == :containers do
          select_prev_container(model)
        else
          select_prev_server(model)
        end

      :down ->
        if focus == :containers do
          select_next_container(model)
        else
          select_next_server(model)
        end

      :tab ->
        new_focus = if focus == :containers, do: :servers, else: :containers
        new_model = %{model | sidebar_focus: new_focus}

        if new_focus == :containers and is_nil(new_model.selected_container_id) do
          case get_enabled_containers_for_profile(new_model, new_model.selected_profile_id) do
            [first_container | _] ->
              select_container(
                new_model.selected_profile_id,
                first_container.id,
                first_container.name,
                new_model
              )

            _ ->
              {new_model, []}
          end
        else
          {new_model, []}
        end

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
      enabled_containers = ViewHelper.get_enabled_containers(profile, containers)
      Enum.map(enabled_containers, fn c -> {:container, profile.id, c.id, c.name} end)
    end)
  end

  @doc """
  Applies state updates when a profile or container is selected, and instructs workers to stream.
  """
  def select_item(item, model) do
    case item do
      {:server, server_id} ->
        select_server(server_id, model)

      {:container, server_id, container_id, name} ->
        select_container(server_id, container_id, name, model)
    end
  end

  @doc """
  Selects the next visible item down in the sidebar tree.
  """
  def select_next_item(model) do
    focus = Map.get(model, :sidebar_focus, :servers)

    if focus == :containers do
      select_next_container(model)
    else
      select_next_server(model)
    end
  end

  @doc """
  Selects the previous visible item up in the sidebar tree.
  """
  def select_prev_item(model) do
    focus = Map.get(model, :sidebar_focus, :servers)

    if focus == :containers do
      select_prev_container(model)
    else
      select_prev_server(model)
    end
  end

  # Helpers for Servers list selection

  def select_next_server(model) do
    profiles = model.profiles

    if profiles != [] do
      current_idx = Enum.find_index(profiles, &(&1.id == model.selected_profile_id))

      next_idx =
        cond do
          is_nil(current_idx) -> 0
          current_idx == length(profiles) - 1 -> 0
          true -> current_idx + 1
        end

      next_profile = Enum.at(profiles, next_idx)

      select_server(next_profile.id, model)
    else
      {model, []}
    end
  end

  def select_prev_server(model) do
    profiles = model.profiles

    if profiles != [] do
      current_idx = Enum.find_index(profiles, &(&1.id == model.selected_profile_id))

      prev_idx =
        cond do
          is_nil(current_idx) -> 0
          current_idx == 0 -> length(profiles) - 1
          true -> current_idx - 1
        end

      prev_profile = Enum.at(profiles, prev_idx)

      select_server(prev_profile.id, model)
    else
      {model, []}
    end
  end

  def select_server(server_id, model) do
    profile = Enum.find(model.profiles, &(&1.id == server_id))
    containers = Map.get(model.containers, server_id, [])
    enabled_containers = ViewHelper.get_enabled_containers(profile, containers)

    case enabled_containers do
      [first_container | _] ->
        select_container(server_id, first_container.id, first_container.name, model)

      _ ->
        source_id = server_id

        stats =
          if Process.whereis(Caudata.LogStore) do
            Caudata.LogStore.get_stats(source_id)
          else
            %{size: 0, drop_count: 0}
          end

        {%{
           model
           | selected_profile_id: server_id,
             selected_container_id: nil,
             logs: [],
             logs_scroll_y: :bottom,
             logs_fetch_limit: 100,
             loading_history: false,
             loading_history_ticks: 0,
             logs_len_before_history_load: 0,
             buffer_sizes: Map.put(model.buffer_sizes, source_id, stats.size),
             drop_counts: Map.put(model.drop_counts, source_id, stats.drop_count)
         }, []}
    end
  end

  # Helpers for Containers list selection

  def select_next_container(model) do
    containers = get_enabled_containers_for_profile(model, model.selected_profile_id)

    if containers != [] do
      current_idx =
        Enum.find_index(containers, &(to_string(&1.id) == to_string(model.selected_container_id)))

      next_idx =
        cond do
          is_nil(current_idx) -> 0
          current_idx == length(containers) - 1 -> 0
          true -> current_idx + 1
        end

      next_container = Enum.at(containers, next_idx)

      select_container(
        model.selected_profile_id,
        next_container.id,
        next_container.name,
        model
      )
    else
      {model, []}
    end
  end

  def select_prev_container(model) do
    containers = get_enabled_containers_for_profile(model, model.selected_profile_id)

    if containers != [] do
      current_idx =
        Enum.find_index(containers, &(to_string(&1.id) == to_string(model.selected_container_id)))

      prev_idx =
        cond do
          is_nil(current_idx) -> 0
          current_idx == 0 -> length(containers) - 1
          true -> current_idx - 1
        end

      prev_container = Enum.at(containers, prev_idx)

      select_container(
        model.selected_profile_id,
        prev_container.id,
        prev_container.name,
        model
      )
    else
      {model, []}
    end
  end

  def select_container(server_id, container_id, _container_name, model) do
    case Caudata.ServerSupervisor.lookup_worker(server_id) do
      {:ok, pid} ->
        Task.start(fn ->
          try do
            GenServer.call(pid, {:stream_container_logs, container_id}, 10_000)
          catch
            :exit, _ -> :ok
          end
        end)

        :ok

      _ ->
        :ok
    end

    source_id = "#{server_id}/#{container_id}"
    logs = Caudata.LogStore.get_snapshot(Caudata.LogStore, source_id, 1000)

    stats =
      if Process.whereis(Caudata.LogStore) do
        Caudata.LogStore.get_stats(source_id)
      else
        %{size: 0, drop_count: 0}
      end

    {%{
       model
       | selected_profile_id: server_id,
         selected_container_id: container_id,
         logs: logs,
         logs_scroll_y: :bottom,
         logs_fetch_limit: 100,
         loading_history: false,
         loading_history_ticks: 0,
         logs_len_before_history_load: 0,
         buffer_sizes: Map.put(model.buffer_sizes, source_id, stats.size),
         drop_counts: Map.put(model.drop_counts, source_id, stats.drop_count)
     }, []}
  end

  # Helper functions

  defp get_enabled_containers_for_profile(model, profile_id) do
    case Enum.find(model.profiles, &(&1.id == profile_id)) do
      nil ->
        []

      profile ->
        containers = Map.get(model.containers, profile_id, [])
        ViewHelper.get_enabled_containers(profile, containers)
    end
  end
end
