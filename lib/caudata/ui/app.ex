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

  @env Application.compile_env(:caudata, :env, :prod)

  # Model Definition

  @impl true
  def mount(opts) do
    # No interval timer. Tick is scheduled on-demand.

    # Subscribe to static updates if PubSub is running
    if Process.whereis(Caudata.PubSub) do
      Phoenix.PubSub.subscribe(Caudata.PubSub, "config:profiles")
      Phoenix.PubSub.subscribe(Caudata.PubSub, "servers")
      Phoenix.PubSub.subscribe(Caudata.PubSub, "tailscale")
    end

    {width, height} =
      if Keyword.get(opts, :terminal, false) do
        case ExRatatui.terminal_size() do
          {w, h} ->
            {Keyword.get(opts, :width, w), Keyword.get(opts, :height, h)}

          _ ->
            {Keyword.get(opts, :width, 80), Keyword.get(opts, :height, 24)}
        end
      else
        {Keyword.get(opts, :width, 80), Keyword.get(opts, :height, 24)}
      end

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
      selected_container_name: nil,
      sidebar_focus: :servers,
      containers: %{},
      metrics: %{},
      logs: [],
      logs_scroll_y: :bottom,
      logs_fetch_limit: 100,
      show_timestamps: false,
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
        "password" => ""
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
      settings_service_idx: 0,
      settings_custom_log_idx: 0,
      settings_connection_focus_idx: 0,
      settings_connection_fields: %{},
      settings_global_focus_idx: 0,
      settings_global_capacity: "1000",
      settings_ts_enabled: false,
      settings_ts_auth_key: "",
      settings_ts_hostname: "caudata",
      settings_tailscale_focus_idx: 0,
      settings_input_active: false,
      settings_input_value: "",
      settings_service_search: "",
      settings_service_search_active: false,
      settings_status_msg: nil,
      logs_dirty: true,
      logs_full_screen: false,
      update_available: nil,
      last_key: nil,
      last_key_time: 0,
      consecutive_key_count: 0,
      visual_anchor: nil,
      visual_cursor: nil,
      notification: nil,
      tick_scheduled: false
    }

    state = adjust_log_subscription(nil, state)

    # Asynchronously bootstrap state from running servers
    send(self(), :bootstrap)

    # Check for update in the background if in prod and running inside Burrito release
    if @env == :prod and Code.ensure_loaded?(Burrito.Util.Args) and
         Burrito.Util.Args.get_bin_path() != :not_in_burrito do
      parent = self()

      Task.start(fn ->
        case Caudata.CLI.check_for_update() do
          {:update_available, tag_name} ->
            send(parent, {:update_available, tag_name})

          _ ->
            :ok
        end
      end)
    end

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
            "f2" -> :f2
            "F2" -> :f2
            "insert" -> :insert
            "Insert" -> :insert
            _ -> nil
          end

        {mapped_key, %{key: mapped_key, modifiers: modifiers}}
      end

    now = System.monotonic_time(:millisecond)
    last_key = Map.get(state, :last_key)
    last_key_time = Map.get(state, :last_key_time, 0)
    consecutive_key_count = Map.get(state, :consecutive_key_count, 0)

    new_consecutive_count =
      if last_key == code and now - last_key_time < 250 do
        consecutive_key_count + 1
      else
        1
      end

    state = %{
      state
      | last_key: code,
        last_key_time: now,
        consecutive_key_count: new_consecutive_count
    }

    KeyHandler.handle_key_event(key_data, state)
    |> process_key_event_result(state)
  end

  def handle_event(%ExRatatui.Event.Paste{content: text}, state) do
    key_data = %{key: :paste, content: text}

    KeyHandler.handle_key_event(key_data, state)
    |> process_key_event_result(state)
  end

  def handle_event(_event, state) do
    {:noreply, state}
  end

  defp process_key_event_result(key_handler_result, state) do
    case key_handler_result do
      {new_state, []} ->
        noreply(state, new_state)

      {new_state, [{:command, :quit}]} ->
        {:stop, new_state}

      {new_state, [{:command, {:load_history, new_limit}}]} ->
        source_id = current_source_id(new_state)

        {logs, scroll_y, visual_cursor, visual_anchor} =
          if source_id && Process.whereis(Caudata.LogStore) do
            new_logs = Caudata.LogStore.get_snapshot(Caudata.LogStore, source_id, new_limit)
            m = length(new_logs) - new_state.logs_len_before_history_load

            if m > 0 do
              displayed_before =
                if new_state.logs == [], do: [], else: ViewHelper.get_displayed_logs(new_state)

              displayed_after = ViewHelper.get_displayed_logs(%{new_state | logs: new_logs})
              m_displayed = length(displayed_after) - length(displayed_before)

              inner_width = ViewHelper.get_logs_inner_width(new_state)
              prepended_displayed = Enum.take(displayed_after, m_displayed)
              prepended_wrapped = ViewHelper.count_wrapped_lines(prepended_displayed, inner_width)

              logs_height = ViewHelper.get_logs_pane_height(new_state)
              wrapped_after_count = ViewHelper.count_wrapped_lines(displayed_after, inner_width)
              new_max_scroll = max(0, wrapped_after_count - logs_height)

              new_scroll =
                case new_state.logs_scroll_y do
                  :bottom -> :bottom
                  val -> min(new_max_scroll, max(0, val + prepended_wrapped - 1))
                end

              vc =
                if new_state.mode == :selecting and new_state.visual_cursor != nil,
                  do: new_state.visual_cursor + m_displayed,
                  else: new_state.visual_cursor

              va =
                if new_state.mode == :selecting and new_state.visual_anchor != nil,
                  do: new_state.visual_anchor + m_displayed,
                  else: new_state.visual_anchor

              {new_logs, new_scroll, vc, va}
            else
              {new_state.logs, new_state.logs_scroll_y, new_state.visual_cursor,
               new_state.visual_anchor}
            end
          else
            {new_state.logs, new_state.logs_scroll_y, new_state.visual_cursor,
             new_state.visual_anchor}
          end

        final_state = %{
          new_state
          | logs: logs,
            logs_scroll_y: scroll_y,
            visual_cursor: visual_cursor,
            visual_anchor: visual_anchor,
            loading_history: false
        }

        noreply(state, final_state)

      {new_state, _other_commands} ->
        noreply(state, new_state)
    end
  end

  @impl true
  def handle_info(message, state) do
    case message do
      :bootstrap ->
        profiles = state.profiles

        {statuses, containers, metrics} =
          Enum.reduce(profiles, {%{}, %{}, %{}}, fn p,
                                                    {status_acc, containers_acc, metrics_acc} ->
            case Caudata.ServerSupervisor.lookup_worker(p.id) do
              {:ok, pid} ->
                status = Caudata.ServerWorker.get_status(pid)
                conts = Caudata.ServerWorker.get_containers(pid)
                mets = Caudata.ServerWorker.get_metrics(pid)

                {Map.put(status_acc, p.id, status), Map.put(containers_acc, p.id, conts),
                 Map.put(metrics_acc, p.id, mets)}

              _ ->
                {Map.put(status_acc, p.id, :disconnected), Map.put(containers_acc, p.id, []),
                 Map.put(metrics_acc, p.id, nil)}
            end
          end)

        {sizes, drops} =
          if src_id = current_source_id(state) do
            if Process.whereis(Caudata.LogStore) do
              stats = Caudata.LogStore.get_stats(src_id)
              {Map.put(%{}, src_id, stats.size), Map.put(%{}, src_id, stats.drop_count)}
            else
              {%{}, %{}}
            end
          else
            {%{}, %{}}
          end

        new_state =
          %{
            state
            | statuses: statuses,
              containers: containers,
              metrics: metrics,
              buffer_sizes: Map.merge(state.buffer_sizes, sizes),
              drop_counts: Map.merge(state.drop_counts, drops)
          }
          |> maybe_auto_select_container()

        # Check Tailscale status and set initial notification if applicable
        new_state =
          case Caudata.Tailscale.Service.get_status() do
            :connecting ->
              %{new_state | notification: {"Connecting to Tailscale network...", 25}}

            {:connected, ip_str} ->
              %{new_state | notification: {"Tailscale connected successfully! IP: #{ip_str}", 25}}

            {:error, err} ->
              %{new_state | notification: {"Error connecting to Tailscale: #{inspect(err)}", 25}}

            _ ->
              new_state
          end

        noreply(state, new_state)

      :tick ->
        state = %{state | tick_scheduled: false}
        # Get the enabled containers for the selected profile
        enabled_conts_for_profile =
          case Enum.find(state.profiles, &(&1.id == state.selected_profile_id)) do
            nil ->
              []

            profile ->
              containers = Map.get(state.containers, profile.id, [])
              Caudata.UI.ViewHelper.get_enabled_containers(profile, containers)
          end

        # Auto-select first container of selected profile if none selected
        {selected_container_id, selected_container_name, logs_scroll_y} =
          if is_nil(state.selected_container_id) and state.selected_profile_id do
            case enabled_conts_for_profile do
              [first_container | _] ->
                case Caudata.ServerSupervisor.lookup_worker(state.selected_profile_id) do
                  {:ok, pid} ->
                    Task.start(fn ->
                      try do
                        GenServer.call(pid, {:stream_container_logs, first_container.id}, 10_000)
                      catch
                        :exit, _ -> :ok
                      end
                    end)

                    :ok

                  _ ->
                    :ok
                end

                {first_container.id, first_container.name, :bottom}

              _ ->
                {state.selected_container_id, state.selected_container_name, state.logs_scroll_y}
            end
          else
            {state.selected_container_id, state.selected_container_name, state.logs_scroll_y}
          end

        # If logs are dirty or we are loading history, fetch latest snapshot from LogStore
        {new_logs, logs_dirty} =
          if state.selected_profile_id && not state.freeze &&
               (state.logs_dirty or state.loading_history) do
            source_id =
              if selected_container_id do
                "#{state.selected_profile_id}/#{selected_container_id}"
              else
                state.selected_profile_id
              end

            if Process.whereis(Caudata.LogStore) do
              {Caudata.LogStore.get_snapshot(Caudata.LogStore, source_id, state.logs_fetch_limit),
               false}
            else
              {state.logs, false}
            end
          else
            {state.logs, state.logs_dirty}
          end

        # Handle loading_history state machine transitions to avoid flashing/jumping:
        loading_ticks = if state.loading_history, do: state.loading_history_ticks + 1, else: 0

        {logs, loading_history, scroll_y, visual_cursor, visual_anchor} =
          if state.loading_history do
            cond do
              length(new_logs) > state.logs_len_before_history_load ->
                displayed_before =
                  if state.logs == [], do: [], else: ViewHelper.get_displayed_logs(state)

                displayed_after =
                  ViewHelper.get_displayed_logs(%{
                    state
                    | logs: new_logs,
                      selected_container_id: selected_container_id
                  })

                m_displayed = length(displayed_after) - length(displayed_before)

                inner_width = ViewHelper.get_logs_inner_width(state)
                prepended_displayed = Enum.take(displayed_after, m_displayed)

                prepended_wrapped =
                  ViewHelper.count_wrapped_lines(prepended_displayed, inner_width)

                logs_height = ViewHelper.get_logs_pane_height(state)
                wrapped_after_count = ViewHelper.count_wrapped_lines(displayed_after, inner_width)
                new_max_scroll = max(0, wrapped_after_count - logs_height)

                new_scroll =
                  case state.logs_scroll_y do
                    :bottom -> :bottom
                    val -> min(new_max_scroll, max(0, val + prepended_wrapped - 1))
                  end

                # Adjust visual cursor/anchor by the number of newly prepended logs
                vc =
                  if state.mode == :selecting and state.visual_cursor != nil,
                    do: state.visual_cursor + m_displayed,
                    else: state.visual_cursor

                va =
                  if state.mode == :selecting and state.visual_anchor != nil,
                    do: state.visual_anchor + m_displayed,
                    else: state.visual_anchor

                {new_logs, false, new_scroll, vc, va}

              loading_ticks >= 8 ->
                # Timeout: fallback to currently displayed logs
                {state.logs, false, logs_scroll_y, state.visual_cursor, state.visual_anchor}

              true ->
                # Still loading: keep showing old logs to prevent flashing
                {state.logs, true, logs_scroll_y, state.visual_cursor, state.visual_anchor}
            end
          else
            inner_width = ViewHelper.get_logs_inner_width(state)
            raw_shift = ViewHelper.find_overlap_index(state.logs, new_logs) || 0

            new_scroll =
              case logs_scroll_y do
                :bottom ->
                  :bottom

                val when is_integer(val) ->
                  shift =
                    state.logs
                    |> Enum.take(raw_shift)
                    |> ViewHelper.count_wrapped_lines(inner_width)

                  max(0, val - shift)
              end

            new_cursor =
              if state.visual_cursor, do: max(0, state.visual_cursor - raw_shift), else: nil

            new_anchor =
              if state.visual_anchor, do: max(0, state.visual_anchor - raw_shift), else: nil

            {new_logs, false, new_scroll, new_cursor, new_anchor}
          end

        # Decrement notification tick if active
        notification =
          case state.notification do
            {msg, ticks} when ticks > 1 -> {msg, ticks - 1}
            _ -> nil
          end

        new_state = %{
          state
          | selected_container_id: selected_container_id,
            selected_container_name: selected_container_name,
            logs: logs,
            logs_scroll_y: scroll_y,
            loading_history: loading_history,
            loading_history_ticks: loading_ticks,
            logs_dirty: logs_dirty,
            notification: notification,
            visual_cursor: visual_cursor,
            visual_anchor: visual_anchor
        }

        noreply(state, new_state)

      {:update_available, tag_name} ->
        {:noreply, %{state | update_available: tag_name}}

      {:profiles_updated, all_profiles} ->
        {:noreply, %{state | profiles: all_profiles}}

      {:status_updated, server_id, status} ->
        new_containers =
          if status == :disconnected do
            Map.put(state.containers, server_id, [])
          else
            state.containers
          end

        new_metrics =
          if status != :connected do
            Map.put(state.metrics, server_id, nil)
          else
            state.metrics
          end

        {:noreply,
         %{
           state
           | statuses: Map.put(state.statuses, server_id, status),
             containers: new_containers,
             metrics: new_metrics
         }}

      {:tailscale_status, :connecting} ->
        noreply(state, %{state | notification: {"Connecting to Tailscale network...", 25}})

      {:tailscale_status, {:connected, ip_str}} ->
        noreply(state, %{
          state
          | notification: {"Tailscale connected successfully! IP: #{ip_str}", 25}
        })

      {:tailscale_status, {:error, err}} ->
        noreply(state, %{
          state
          | notification: {"Error connecting to Tailscale: #{inspect(err)}", 25}
        })

      {:metrics_updated, server_id, metrics} ->
        {:noreply, %{state | metrics: Map.put(state.metrics, server_id, metrics)}}

      {:containers_updated, server_id, containers} ->
        new_state = %{state | containers: Map.put(state.containers, server_id, containers)}
        new_state = maybe_auto_select_container(new_state)
        {:noreply, new_state}

      {:container_rebuilt, server_id, name, old_id, new_id} ->
        new_state =
          if state.selected_profile_id == server_id &&
               (state.selected_container_id == old_id ||
                  (state.selected_container_name == name && name != nil)) do
            source_id = "#{server_id}/#{new_id}"

            initial_logs =
              if Process.whereis(Caudata.LogStore) do
                Caudata.LogStore.get_snapshot(Caudata.LogStore, source_id, state.logs_fetch_limit)
              else
                []
              end

            new_state = %{
              state
              | selected_container_id: new_id,
                selected_container_name: name,
                logs: initial_logs
            }

            adjust_log_subscription(state, new_state)
          else
            state
          end

        {:noreply, new_state}

      {:logs_updated, source_id, %{size: size, drop_count: drops}} ->
        current_src = current_source_id(state)
        logs_dirty = state.logs_dirty || source_id == current_src

        tick_scheduled =
          if logs_dirty and not state.freeze and not Map.get(state, :tick_scheduled, false) do
            Process.send_after(self(), :tick, 100)
            true
          else
            Map.get(state, :tick_scheduled, false)
          end

        new_state = %{
          state
          | buffer_sizes: Map.put(state.buffer_sizes, source_id, size),
            drop_counts: Map.put(state.drop_counts, source_id, drops),
            logs_dirty: logs_dirty,
            tick_scheduled: tick_scheduled
        }

        {:noreply, new_state}

      {:logs_cleared, source_id} ->
        new_state =
          if source_id == current_source_id(state) do
            %{
              state
              | logs: [],
                buffer_sizes: Map.put(state.buffer_sizes, source_id, 0),
                drop_counts: Map.put(state.drop_counts, source_id, 0),
                logs_scroll_y: :bottom,
                logs_dirty: false
            }
          else
            state
          end

        {:noreply, new_state}

      {:select_profile, profile_id} ->
        {new_state, []} = KeyHandler.select_item({:server, profile_id}, state)
        {:noreply, adjust_log_subscription(state, new_state)}

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

        {:noreply, adjust_log_subscription(state, new_state)}

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

  defp noreply(old_state, new_state) do
    new_state = adjust_log_subscription(old_state, new_state)

    new_state =
      if new_state.notification && not Map.get(new_state, :tick_scheduled, false) do
        Process.send_after(self(), :tick, 100)
        %{new_state | tick_scheduled: true}
      else
        new_state
      end

    {:noreply, new_state}
  end

  defp update_freeze_state(state) do
    case state.logs_scroll_y do
      :bottom ->
        if state.freeze do
          state = %{state | freeze: false, logs_dirty: true}

          if not Map.get(state, :tick_scheduled, false) do
            Process.send_after(self(), :tick, 100)
            %{state | tick_scheduled: true}
          else
            state
          end
        else
          state
        end

      val when is_integer(val) ->
        %{state | freeze: true}
    end
  end

  defp adjust_log_subscription(old_state, new_state) do
    old_source = if old_state, do: current_source_id(old_state), else: nil
    new_source = current_source_id(new_state)

    new_state =
      if old_source != new_source do
        if old_source && Process.whereis(Caudata.PubSub) do
          Phoenix.PubSub.unsubscribe(Caudata.PubSub, "logs:#{old_source}")
        end

        if new_source && Process.whereis(Caudata.PubSub) do
          Phoenix.PubSub.subscribe(Caudata.PubSub, "logs:#{new_source}")
        end

        # Force log fetch and reset scroll/freeze on source change
        %{new_state | logs_dirty: true, freeze: false, logs_scroll_y: :bottom}
      else
        new_state
      end

    update_freeze_state(new_state)
  end

  defp maybe_auto_select_container(state) do
    if is_nil(state.selected_container_id) and state.selected_profile_id do
      profile = Enum.find(state.profiles, &(&1.id == state.selected_profile_id))
      containers = Map.get(state.containers, state.selected_profile_id, [])
      enabled_containers = Caudata.UI.ViewHelper.get_enabled_containers(profile, containers)

      case enabled_containers do
        [first_container | _] ->
          {new_state, _cmds} =
            KeyHandler.select_item(
              {:container, state.selected_profile_id, first_container.id, first_container.name},
              state
            )

          adjust_log_subscription(state, new_state)

        _ ->
          state
      end
    else
      state
    end
  end

  defp current_source_id(state) do
    cond do
      state.selected_profile_id && state.selected_container_id ->
        "#{state.selected_profile_id}/#{state.selected_container_id}"

      state.selected_profile_id ->
        state.selected_profile_id

      true ->
        nil
    end
  end

  @impl true
  def render(state, frame) do
    Renderer.render(state, frame)
  end
end
