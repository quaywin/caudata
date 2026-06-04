defmodule Caudata.UI.App do
  @moduledoc """
  The canonical ExRatatui UI application for Caudata.
  Renders the sidebar, logs stream, filter bar, and manual connection profile modal.
  Delegates key processing to KeyHandler, rendering to Renderer, and helper lookups to ViewHelper.
  """
  use ExRatatui.App
  require Logger

  alias Caudata.UI.ViewHelper
  alias Caudata.UI.KeyHandler
  alias Caudata.UI.Renderer

  # Model Definition

  @impl true
  def mount(opts) do
    # Start the tick timer
    {:ok, _} = :timer.send_interval(100, :tick)

    width = Keyword.get(opts, :width, 80)
    height = Keyword.get(opts, :height, 24)

    profiles = Caudata.ConfigManager.list_profiles()

    # Auto-connect at startup
    Enum.each(profiles, fn profile ->
      ViewHelper.start_worker_if_needed(profile)
    end)

    selected_id =
      case profiles do
        [first | _] ->
          first.id

        _ ->
          nil
      end

    state = %{
      profiles: profiles,
      selected_profile_id: selected_id,
      selected_container_id: nil,
      containers: %{},
      logs: [],
      logs_scroll_y: :bottom,
      logs_fetch_limit: 1000,
      loading_history: false,
      loading_history_ticks: 0,
      logs_len_before_history_load: 0,
      statuses: %{},
      filter_regex: "",
      filter_error: false,
      freeze: false,
      modal_visible: false,
      modal_type: :select_ssh,
      ssh_config_profiles: [],
      modal_selected_index: 0,
      modal_focus_index: 0,
      modal_error: nil,
      modal_fields: %{
        "id" => "",
        "host_name" => "",
        "user" => "",
        "port" => "22",
        "identity_file" => "",
        "log_command" => "tail -F /var/log/messages"
      },
      drop_counts: %{},
      buffer_sizes: %{},
      active_field: nil,
      mode: :browsing,
      width: width,
      height: height,
      terminal: Keyword.get(opts, :terminal, false),
      settings_selected_profile_idx: 0,
      settings_focus: :servers,
      settings_container_idx: 0,
      settings_custom_log_idx: 0,
      settings_input_active: false,
      settings_input_value: "",
      settings_status_msg: nil
    }

    {:ok, state}
  end

  @impl true
  def handle_event(%ExRatatui.Event.Resize{width: w, height: h}, state) do
    {:noreply, %{state | width: w, height: h}}
  end

  def handle_event(%ExRatatui.Event.Key{code: code, modifiers: modifiers}, state) do
    # Map the key to the Raxol format and handle
    {_key, key_data} =
      if String.length(code) == 1 do
        {:char, %{key: :char, char: code, modifiers: modifiers}}
      else
        mapped_key =
          case code do
            "up" -> :up
            "down" -> :down
            "left" -> :left
            "right" -> :right
            "tab" -> :tab
            "enter" -> :enter
            "esc" -> :escape
            "escape" -> :escape
            "backspace" -> :backspace
            _ -> nil
          end

        {mapped_key, %{key: mapped_key, modifiers: modifiers}}
      end

    case KeyHandler.handle_key_event(key_data, state) do
      {new_state, []} ->
        {:noreply, new_state}

      {new_state, [{:command, :quit}]} ->
        {:stop, new_state}

      {new_state, _other_commands} ->
        {:noreply, new_state}
    end
  end

  def handle_event(_event, state) do
    {:noreply, state}
  end

  @impl true
  def handle_info(message, state) do
    case message do
      :tick ->
        profiles = Caudata.ConfigManager.list_profiles()

        # Get statuses and containers from supervisor/worker registry
        {statuses, containers} =
          Enum.reduce(profiles, {%{}, %{}}, fn p, {status_acc, containers_acc} ->
            case Caudata.ServerSupervisor.lookup_worker(p.id) do
              {:ok, pid} ->
                status = Caudata.ServerWorker.get_status(pid)
                conts = Caudata.ServerWorker.get_containers(pid)
                {Map.put(status_acc, p.id, status), Map.put(containers_acc, p.id, conts)}

              _ ->
                {Map.put(status_acc, p.id, :disconnected), Map.put(containers_acc, p.id, [])}
            end
          end)

        # If the currently selected container is disabled, reset selection
        selected_container_id =
          case Enum.find(profiles, &(&1.id == state.selected_profile_id)) do
            nil ->
              state.selected_container_id

            profile ->
              if state.selected_container_id &&
                   (state.selected_container_id in profile.disabled_containers or
                      (case Enum.find(
                              Map.get(containers, profile.id, []),
                              &(&1.id == state.selected_container_id)
                            ) do
                         nil -> false
                         c -> c.name in profile.disabled_containers
                       end)) do
                nil
              else
                state.selected_container_id
              end
          end

        # Get the enabled containers for the selected profile
        enabled_conts_for_profile =
          case Enum.find(profiles, &(&1.id == state.selected_profile_id)) do
            nil ->
              []

            profile ->
              Map.get(containers, profile.id, [])
              |> Enum.filter(fn c ->
                c.id not in profile.disabled_containers and
                  c.name not in profile.disabled_containers
              end)
          end

        # Auto-select first container of selected profile if none selected
        {selected_container_id, logs_scroll_y} =
          if is_nil(selected_container_id) and state.selected_profile_id do
            case enabled_conts_for_profile do
              [first_container | _] ->
                case Caudata.ServerSupervisor.lookup_worker(state.selected_profile_id) do
                  {:ok, pid} ->
                    _ = GenServer.call(pid, {:stream_container_logs, first_container.id})
                    :ok

                  _ ->
                    :ok
                end

                {first_container.id, :bottom}

              _ ->
                {selected_container_id, state.logs_scroll_y}
            end
          else
            {selected_container_id, state.logs_scroll_y}
          end

        # Get statistics for all profiles/containers
        {sizes, drops} =
          Enum.reduce(profiles, {%{}, %{}}, fn p, {sz_acc, dr_acc} ->
            source_id =
              if state.selected_profile_id == p.id and selected_container_id do
                "#{p.id}/#{selected_container_id}"
              else
                p.id
              end

            stats = Caudata.LogStore.get_stats(source_id)
            {Map.put(sz_acc, p.id, stats.size), Map.put(dr_acc, p.id, stats.drop_count)}
          end)

        # If logs are not frozen, fetch latest snapshot from LogStore
        new_logs =
          if state.selected_profile_id && not state.freeze do
            source_id =
              if selected_container_id do
                "#{state.selected_profile_id}/#{selected_container_id}"
              else
                state.selected_profile_id
              end

            Caudata.LogStore.get_snapshot(Caudata.LogStore, source_id, state.logs_fetch_limit)
          else
            state.logs
          end

        # Handle loading_history state machine transitions to avoid flashing/jumping:
        loading_ticks = if state.loading_history, do: state.loading_history_ticks + 1, else: 0

        {logs, loading_history, scroll_y} =
          if state.loading_history do
            cond do
              length(new_logs) > state.logs_len_before_history_load ->
                m = length(new_logs) - state.logs_len_before_history_load

                displayed_logs =
                  ViewHelper.get_displayed_logs(%{
                    state
                    | logs: new_logs,
                      selected_container_id: selected_container_id
                  })

                logs_height = ViewHelper.get_logs_pane_height(state)
                new_max_scroll = max(0, length(displayed_logs) - logs_height)
                new_scroll = min(new_max_scroll, max(0, m - 1))
                {new_logs, false, new_scroll}

              loading_ticks >= 8 ->
                # Timeout: fallback to currently displayed logs
                {state.logs, false, logs_scroll_y}

              true ->
                # Still loading: keep showing old logs to prevent flashing
                {state.logs, true, logs_scroll_y}
            end
          else
            drop_diff =
              if state.selected_profile_id do
                old_drop = Map.get(state.drop_counts, state.selected_profile_id, 0)
                new_drop = Map.get(drops, state.selected_profile_id, 0)
                max(0, new_drop - old_drop)
              else
                0
              end

            adjusted_scroll =
              case logs_scroll_y do
                :bottom -> :bottom
                val when is_integer(val) -> max(0, val - drop_diff)
              end

            {new_logs, false, adjusted_scroll}
          end

        new_state = %{
          state
          | profiles: profiles,
            statuses: statuses,
            containers: containers,
            logs: logs,
            selected_container_id: selected_container_id,
            logs_scroll_y: scroll_y,
            loading_history: loading_history,
            loading_history_ticks: loading_ticks,
            buffer_sizes: sizes,
            drop_counts: drops
        }

        {:noreply, new_state}

      {:select_profile, profile_id} ->
        {new_state, []} = KeyHandler.select_item({:server, profile_id}, state)
        {:noreply, new_state}

      {:validation_result, server_id, path, result} ->
        profile = Enum.find(state.profiles, &(&1.id == server_id))

        if profile do
          case result do
            :ok ->
              custom_logs = profile.custom_logs || []
              new_custom_logs = custom_logs ++ [path]

              case Caudata.ConfigManager.update_profile(server_id, %{custom_logs: new_custom_logs}) do
                {:ok, updated_profile} ->
                  new_profiles =
                    Enum.map(state.profiles, fn p ->
                      if p.id == server_id, do: updated_profile, else: p
                    end)

                  {:noreply,
                   %{
                     state
                     | profiles: new_profiles,
                       settings_status_msg: "Added path: #{path}"
                   }}

                {:error, reason} ->
                  {:noreply,
                   %{state | settings_status_msg: "Error: Failed to save: #{inspect(reason)}"}}
              end

            {:error, reason} when reason in [:not_connected, :closed, :timeout] ->
              custom_logs = profile.custom_logs || []
              new_custom_logs = custom_logs ++ [path]

              case Caudata.ConfigManager.update_profile(server_id, %{custom_logs: new_custom_logs}) do
                {:ok, updated_profile} ->
                  new_profiles =
                    Enum.map(state.profiles, fn p ->
                      if p.id == server_id, do: updated_profile, else: p
                    end)

                  {:noreply,
                   %{
                     state
                     | profiles: new_profiles,
                       settings_status_msg:
                         "Added path (unvalidated: server is not connected or timed out)"
                   }}

                {:error, save_reason} ->
                  {:noreply,
                   %{
                     state
                     | settings_status_msg: "Error: Failed to save: #{inspect(save_reason)}"
                   }}
              end

            {:error, :not_readable_or_not_found} ->
              {:noreply, %{state | settings_status_msg: "Error: File not found or not readable"}}

            {:error, reason} ->
              {:noreply, %{state | settings_status_msg: "Error: #{inspect(reason)}"}}
          end
        else
          {:noreply, state}
        end

      {:select_container, server_id, container_id} ->
        {new_state, []} =
          KeyHandler.select_item({:container, server_id, container_id, nil}, state)

        {:noreply, new_state}

      {:update_filter, value} ->
        # Regex compile safety check
        {error, _compiled} =
          case Regex.compile(value) do
            {:ok, re} -> {false, re}
            _ -> {true, nil}
          end

        {:noreply, %{state | filter_regex: value, filter_error: error}}

      :toggle_freeze ->
        {:noreply, %{state | freeze: not state.freeze}}

      _ ->
        {:noreply, state}
    end
  end

  @impl true
  def terminate(_reason, state) do
    if Map.get(state, :terminal, false) do
      self_pid = self()

      spawn(fn ->
        ref = Process.monitor(self_pid)

        receive do
          {:DOWN, ^ref, :process, ^self_pid, _reason} ->
            Process.sleep(50)
            System.halt(0)
        after
          2000 ->
            System.halt(0)
        end
      end)
    end

    :ok
  end

  @impl true
  def render(state, frame) do
    Renderer.render(state, frame)
  end
end
