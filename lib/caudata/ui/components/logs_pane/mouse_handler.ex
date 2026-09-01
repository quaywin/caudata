defmodule Caudata.UI.Components.LogsPane.MouseHandler do
  @moduledoc """
  Handles mouse events (scroll wheel, click, drag selection) for Caudata's Logs Pane.
  Maps screen mouse coordinates (x, y) to log line indices and integrates with Visual Mode state.
  """

  alias ExRatatui.Layout.Rect
  alias Caudata.UI.ViewHelper

  alias Caudata.UI.KeyRegistry

  @doc """
  Main entry point for handling %ExRatatui.Event.Mouse{} events.
  Routes mouse events using KeyRegistry.determine_context(state) as Single Source of Truth.
  """
  def handle_mouse(%ExRatatui.Event.Mouse{} = mouse, state) do
    context = KeyRegistry.determine_context(state)
    logs_area = get_logs_area(state)
    sidebar_area = get_sidebar_area(state)
    footer_y = Map.get(state, :height, 24) - 1

    cond do
      # 1. Left click on Footer Bar (available in all contexts)
      mouse.kind == "down" and mouse.button == "left" and mouse.y >= footer_y ->
        handle_footer_click(mouse, state)

      # 2. Modal Contexts: Route mouse events specifically within active modal dialogs
      context in [
        :help,
        :settings_input,
        :settings_service_search,
        :settings_tab,
        :container_action,
        :confirm_docker_action,
        :container_inspect,
        :level_filter
      ] or Map.get(state, :modal_visible, false) ->
        cond do
          mouse.kind == "down" and mouse.button == "left" ->
            handle_modal_click(context, mouse, state)

          mouse.kind in ["scroll_up", "scroll_down"] ->
            handle_modal_scroll(mouse.kind, context, state)

          true ->
            {state, []}
        end

      # 3. Main View Contexts (:normal, :selecting, :searching)
      true ->
        handle_main_view_mouse(mouse, state, logs_area, sidebar_area)
    end
  end

  defp handle_main_view_mouse(mouse, state, logs_area, sidebar_area) do
    cond do
      # Handle mouse scroll up / down over logs area (or fullscreen)
      mouse.kind in ["scroll_up", "scroll_down"] and inside_area?(mouse, logs_area) ->
        handle_scroll(mouse.kind, state)

      # Left click down inside Logs Pane: Switch focus to :logs panel, start drag selection
      mouse.kind == "down" and mouse.button == "left" and inside_area?(mouse, logs_area) ->
        handle_mouse_down(mouse, state, logs_area)

      # Left click down inside Sidebar: Select server or container under cursor
      mouse.kind == "down" and mouse.button == "left" and inside_area?(mouse, sidebar_area) ->
        handle_sidebar_click(mouse, state, sidebar_area)

      # Drag selection inside or through Logs Pane
      mouse.kind == "drag" and mouse.button == "left" and state.mode == :selecting ->
        handle_mouse_drag(mouse, state, logs_area)

      # Mouse up to end drag selection
      mouse.kind == "up" and mouse.button == "left" ->
        handle_mouse_up(state)

      true ->
        {state, []}
    end
  end

  # ── Scroll Handling ───────────────────────────────────────────────────

  defp handle_scroll("scroll_up", state) do
    displayed_logs = ViewHelper.get_displayed_logs(state)
    max_scroll = get_max_scroll(state, displayed_logs)
    current_scroll = get_current_scroll(state, max_scroll)

    new_scroll = max(0, current_scroll - 3)

    new_state =
      %{
        state
        | logs_scroll_y: new_scroll,
          active_panel: :logs,
          mode: :browsing,
          visual_anchor: nil,
          visual_cursor: nil
      }
      |> Map.put(:mouse_dragging, false)
      |> Map.put(:mouse_drag_auto_scroll, nil)

    if new_scroll == 0 and current_scroll > 0 and state.logs_fetch_limit < 10000 and
         not state.loading_history do
      new_limit = min(state.logs_fetch_limit + 1000, 10000)

      load_state = %{
        new_state
        | logs_fetch_limit: new_limit,
          loading_history: true,
          logs_len_before_history_load: length(state.logs)
      }

      {load_state, [{:command, {:load_history, new_limit}}]}
    else
      {new_state, []}
    end
  end

  defp handle_scroll("scroll_down", state) do
    displayed_logs = ViewHelper.get_displayed_logs(state)
    max_scroll = get_max_scroll(state, displayed_logs)
    current_scroll = get_current_scroll(state, max_scroll)

    new_scroll = min(max_scroll, current_scroll + 3)

    final_scroll =
      if new_scroll >= max_scroll do
        :bottom
      else
        new_scroll
      end

    {
      %{
        state
        | logs_scroll_y: final_scroll,
          active_panel: :logs,
          mode: :browsing,
          visual_anchor: nil,
          visual_cursor: nil,
          freeze: final_scroll != :bottom
      }
      |> Map.put(:mouse_dragging, false)
      |> Map.put(:mouse_drag_auto_scroll, nil),
      []
    }
  end

  # ── Drag Selection Handling ──────────────────────────────────────────

  defp handle_mouse_down(mouse, state, logs_area) do
    inner = ViewHelper.inner_rect(logs_area)

    state = %{state | active_panel: :logs}
    displayed_logs = ViewHelper.get_displayed_logs(state)

    if displayed_logs != [] do
      max_scroll = get_max_scroll(state, displayed_logs)
      current_scroll = get_current_scroll(state, max_scroll)

      log_index =
        screen_y_to_log_index(
          mouse.y,
          inner,
          %{state | logs_scroll_y: current_scroll},
          displayed_logs
        )

      new_state =
        %{
          state
          | mode: :selecting,
            visual_anchor: log_index,
            visual_cursor: log_index,
            logs_scroll_y: current_scroll,
            freeze: true
        }
        |> Map.put(:mouse_dragging, false)
        |> Map.put(:mouse_drag_auto_scroll, nil)

      {new_state, []}
    else
      {state, []}
    end
  end

  defp handle_mouse_drag(mouse, state, logs_area) do
    inner = ViewHelper.inner_rect(logs_area)
    displayed_logs = ViewHelper.get_displayed_logs(state)

    if displayed_logs != [] do
      inner_width = ViewHelper.get_logs_inner_width(state)
      logs_height = ViewHelper.get_logs_pane_height(state)
      max_scroll = get_max_scroll(state, displayed_logs)
      last_log_idx = max(0, length(displayed_logs) - 1)
      current_scroll = get_current_scroll(state, max_scroll)

      log_index_at_visual_y = fn visual_y ->
        displayed_logs
        |> Caudata.UI.Components.LogsPane.EventHandler.get_raw_index_at_scroll(
          visual_y,
          inner_width
        )
        |> clamp(0, last_log_idx)
      end

      top_edge = inner.y
      bottom_edge = inner.y + logs_height - 1

      cond do
        # Dragging at or below bottom edge -> auto-scroll DOWN
        mouse.y >= bottom_edge ->
          bottom_log_idx = log_index_at_visual_y.(current_scroll + max(0, logs_height - 1))

          if mouse.y > bottom_edge or state.visual_cursor == bottom_log_idx do
            scroll_delta = clamp(max(1, mouse.y - bottom_edge), 1, 5)

            if current_scroll < max_scroll do
              if Map.get(state, :mouse_drag_auto_scroll) == nil do
                Process.send_after(self(), :mouse_drag_tick, 60)
              end

              new_scroll = min(max_scroll, current_scroll + scroll_delta)
              new_cursor = log_index_at_visual_y.(new_scroll + max(0, logs_height - 1))

              new_state = %{
                state
                | logs_scroll_y: new_scroll,
                  visual_cursor: new_cursor,
                  mouse_dragging: true,
                  mouse_drag_auto_scroll: {:down, scroll_delta}
              }

              {new_state, []}
            else
              new_state = %{
                state
                | logs_scroll_y: current_scroll,
                  visual_cursor: bottom_log_idx,
                  mouse_dragging: true,
                  mouse_drag_auto_scroll: nil
              }

              {new_state, []}
            end
          else
            new_state = %{
              state
              | logs_scroll_y: current_scroll,
                visual_cursor: bottom_log_idx,
                mouse_dragging: true,
                mouse_drag_auto_scroll: nil
            }

            {new_state, []}
          end

        # Dragging at or above top edge -> auto-scroll UP
        mouse.y <= top_edge ->
          top_log_idx = log_index_at_visual_y.(current_scroll)

          if mouse.y < top_edge or state.visual_cursor == top_log_idx do
            scroll_delta = clamp(max(1, top_edge - mouse.y), 1, 5)

            if current_scroll > 0 do
              if Map.get(state, :mouse_drag_auto_scroll) == nil do
                Process.send_after(self(), :mouse_drag_tick, 60)
              end

              new_scroll = max(0, current_scroll - scroll_delta)
              new_cursor = log_index_at_visual_y.(new_scroll)

              new_state = %{
                state
                | logs_scroll_y: new_scroll,
                  visual_cursor: new_cursor,
                  mouse_dragging: true,
                  mouse_drag_auto_scroll: {:up, scroll_delta}
              }

              if new_scroll == 0 and current_scroll > 0 and state.logs_fetch_limit < 10000 and
                   not state.loading_history do
                new_limit = min(state.logs_fetch_limit + 1000, 10000)

                load_state = %{
                  new_state
                  | logs_fetch_limit: new_limit,
                    loading_history: true,
                    logs_len_before_history_load: length(state.logs)
                }

                {load_state, [{:command, {:load_history, new_limit}}]}
              else
                {new_state, []}
              end
            else
              # At top (current_scroll == 0)
              new_state = %{
                state
                | logs_scroll_y: current_scroll,
                  visual_cursor: top_log_idx,
                  mouse_dragging: true,
                  mouse_drag_auto_scroll: nil
              }

              if state.logs_fetch_limit < 10000 and not state.loading_history do
                new_limit = min(state.logs_fetch_limit + 1000, 10000)

                load_state = %{
                  new_state
                  | logs_fetch_limit: new_limit,
                    loading_history: true,
                    logs_len_before_history_load: length(state.logs)
                }

                {load_state, [{:command, {:load_history, new_limit}}]}
              else
                {new_state, []}
              end
            end
          else
            new_state = %{
              state
              | logs_scroll_y: current_scroll,
                visual_cursor: top_log_idx,
                mouse_dragging: true,
                mouse_drag_auto_scroll: nil
            }

            {new_state, []}
          end

        # Dragging strictly inside the visible logs area
        true ->
          relative_y = clamp(mouse.y - top_edge, 0, max(0, logs_height - 1))
          log_index = log_index_at_visual_y.(current_scroll + relative_y)

          new_state = %{
            state
            | logs_scroll_y: current_scroll,
              visual_cursor: log_index,
              mouse_dragging: true,
              mouse_drag_auto_scroll: nil
          }

          {new_state, []}
      end
    else
      {state, []}
    end
  end

  defp handle_mouse_up(state) do
    dragging? = Map.get(state, :mouse_dragging, false)
    state = Map.merge(state, %{mouse_dragging: false, mouse_drag_auto_scroll: nil})

    if dragging? and state.visual_anchor != nil and state.visual_cursor != nil and
         state.visual_anchor != state.visual_cursor do
      displayed_logs = ViewHelper.get_displayed_logs(state)
      Caudata.UI.Components.LogsPane.EventHandler.copy_selected_logs(state, displayed_logs)
    else
      {state, []}
    end
  end

  @doc """
  Handles periodic auto-scrolling ticks during mouse drag-selection.
  """
  def handle_drag_tick(state) do
    auto_scroll = Map.get(state, :mouse_drag_auto_scroll)

    if state.mode == :selecting and auto_scroll != nil do
      displayed_logs = ViewHelper.get_displayed_logs(state)

      if displayed_logs != [] do
        inner_width = ViewHelper.get_logs_inner_width(state)
        logs_height = ViewHelper.get_logs_pane_height(state)
        max_scroll = get_max_scroll(state, displayed_logs)
        last_log_idx = max(0, length(displayed_logs) - 1)
        current_scroll = get_current_scroll(state, max_scroll)

        log_index_at_visual_y = fn visual_y ->
          displayed_logs
          |> Caudata.UI.Components.LogsPane.EventHandler.get_raw_index_at_scroll(
            visual_y,
            inner_width
          )
          |> clamp(0, last_log_idx)
        end

        case auto_scroll do
          {:down, delta} ->
            if current_scroll < max_scroll do
              new_scroll = min(max_scroll, current_scroll + delta)
              new_cursor = log_index_at_visual_y.(new_scroll + max(0, logs_height - 1))
              Process.send_after(self(), :mouse_drag_tick, 60)
              new_state = %{state | logs_scroll_y: new_scroll, visual_cursor: new_cursor}
              {new_state, []}
            else
              bottom_log_idx = log_index_at_visual_y.(current_scroll + max(0, logs_height - 1))
              new_state = %{state | visual_cursor: bottom_log_idx, mouse_drag_auto_scroll: nil}
              {new_state, []}
            end

          {:up, delta} ->
            if current_scroll > 0 do
              new_scroll = max(0, current_scroll - delta)
              new_cursor = log_index_at_visual_y.(new_scroll)
              Process.send_after(self(), :mouse_drag_tick, 60)
              new_state = %{state | logs_scroll_y: new_scroll, visual_cursor: new_cursor}

              if new_scroll == 0 and state.logs_fetch_limit < 10000 and not state.loading_history do
                new_limit = min(state.logs_fetch_limit + 1000, 10000)

                load_state = %{
                  new_state
                  | logs_fetch_limit: new_limit,
                    loading_history: true,
                    logs_len_before_history_load: length(state.logs)
                }

                {load_state, [{:command, {:load_history, new_limit}}]}
              else
                {new_state, []}
              end
            else
              top_log_idx = log_index_at_visual_y.(0)
              new_state = %{state | visual_cursor: top_log_idx, mouse_drag_auto_scroll: nil}

              if state.logs_fetch_limit < 10000 and not state.loading_history do
                new_limit = min(state.logs_fetch_limit + 1000, 10000)

                load_state = %{
                  new_state
                  | logs_fetch_limit: new_limit,
                    loading_history: true,
                    logs_len_before_history_load: length(state.logs)
                }

                {load_state, [{:command, {:load_history, new_limit}}]}
              else
                {new_state, []}
              end
            end

          _ ->
            {Map.put(state, :mouse_drag_auto_scroll, nil), []}
        end
      else
        {Map.put(state, :mouse_drag_auto_scroll, nil), []}
      end
    else
      {Map.put(state, :mouse_drag_auto_scroll, nil), []}
    end
  end

  # ── Sidebar Mouse Selection ──────────────────────────────────────────

  defp handle_sidebar_click(mouse, state, sidebar_area) do
    state =
      %{
        state
        | active_panel: :sidebar,
          mode: :browsing,
          visual_anchor: nil,
          visual_cursor: nil
      }
      |> Map.put(:mouse_dragging, false)
      |> Map.put(:mouse_drag_auto_scroll, nil)

    h = sidebar_area.height

    {box1_area, box2_area} =
      if h >= 18 do
        {h1, h3, h4} =
          cond do
            h >= 30 -> {10, 7, 5}
            h >= 24 -> {8, 6, 5}
            true -> {6, 5, 5}
          end

        box1 = %Rect{x: sidebar_area.x, y: sidebar_area.y, width: sidebar_area.width, height: h1}

        box2 = %Rect{
          x: sidebar_area.x,
          y: sidebar_area.y + h1,
          width: sidebar_area.width,
          height: max(0, h - (h1 + h3 + h4))
        }

        {box1, box2}
      else
        servers_h = if h >= 10, do: 6, else: max(3, div(h, 2))

        box1 = %Rect{
          x: sidebar_area.x,
          y: sidebar_area.y,
          width: sidebar_area.width,
          height: servers_h
        }

        box2 = %Rect{
          x: sidebar_area.x,
          y: sidebar_area.y + servers_h,
          width: sidebar_area.width,
          height: max(0, h - servers_h)
        }

        {box1, box2}
      end

    cond do
      inside_area?(mouse, ViewHelper.inner_rect(box1_area)) ->
        inner = ViewHelper.inner_rect(box1_area)
        row = mouse.y - inner.y

        if row >= 0 and row < length(state.profiles) do
          profile = Enum.at(state.profiles, row)
          {new_state, cmds} = Caudata.UI.Components.Sidebar.select_server(profile.id, state)
          {Map.put(new_state, :sidebar_focus, :servers), cmds}
        else
          {Map.put(state, :sidebar_focus, :servers), []}
        end

      inside_area?(mouse, ViewHelper.inner_rect(box2_area)) ->
        inner = ViewHelper.inner_rect(box2_area)
        row = mouse.y - inner.y

        selected_profile = Enum.find(state.profiles, &(&1.id == state.selected_profile_id))

        enabled_containers =
          if selected_profile do
            ViewHelper.get_enabled_containers(
              selected_profile,
              Map.get(state.containers, selected_profile.id, [])
            )
          else
            []
          end

        if row >= 0 and row < length(enabled_containers) do
          container = Enum.at(enabled_containers, row)

          {new_state, cmds} =
            Caudata.UI.Components.Sidebar.select_container(
              selected_profile.id,
              container.id,
              container.name,
              state
            )

          {Map.put(new_state, :sidebar_focus, :containers), cmds}
        else
          {Map.put(state, :sidebar_focus, :containers), []}
        end

      true ->
        {state, []}
    end
  end

  # ── Helpers ─────────────────────────────────────────────────────────

  def get_logs_area(state) do
    width = Map.get(state, :width, 80)
    height = Map.get(state, :height, 24)
    main_height = max(1, height - 2)

    if Map.get(state, :logs_full_screen, false) do
      %Rect{x: 0, y: 0, width: width, height: main_height}
    else
      %Rect{x: 38, y: 0, width: max(0, width - 38), height: main_height}
    end
  end

  def get_sidebar_area(state) do
    height = Map.get(state, :height, 24)
    main_height = max(1, height - 2)

    if Map.get(state, :logs_full_screen, false) do
      %Rect{x: 0, y: 0, width: 0, height: 0}
    else
      %Rect{x: 0, y: 0, width: min(38, Map.get(state, :width, 80)), height: main_height}
    end
  end

  def inside_area?(%ExRatatui.Event.Mouse{x: x, y: y}, %Rect{x: rx, y: ry, width: rw, height: rh}) do
    x >= rx and x < rx + rw and y >= ry and y < ry + rh
  end

  def screen_y_to_log_index(mouse_y, %Rect{y: ry, height: rh}, state, displayed_logs) do
    inner_width = ViewHelper.get_logs_inner_width(state)
    max_scroll = get_max_scroll(state, displayed_logs)
    current_scroll = get_current_scroll(state, max_scroll)

    relative_y = clamp(mouse_y - ry, 0, rh - 1)
    target_visual_y = current_scroll + relative_y

    log_index =
      Caudata.UI.Components.LogsPane.EventHandler.get_raw_index_at_scroll(
        displayed_logs,
        target_visual_y,
        inner_width
      )

    max_idx = max(0, length(displayed_logs) - 1)
    clamp(log_index, 0, max_idx)
  end

  defp get_current_scroll(state, max_scroll) do
    case state.logs_scroll_y do
      :bottom -> max_scroll
      val when is_integer(val) -> val
      _ -> 0
    end
  end

  defp get_max_scroll(state, displayed_logs) do
    inner_width = ViewHelper.get_logs_inner_width(state)
    logs_height = ViewHelper.get_logs_pane_height(state)
    wrapped_lines_count = ViewHelper.count_wrapped_lines(displayed_logs, inner_width)
    max(0, wrapped_lines_count - logs_height)
  end

  defp clamp(val, min_val, max_val) do
    val |> max(min_val) |> min(max_val)
  end

  # ── Footer Mouse Action Bar ──────────────────────────────────────────

  defp handle_footer_click(%ExRatatui.Event.Mouse{x: x}, state) do
    shortcuts = Caudata.UI.KeyRegistry.get_shortcuts(state)

    shortcut_hit =
      shortcuts
      |> Enum.reduce_while(0, fn s, col_acc ->
        len = String.length(s.key <> " " <> s.label)
        next_acc = col_acc + len

        if x >= col_acc and x < next_acc do
          {:halt, s}
        else
          {:cont, next_acc}
        end
      end)

    case shortcut_hit do
      %{key: key_str} ->
        key_data = parse_key_from_shortcut(key_str)
        Caudata.UI.KeyHandler.handle_key_event(key_data, state)

      _ ->
        {state, []}
    end
  end

  defp parse_key_from_shortcut(key_str) do
    cond do
      String.contains?(key_str, "Tab") or String.contains?(key_str, "1-3") ->
        %{key: :tab, modifiers: []}

      String.contains?(key_str, "m/Enter") ->
        %{key: :char, char: "m", modifiers: []}

      String.contains?(key_str, "y/Enter") ->
        %{key: :char, char: "y", modifiers: []}

      String.contains?(key_str, "n/Esc") ->
        %{key: :char, char: "n", modifiers: []}

      String.contains?(key_str, "Space") ->
        %{key: :char, char: " ", modifiers: []}

      String.contains?(key_str, "d/") or key_str == "[d]" ->
        %{key: :char, char: "d", modifiers: []}

      String.contains?(key_str, "g/G") ->
        %{key: :char, char: "g", modifiers: []}

      String.contains?(key_str, "o") ->
        %{key: :char, char: "o", modifiers: []}

      String.contains?(key_str, "r") ->
        %{key: :char, char: "r", modifiers: []}

      String.contains?(key_str, "a") ->
        %{key: :char, char: "a", modifiers: []}

      String.contains?(key_str, "s") and not String.contains?(key_str, "Esc") ->
        %{key: :char, char: "s", modifiers: []}

      String.contains?(key_str, "f") ->
        %{key: :char, char: "f", modifiers: []}

      String.contains?(key_str, "?") ->
        %{key: :char, char: "?", modifiers: []}

      String.contains?(key_str, "/") ->
        %{key: :char, char: "/", modifiers: []}

      String.contains?(key_str, "t") ->
        %{key: :char, char: "t", modifiers: []}

      String.contains?(key_str, "v") ->
        %{key: :char, char: "v", modifiers: []}

      String.contains?(key_str, "y") ->
        %{key: :char, char: "y", modifiers: []}

      String.contains?(key_str, "q") ->
        %{key: :char, char: "q", modifiers: []}

      String.contains?(key_str, "Esc") ->
        %{key: :escape, modifiers: []}

      String.contains?(key_str, "Enter") ->
        %{key: :enter, modifiers: []}

      true ->
        %{key: :char, char: "", modifiers: []}
    end
  end

  # ── Modal Mouse Handling ──────────────────────────────────────────────

  defp handle_modal_scroll(direction, _context, state) do
    modal_type = Map.get(state, :modal_type)

    cond do
      modal_type == :select_ssh ->
        options_count = length(Map.get(state, :ssh_config_profiles, [])) + 2
        current_index = Map.get(state, :modal_selected_index, 0)

        new_index =
          Caudata.UI.ViewHelper.navigate_bounded_index(current_index, direction, options_count)

        {Map.put(state, :modal_selected_index, new_index), []}

      modal_type == :settings ->
        case Map.get(state, :settings_focus, :servers) do
          :servers ->
            profiles = Map.get(state, :profiles, [])
            current = Map.get(state, :settings_selected_profile_idx, 0)

            new_idx =
              Caudata.UI.ViewHelper.navigate_bounded_index(current, direction, length(profiles))

            profile = Enum.at(profiles, new_idx)

            connection_fields =
              if profile do
                if Map.get(profile, :is_local, false) do
                  %{"password" => profile.password || ""}
                else
                  %{
                    "host_name" => profile.host_name || "",
                    "port" => to_string(profile.port || 22),
                    "user" => profile.user || "",
                    "identity_file" => profile.identity_file || "",
                    "password" => profile.password || ""
                  }
                end
              else
                %{}
              end

            {Map.merge(state, %{
               settings_selected_profile_idx: new_idx,
               settings_connection_fields: connection_fields
             }), []}

          :containers ->
            profile =
              Enum.find(
                Map.get(state, :profiles, []),
                &(&1.id == Map.get(state, :selected_profile_id))
              )

            containers = if profile, do: Map.get(state.containers, profile.id, []), else: []
            docker_only = Caudata.UI.ViewHelper.filter_docker_containers(containers)
            current = Map.get(state, :settings_container_idx, 0)

            new_idx =
              Caudata.UI.ViewHelper.navigate_bounded_index(
                current,
                direction,
                length(docker_only)
              )

            {Map.put(state, :settings_container_idx, new_idx), []}

          :services ->
            profile =
              Enum.find(
                Map.get(state, :profiles, []),
                &(&1.id == Map.get(state, :selected_profile_id))
              )

            containers = if profile, do: Map.get(state.containers, profile.id, []), else: []
            services_only = Caudata.UI.ViewHelper.filter_system_services(containers)

            filtered =
              Caudata.UI.Components.SettingsModal.ServicesTab.filter_services(
                services_only,
                Map.get(state, :settings_service_search, "")
              )

            current = Map.get(state, :settings_service_idx, 0)

            new_idx =
              Caudata.UI.ViewHelper.navigate_bounded_index(current, direction, length(filtered))

            {Map.put(state, :settings_service_idx, new_idx), []}

          :custom_logs ->
            profile =
              Enum.find(
                Map.get(state, :profiles, []),
                &(&1.id == Map.get(state, :selected_profile_id))
              )

            custom_logs = if profile, do: Map.get(profile, :custom_logs) || [], else: []
            current = Map.get(state, :settings_custom_log_idx, 0)

            new_idx =
              Caudata.UI.ViewHelper.navigate_bounded_index(
                current,
                direction,
                length(custom_logs)
              )

            {Map.put(state, :settings_custom_log_idx, new_idx), []}

          _ ->
            {state, []}
        end

      modal_type == :level_filter ->
        current = Map.get(state, :level_filter_modal_selected_index, 0)
        new_idx = Caudata.UI.ViewHelper.navigate_bounded_index(current, direction, 4)
        {Map.put(state, :level_filter_modal_selected_index, new_idx), []}

      modal_type == :container_action ->
        actions = Caudata.UI.Components.ContainerActionModal.get_available_actions(state)
        current = Map.get(state, :container_action_modal_selected_index, 0)

        new_idx =
          Caudata.UI.ViewHelper.navigate_bounded_index(current, direction, length(actions))

        {Map.put(state, :container_action_modal_selected_index, new_idx), []}

      modal_type == :container_inspect ->
        inspect_raw = Map.get(state, :container_inspect_data, "")
        mode = Map.get(state, :container_inspect_mode, :summary)

        formatted_lines =
          Caudata.UI.Components.ContainerInspectModal.format_inspect_data(inspect_raw, mode)

        total_lines = length(formatted_lines)
        inner_height = max(1, div(Map.get(state, :height, 24) * 80, 100) - 4)
        max_scroll = max(0, total_lines - inner_height)
        scroll_y = Map.get(state, :container_inspect_scroll_y, 0)

        new_scroll =
          if direction == "scroll_up",
            do: max(0, scroll_y - 1),
            else: min(max_scroll, scroll_y + 1)

        {Map.put(state, :container_inspect_scroll_y, new_scroll), []}

      modal_type == :help ->
        inner_height = max(1, div(Map.get(state, :height, 24) * 80, 100) - 4)
        max_scroll = max(0, Caudata.UI.Components.HelpModal.total_lines() - inner_height)
        scroll_y = Map.get(state, :help_modal_scroll_y, 0)

        new_scroll =
          if direction == "scroll_up",
            do: max(0, scroll_y - 1),
            else: min(max_scroll, scroll_y + 1)

        {Map.put(state, :help_modal_scroll_y, new_scroll), []}

      true ->
        {state, []}
    end
  end

  defp handle_modal_click(context, mouse, state) do
    w = Map.get(state, :width, 80)
    h = Map.get(state, :height, 24)

    cond do
      context in [:settings, :settings_input, :settings_service_search, :settings_tab] or
          Map.get(state, :modal_type) == :settings ->
        modal_w = clamp(div(w * 80, 100), 40, w)
        modal_h = clamp(div(h * 90, 100), 12, h)
        modal_x = div(w - modal_w, 2)
        modal_y = div(h - modal_h, 2)
        modal_rect = %Rect{x: modal_x, y: modal_y, width: modal_w, height: modal_h}

        if inside_area?(mouse, modal_rect) do
          inner = ViewHelper.inner_rect(modal_rect)
          rel_y = mouse.y - inner.y
          rel_x = mouse.x - inner.x

          cond do
            # Line 2 is tabs line
            rel_y == 2 ->
              tabs = [
                {:servers, " [ Servers ] "},
                {:connection, " [ SSH Connection ] "},
                {:containers, " [ Docker Containers ] "},
                {:services, " [ System Services ] "},
                {:custom_logs, " [ Custom Logs ] "}
              ]

              hit_tab =
                tabs
                |> Enum.reduce_while(0, fn {focus, name}, col_acc ->
                  len = String.length(name) + 1
                  next_acc = col_acc + len

                  if rel_x >= col_acc and rel_x < next_acc do
                    {:halt, focus}
                  else
                    {:cont, next_acc}
                  end
                end)

              case hit_tab do
                atom when is_atom(atom) ->
                  {Map.put(state, :settings_focus, atom), []}

                _ ->
                  {state, []}
              end

            # Tab content rows (rel_y >= 4)
            rel_y >= 4 ->
              display_rows_limit = max(3, modal_h - 11)
              clicked_row = rel_y - 4

              case state.settings_focus do
                :servers ->
                  total = length(Map.get(state, :profiles, []))

                  selected_idx =
                    min(
                      max(0, Map.get(state, :settings_selected_profile_idx, 0)),
                      max(0, total - 1)
                    )

                  start_row = ViewHelper.scroll_start_row(selected_idx, display_rows_limit)
                  target_idx = start_row + clicked_row

                  if clicked_row >= 0 and clicked_row < display_rows_limit and target_idx < total do
                    profile = Enum.at(state.profiles, target_idx)

                    connection_fields =
                      if profile do
                        if Map.get(profile, :is_local, false) do
                          %{"password" => profile.password || ""}
                        else
                          %{
                            "host_name" => profile.host_name || "",
                            "port" => to_string(profile.port || 22),
                            "user" => profile.user || "",
                            "identity_file" => profile.identity_file || "",
                            "password" => profile.password || ""
                          }
                        end
                      else
                        %{}
                      end

                    {Map.merge(state, %{
                       settings_selected_profile_idx: target_idx,
                       settings_connection_fields: connection_fields
                     }), []}
                  else
                    {state, []}
                  end

                :containers ->
                  profile =
                    Enum.find(
                      Map.get(state, :profiles, []),
                      &(&1.id == Map.get(state, :selected_profile_id))
                    )

                  containers = if profile, do: Map.get(state.containers, profile.id, []), else: []
                  docker_only = ViewHelper.filter_docker_containers(containers)
                  total = length(docker_only)

                  selected_idx =
                    min(max(0, Map.get(state, :settings_container_idx, 0)), max(0, total - 1))

                  start_row = ViewHelper.scroll_start_row(selected_idx, display_rows_limit)
                  target_idx = start_row + clicked_row

                  if clicked_row >= 0 and clicked_row < display_rows_limit and target_idx < total do
                    {Map.put(state, :settings_container_idx, target_idx), []}
                  else
                    {state, []}
                  end

                :services ->
                  profile =
                    Enum.find(
                      Map.get(state, :profiles, []),
                      &(&1.id == Map.get(state, :selected_profile_id))
                    )

                  containers = if profile, do: Map.get(state.containers, profile.id, []), else: []
                  services_only = ViewHelper.filter_system_services(containers)

                  filtered =
                    Caudata.UI.Components.SettingsModal.ServicesTab.filter_services(
                      services_only,
                      Map.get(state, :settings_service_search, "")
                    )

                  total = length(filtered)

                  selected_idx =
                    min(max(0, Map.get(state, :settings_service_idx, 0)), max(0, total - 1))

                  start_row = ViewHelper.scroll_start_row(selected_idx, display_rows_limit)
                  target_idx = start_row + clicked_row

                  if clicked_row >= 0 and clicked_row < display_rows_limit and target_idx < total do
                    {Map.put(state, :settings_service_idx, target_idx), []}
                  else
                    {state, []}
                  end

                :custom_logs ->
                  profile =
                    Enum.find(
                      Map.get(state, :profiles, []),
                      &(&1.id == Map.get(state, :selected_profile_id))
                    )

                  custom_logs = if profile, do: Map.get(profile, :custom_logs) || [], else: []
                  total = length(custom_logs)

                  selected_idx =
                    min(max(0, Map.get(state, :settings_custom_log_idx, 0)), max(0, total - 1))

                  start_row = ViewHelper.scroll_start_row(selected_idx, display_rows_limit)
                  target_idx = start_row + clicked_row

                  if clicked_row >= 0 and clicked_row < display_rows_limit and target_idx < total do
                    {Map.put(state, :settings_custom_log_idx, target_idx), []}
                  else
                    {state, []}
                  end

                _ ->
                  {state, []}
              end

            true ->
              {state, []}
          end
        else
          # Clicked outside modal window -> Close modal
          key_data = %{key: :escape, modifiers: []}
          Caudata.UI.KeyHandler.handle_key_event(key_data, state)
        end

      context == :level_filter or Map.get(state, :modal_type) == :level_filter ->
        modal_w = clamp(div(w * 58, 100), 30, w)
        modal_h = clamp(div(h * 40, 100), 8, h)
        modal_x = div(w - modal_w, 2)
        modal_y = div(h - modal_h, 2)
        modal_rect = %Rect{x: modal_x, y: modal_y, width: modal_w, height: modal_h}

        if inside_area?(mouse, modal_rect) do
          inner = ViewHelper.inner_rect(modal_rect)
          row = mouse.y - inner.y
          # Header is 2 rows (0, 1). Option items start at row 2
          opt_idx = row - 2

          if opt_idx in 0..3 do
            chosen_level = Caudata.UI.Components.LevelFilterModal.get_level_by_index(opt_idx)
            Caudata.UI.KeyRegistry.apply_level_filter(chosen_level, state)
          else
            {state, []}
          end
        else
          key_data = %{key: :escape, modifiers: []}
          Caudata.UI.KeyHandler.handle_key_event(key_data, state)
        end

      context == :container_action or Map.get(state, :modal_type) == :container_action ->
        modal_w = clamp(div(w * 55, 100), 30, w)
        modal_h = clamp(div(h * 35, 100), 8, h)
        modal_x = div(w - modal_w, 2)
        modal_y = div(h - modal_h, 2)
        modal_rect = %Rect{x: modal_x, y: modal_y, width: modal_w, height: modal_h}

        if inside_area?(mouse, modal_rect) do
          inner = ViewHelper.inner_rect(modal_rect)
          row = mouse.y - inner.y

          actions = Caudata.UI.Components.ContainerActionModal.get_available_actions(state)

          # Action options start at row 2
          action_idx = row - 2

          if action_idx >= 0 and action_idx < length(actions) do
            Caudata.UI.Components.ContainerActionModal.execute_action(action_idx, actions, state)
          else
            {state, []}
          end
        else
          # Clicked outside modal window -> Close modal
          key_data = %{key: :escape, modifiers: []}
          Caudata.UI.KeyHandler.handle_key_event(key_data, state)
        end

      context in [:select_ssh, :add_server] or Map.get(state, :modal_type) == :select_ssh ->
        modal_w = clamp(div(w * 70, 100), 40, w)
        modal_h = clamp(div(h * 60, 100), 10, h)
        modal_x = div(w - modal_w, 2)
        modal_y = div(h - modal_h, 2)
        modal_rect = %Rect{x: modal_x, y: modal_y, width: modal_w, height: modal_h}

        if inside_area?(mouse, modal_rect) do
          inner = ViewHelper.inner_rect(modal_rect)
          rel_y = mouse.y - inner.y

          # Header is 2 rows (title + separator). Options start at rel_y == 2
          clicked_row = rel_y - 2

          options = [
            {"+ Manual SSH Connection", :manual},
            {"+ Local Machine Connection", :local}
            | Enum.map(Map.get(state, :ssh_config_profiles, []), &{&1.id, &1})
          ]

          total_options = length(options)
          error_rows = if Map.get(state, :modal_error), do: 2, else: 0
          inner_height = max(3, modal_h - 2)
          display_rows_limit = max(3, inner_height - 2 - error_rows)

          selected_idx =
            min(max(0, Map.get(state, :modal_selected_index, 0)), max(0, total_options - 1))

          start_row =
            if selected_idx >= display_rows_limit,
              do: selected_idx - display_rows_limit + 1,
              else: 0

          target_idx = start_row + clicked_row

          if clicked_row >= 0 and clicked_row < display_rows_limit and target_idx < total_options do
            {Map.put(state, :modal_selected_index, target_idx), []}
          else
            {state, []}
          end
        else
          # Clicked outside modal window -> Close modal
          key_data = %{key: :escape, modifiers: []}
          Caudata.UI.KeyHandler.handle_key_event(key_data, state)
        end

      true ->
        handle_modal_backdrop_click(mouse, state)
    end
  end

  defp handle_modal_backdrop_click(mouse, state) do
    w = Map.get(state, :width, 80)
    h = Map.get(state, :height, 24)

    modal_w = clamp(div(w * 70, 100), 40, w)
    modal_h = clamp(div(h * 70, 100), 12, h)
    modal_x = div(w - modal_w, 2)
    modal_y = div(h - modal_h, 2)

    modal_rect = %Rect{x: modal_x, y: modal_y, width: modal_w, height: modal_h}

    if not inside_area?(mouse, modal_rect) do
      # Clicked on backdrop outside modal popup window -> Close modal
      key_data = %{key: :escape, modifiers: []}
      Caudata.UI.KeyHandler.handle_key_event(key_data, state)
    else
      {state, []}
    end
  end
end
