defmodule Caudata.UI.ViewHelper do
  @moduledoc """
  Shared helper functions for calculations and state lookup in the UI layer.
  """
  alias ExRatatui.Layout.Rect
  alias Caudata.UI.Cache

  @doc """
  Computes the inner rectangle for a widget pane by subtracting borders.
  """
  def inner_rect(%Rect{} = rect) do
    %Rect{
      x: rect.x + 1,
      y: rect.y + 1,
      width: max(0, rect.width - 2),
      height: max(0, rect.height - 2)
    }
  end

  @doc """
  Checks if a container struct represents a custom file log.
  """
  def file_container?(container) do
    case container do
      %{image: image, id: id} ->
        image == "file" or String.starts_with?(to_string(id), "file:")

      _ ->
        false
    end
  end

  @doc """
  Checks if a container struct represents a system service (systemd or launchd).
  """
  def service_container?(container) do
    case container do
      %{image: image, id: id} ->
        image in ["systemd", "launchd"] or
          String.starts_with?(to_string(id), "systemd:") or
          String.starts_with?(to_string(id), "launchd:")

      _ ->
        false
    end
  end

  @doc """
  Checks if a container struct represents a Docker container vs a custom file or system service.
  """
  def docker_container?(container) do
    case container do
      %{image: _image, id: _id} ->
        not file_container?(container) and not service_container?(container)

      _ ->
        false
    end
  end

  @doc """
  Filters a list of containers into Docker containers only.
  """
  def filter_docker_containers(containers) when is_list(containers) do
    Enum.filter(containers, &docker_container?/1)
  end

  def filter_docker_containers(_), do: []

  @doc """
  Filters a list of containers into System Services only (systemd/launchd).
  """
  def filter_system_services(containers) when is_list(containers) do
    Enum.filter(containers, &service_container?/1)
  end

  def filter_system_services(_), do: []

  @doc """
  Calculates the starting row index for windowed list scrolling.
  """
  def scroll_start_row(selected_idx, display_limit) when is_integer(selected_idx) and is_integer(display_limit) do
    if selected_idx >= display_limit, do: selected_idx - display_limit + 1, else: 0
  end

  def scroll_start_row(_selected_idx, _display_limit), do: 0

  @doc """
  Calculates the scroll offset to keep the selected item centered in the viewport.
  """
  def centered_scroll_y(selected_idx, total_count, inner_height)
      when is_integer(total_count) and is_integer(inner_height) do
    cond do
      total_count <= inner_height -> 0
      is_nil(selected_idx) -> 0
      true -> max(0, min(selected_idx - div(inner_height, 2), total_count - inner_height))
    end
  end

  def centered_scroll_y(_selected_idx, _total_count, _inner_height), do: 0

  @doc """
  Slices an enumerable or list into a visible window based on selected index and display limit.
  """
  def window_slice(items, selected_idx, display_limit) when is_list(items) do
    start = scroll_start_row(selected_idx, display_limit)
    Enum.slice(items, start, display_limit)
  end

  def window_slice(_items, _selected_idx, _display_limit), do: []

  @doc """
  Calculates the new index when navigating a list with bounded limits (0 to total - 1).
  Supports :up, :down, :home, :end, :page_up, :page_down, "k", "j", "g", "G", "scroll_up", "scroll_down".
  """
  def navigate_bounded_index(current_idx, key, total, page_step \\ 10) do
    max_idx = max(0, total - 1)
    idx = min(max(0, current_idx || 0), max_idx)

    case key do
      k when k in [:up, "k", "K", "scroll_up"] ->
        max(0, idx - 1)

      k when k in [:down, "j", "J", "scroll_down"] ->
        min(max_idx, idx + 1)

      k when k in [:home, "g"] ->
        0

      k when k in [:end, "G"] ->
        max_idx

      k when k in [:page_up, :pageup] ->
        max(0, idx - page_step)

      k when k in [:page_down, :pagedown] ->
        min(max_idx, idx + page_step)

      _ ->
        idx
    end
  end

  @doc """
  Computes the inner width of a popup based on terminal width and popup percent.
  """
  def popup_inner_width(width, percent) do
    max(10, div(width * percent, 100) - 4)
  end

  @doc """
  Renders a vertical list of form input fields with active indicator and optional password masking.
  """
  def render_form_fields(fields_config, fields_map, active_focus_idx) do
    Enum.with_index(fields_config)
    |> Enum.flat_map(fn {{key, label}, index} ->
      active = active_focus_idx == index
      prefix = if active, do: "> ", else: "  "
      label_color = if active, do: :cyan, else: :white
      value_color = if active, do: :green, else: :white
      value = Map.get(fields_map || %{}, key, "")

      masked_value =
        if key == "password", do: String.duplicate("*", String.length(value)), else: value

      display_value = if active, do: masked_value <> "█", else: masked_value

      [
        ExRatatui.Text.Line.new([
          ExRatatui.Text.Span.new(prefix),
          ExRatatui.Text.Span.new(label, style: %ExRatatui.Style{fg: label_color})
        ]),
        ExRatatui.Text.Line.new([
          ExRatatui.Text.Span.new("    "),
          ExRatatui.Text.Span.new(display_value, style: %ExRatatui.Style{fg: value_color})
        ])
      ]
    end)
  end

  @doc """
  Renders save and cancel action buttons with focus styling.
  """
  def render_action_buttons(save_active, cancel_active, save_label \\ "Save Connection", cancel_label \\ "Cancel") do
    ExRatatui.Text.Line.new([
      ExRatatui.Text.Span.new(
        if(save_active, do: "> [ #{save_label} ]   ", else: "  [ #{save_label} ]   "),
        style: %ExRatatui.Style{fg: if(save_active, do: :green, else: :white)}
      ),
      ExRatatui.Text.Span.new(
        if(cancel_active, do: "> [ #{cancel_label} ]", else: "  [ #{cancel_label} ]"),
        style: %ExRatatui.Style{fg: if(cancel_active, do: :red, else: :white)}
      )
    ])
  end

  @doc """
  Applies standard keyboard text editing (:paste, :backspace, :char, single character) to a string.
  Returns `{:ok, new_string}` if text changed, or `:ignore` otherwise.
  """
  def handle_text_input(key, key_data, current_val) do
    val = current_val || ""

    case key do
      :paste ->
        text = Map.get(key_data, :content, "")
        {:ok, val <> text}

      :backspace ->
        {:ok, String.slice(val, 0..-2//1)}

      :char ->
        char = Map.get(key_data, :char, "")

        if is_binary(char) and char != "" do
          {:ok, val <> char}
        else
          :ignore
        end

      ch when is_binary(ch) and byte_size(ch) == 1 ->
        {:ok, val <> ch}

      _ ->
        :ignore
    end
  end

  @doc """
  Cycles focus index forward or backward for form fields with wrap-around.
  Returns `{:ok, new_idx}` if key is navigation (:up, :down, :tab), or `:ignore` otherwise.
  """
  def cycle_focus_index(current_idx, key, is_shift, total_count)
      when is_integer(current_idx) and is_integer(total_count) and total_count > 0 do
    cond do
      key in [:down, :tab] and not is_shift ->
        {:ok, rem(current_idx + 1, total_count)}

      key == :up or (key == :tab and is_shift) ->
        {:ok, rem(current_idx - 1 + total_count, total_count)}

      true ->
        :ignore
    end
  end

  def cycle_focus_index(_current_idx, _key, _is_shift, _total_count), do: :ignore

  @doc """
  Returns the logs list, optionally filtered by regex, or a fallback message if empty.
  """
  def get_displayed_logs(model) do
    logs_len = if is_list(model.logs), do: length(model.logs), else: 0

    hd_log =
      case model.logs do
        [%{seq: seq} | _] -> seq
        [first | _] when is_map(first) -> Map.get(first, :timestamp) || Map.get(first, :message)
        [first | _] -> first
        _ -> nil
      end

    cache_key = {model.filter_regex, Map.get(model, :log_level_filter, :all), model.selected_container_id, logs_len, hd_log}

    Cache.fetch_latest(:cached_displayed_logs, cache_key, fn ->
      do_get_displayed_logs(model)
    end)
  end

  defp do_get_displayed_logs(model) do
    level_filter = Map.get(model, :log_level_filter, :all)

    level_filtered_logs =
      case level_filter do
        :info -> filter_logs_by_predicate(model.logs, fn _is_err, sev -> sev == 2 end)
        :warn -> filter_logs_by_predicate(model.logs, fn _is_err, sev -> sev == 3 end)
        :error -> filter_logs_by_predicate(model.logs, fn is_err, sev -> sev >= 4 or is_err end)
        :fatal -> filter_logs_by_predicate(model.logs, fn is_err, sev -> sev >= 5 or is_err end)
        _ -> model.logs
      end

    filtered_logs =
      if model.filter_regex != "" and not model.filter_error do
        {is_negative, query} =
          if String.starts_with?(model.filter_regex, "!") do
            {true, String.slice(model.filter_regex, 1..-1//1)}
          else
            {false, model.filter_regex}
          end

        if query == "" do
          level_filtered_logs
        else
          if String.contains?(query, ["\\", "^", "$", "*", "+", "?", "(", ")", "[", "]", "{", "}", "|"]) do
            re =
              Map.get(model, :compiled_filter_regex) ||
                case Regex.compile(query) do
                  {:ok, compiled} -> compiled
                  _ -> nil
                end

            if re do
              Enum.filter(level_filtered_logs, fn
                %{message: msg} ->
                  if is_negative, do: not Regex.match?(re, msg), else: Regex.match?(re, msg)

                line when is_binary(line) ->
                  if is_negative, do: not Regex.match?(re, line), else: Regex.match?(re, line)
              end)
            else
              level_filtered_logs
            end
          else
            Enum.filter(level_filtered_logs, fn
              %{message: msg} ->
                if is_negative, do: not String.contains?(msg, query), else: String.contains?(msg, query)

              line when is_binary(line) ->
                if is_negative, do: not String.contains?(line, query), else: String.contains?(line, query)
            end)
          end
        end
      else
        level_filtered_logs
      end

    normalized =
      case filtered_logs do
        [%{timestamp: _, stream: _, message: _} | _] = already_normalized ->
          already_normalized

        other ->
          Enum.map(other, fn
            %{timestamp: ts, stream: stream, message: msg} ->
              %{timestamp: ts, stream: stream, message: msg}

            line when is_binary(line) ->
              %{timestamp: nil, stream: :stdout, message: line}
          end)
      end

    cond do
      is_nil(model.selected_container_id) ->
        [
          %{
            timestamp: nil,
            stream: :stdout,
            message: "No container selected. Select a container in the sidebar to view logs."
          }
        ]

      normalized == [] ->
        [%{timestamp: nil, stream: :stdout, message: "No logs captured yet."}]

      true ->
        normalized
    end
  end

  @doc """
  Computes the available height for logs display based on UI mode.
  """
  def get_logs_pane_height(model) do
    inner_height = max(0, model.height - 4)

    if model.mode == :searching or model.filter_regex != "" do
      max(0, inner_height - 2)
    else
      inner_height
    end
  end

  @doc """
  Maps a connection status to a corresponding terminal UI color.
  """
  def status_color(:connected), do: :green
  def status_color(:connecting), do: :yellow
  def status_color(:disconnected), do: :red
  def status_color(:disabled), do: :dark_gray
  def status_color(_), do: :white

  @doc """
  Counts the total number of lines when wrapping lines of a given width.
  """
  def count_wrapped_lines(lines, width) do
    w = max(1, width)
    lines_len = if is_list(lines), do: length(lines), else: 0

    hd_line =
      case lines do
        [%{seq: seq} | _] -> seq
        [%{message: msg} | _] -> msg
        [first | _] -> first
        _ -> nil
      end

    cache_key = {:cached_wrapped_lines_count, lines_len, hd_line, w}

    Cache.fetch_latest(:cached_wrapped_lines_count, cache_key, fn ->
      Enum.reduce(lines, 0, fn line, acc ->
        acc + visual_line_count(line, w)
      end)
    end)
  end

  @doc """
  Calculates the wrapped lines count for a single string line.
  """
  def visual_line_count(%{message: line}, width), do: visual_line_count(line, width)

  def visual_line_count(line, width) when is_binary(line) do
    w = max(1, width)
    len = String.length(line)
    max(1, ceil(len / w))
  end

  def visual_line_count(_other, _width), do: 1



  @doc """
  Pre-wraps a list of structured spans into multiple lines of spans of a given maximum width.
  """
  def wrap_spans(spans, width) do
    Caudata.Native.wrap_spans(spans, max(1, width))
  end

  @doc """
  Copies the given text to the system clipboard using native OS commands.
  Returns `:ok` on success or `{:error, reason}` on failure.
  """
  def copy_to_clipboard(text) when is_binary(text) do
    case :os.type() do
      {:unix, :darwin} ->
        try_port("pbcopy", [], text)

      {:unix, :linux} ->
        cond do
          System.find_executable("xclip") ->
            try_port("xclip", ["-selection", "clipboard"], text)

          System.find_executable("xsel") ->
            try_port("xsel", ["--clipboard", "--input"], text)

          System.find_executable("wl-copy") ->
            try_port("wl-copy", [], text)

          true ->
            {:error, :no_clipboard_tool}
        end

      {:win32, _} ->
        try_port("clip", [], text)

      _ ->
        {:error, :unsupported_os}
    end
  end

  @doc """
  Reads the system clipboard and returns the text, or an error.
  """
  def paste_from_clipboard do
    if Application.get_env(:caudata, :env) == :test do
      {:ok, "mocked_paste_data"}
    else
      case :os.type() do
        {:unix, :darwin} ->
          run_command("pbpaste", [])

        {:unix, :linux} ->
          cond do
            System.find_executable("xclip") ->
              run_command("xclip", ["-selection", "clipboard", "-o"])

            System.find_executable("xsel") ->
              run_command("xsel", ["--clipboard", "--output"])

            System.find_executable("wl-paste") ->
              run_command("wl-paste", [])

            true ->
              {:error, :no_clipboard_tool}
          end

        {:win32, _} ->
          run_command("powershell.exe", ["-Command", "Get-Clipboard"])

        _ ->
          {:error, :unsupported_os}
      end
    end
  end

  @doc """
  Helper to detect if a key press is the paste hotkey.
  Supports:
  - "P" uppercase character (user preference for 1-character hotkey)
  - Ctrl+V combination
  - Explicit paste key/atom
  """
  def paste_key?(key_data) do
    key = Map.get(key_data, :key)

    key == :paste or
      (key == :char and Map.get(key_data, :char) == "P") or
      (key == :char and Map.get(key_data, :char) in ["v", "V"] and ctrl_pressed?(key_data))
  end

  @doc """
  Helper to detect if a key press is the Ctrl+C quit hotkey.
  """
  def ctrl_c_key?(key_data) do
    key = Map.get(key_data, :key)
    char = Map.get(key_data, :char)

    ctrl_pressed?(key_data) and
      ((key == :char and char in ["c", "C"]) or key in ["c", "C", :c])
  end

  @doc """
  Helper to check if Ctrl key or modifier is present in key_data.
  """
  def ctrl_pressed?(key_data) do
    modifiers = Map.get(key_data, :modifiers, []) || []

    "ctrl" in modifiers or "Ctrl" in modifiers or :ctrl in modifiers or
      Map.get(key_data, :ctrl, false) == true
  end

  defp run_command(cmd, args) do
    case System.find_executable(cmd) do
      nil ->
        {:error, :command_not_found}

      _path ->
        case System.cmd(cmd, args) do
          {output, 0} -> {:ok, String.trim_trailing(output)}
          _ -> {:error, :command_failed}
        end
    end
  rescue
    _ -> {:error, :execution_failed}
  end

  defp try_port(cmd, args, input) do
    case System.find_executable(cmd) do
      nil ->
        {:error, :command_not_found}

      path ->
        try do
          port = Port.open({:spawn_executable, path}, [:binary, {:args, args}])
          Port.command(port, input)
          Port.close(port)
          :ok
        rescue
          _ ->
            {:error, :port_failed}
        end
    end
  end

  @doc """
  Starts a server worker for a profile if one is not already running.
  """
  def start_worker_if_needed(profile) do
    if Application.get_env(:caudata, :env) == :test do
      :ok
    else
      if Map.get(profile, :enabled, true) do
        case Caudata.ServerSupervisor.lookup_worker(profile.id) do
          {:error, :not_found} ->
            _ = Caudata.ServerSupervisor.start_worker(profile)
            :ok

          _ ->
            :ok
        end
      else
        :ok
      end
    end
  end

  @doc """
  Finds the index in `old_logs` where the overlap with `new_logs` starts.
  Specifically, it finds the smallest index `i` such that the suffix of `old_logs`
  starting at `i` is a prefix of `new_logs`.
  Returns `nil` if there is no overlap or if list is empty.
  """
  def find_overlap_index([], _new_logs), do: nil
  def find_overlap_index(_old_logs, []), do: nil

  def find_overlap_index(old_logs, new_logs) do
    if old_logs == new_logs do
      0
    else
      first_new = hd(new_logs)

      case Enum.find_index(old_logs, &(&1 == first_new)) do
        nil ->
          nil

        idx ->
          remaining_old = Enum.drop(old_logs, idx)

          if List.starts_with?(new_logs, remaining_old) do
            idx
          else
            old_logs
            |> Stream.with_index()
            |> Stream.drop(idx + 1)
            |> Stream.filter(fn {item, _i} -> item == first_new end)
            |> Enum.find_value(fn {_item, i} ->
              rem_old = Enum.drop(old_logs, i)
              if List.starts_with?(new_logs, rem_old), do: i, else: nil
            end)
          end
      end
    end
  end

  @doc """
  Gets the currently selected container struct based on profile and container IDs in model state.
  """
  def get_selected_container(state) do
    profiles = Map.get(state, :profiles, [])
    selected_profile_id = Map.get(state, :selected_profile_id)
    selected_profile = Enum.find(profiles, &(&1.id == selected_profile_id))

    if selected_profile do
      containers = Map.get(Map.get(state, :containers, %{}), selected_profile.id, [])
      selected_container_id = Map.get(state, :selected_container_id)

      Enum.find(
        containers,
        &(to_string(&1.id) == to_string(selected_container_id))
      )
    end
  end

  @doc """
  Checks if the currently selected container is a Docker container.
  """
  def selected_container_is_docker?(state) do
    container = get_selected_container(state)
    container != nil and docker_container?(container)
  end

  @doc """
  Computes the inner width of the logs pane based on fullscreen state.
  """
  def get_logs_inner_width(model) do
    width =
      if Map.get(model, :logs_full_screen, false) do
        max(0, model.width - 2)
      else
        max(0, model.width - 40)
      end

    prefix_width = if Map.get(model, :show_timestamps, false), do: 22, else: 2

    max(1, width - prefix_width)
  end

  @doc """
  Gets the list of enabled containers and services for a profile.
  """
  def get_enabled_containers(profile, containers) do
    if is_nil(profile) or is_nil(containers) do
      []
    else
      disabled_containers = Enum.map(profile.disabled_containers || [], &to_string/1)
      enabled_services = Map.get(profile, :enabled_services) || []

      Enum.filter(containers, fn c ->
        id_str = to_string(c.id)

        if service_container?(c) do
          id_str in enabled_services or to_string(c.name) in enabled_services
        else
          id_str not in disabled_containers and
            to_string(c.name) not in disabled_containers
        end
      end)
    end
  end

  @doc """
  Computes the selection range for selecting/visual mode.
  """
  def get_selection_range(%{mode: :selecting, visual_anchor: anchor, visual_cursor: cursor})
      when is_integer(anchor) and is_integer(cursor) do
    if anchor <= cursor, do: anchor..cursor, else: cursor..anchor
  end

  def get_selection_range(_state), do: nil

  defp filter_logs_by_predicate(logs, pred) do
    Enum.filter(logs, fn
      %{is_err: is_err, severity: sev} when not is_nil(is_err) and not is_nil(sev) ->
        pred.(is_err, sev)

      %{message: msg} ->
        {_spans, is_err, sev} = Caudata.UI.LogFormatter.format_line_with_meta(msg)
        pred.(is_err, sev)

      line when is_binary(line) ->
        {_spans, is_err, sev} = Caudata.UI.LogFormatter.format_line_with_meta(line)
        pred.(is_err, sev)

      _ ->
        false
    end)
  end
end
