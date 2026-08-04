defmodule Caudata.UI.ViewHelper do
  @moduledoc """
  Shared helper functions for calculations and state lookup in the UI layer.
  """
  alias ExRatatui.Layout.Rect
  alias ExRatatui.Text.Span

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
  Checks if a container struct represents a Docker container vs a custom file or system service.
  """
  def docker_container?(container) do
    case container do
      %{image: image, id: id} ->
        image not in ["file", "systemd", "launchd"] and
          not String.starts_with?(to_string(id), "file:") and
          not String.starts_with?(to_string(id), "systemd:") and
          not String.starts_with?(to_string(id), "launchd:")

      _ ->
        false
    end
  end

  @doc """
  Returns the logs list, optionally filtered by regex, or a fallback message if empty.
  """
  def get_displayed_logs(model) do
    logs_len = if is_list(model.logs), do: length(model.logs), else: 0
    cache_key = {model.filter_regex, model.selected_container_id, logs_len}

    case Map.get(model, :cached_displayed_logs) do
      {^cache_key, cached_result} ->
        cached_result

      _ ->
        do_get_displayed_logs(model)
    end
  end

  defp do_get_displayed_logs(model) do
    filtered_logs =
      if model.filter_regex != "" and not model.filter_error do
        query = model.filter_regex

        if String.contains?(query, ["\\", "^", "$", "*", "+", "?", "(", ")", "[", "]", "{", "}", "|"]) do
          re =
            Map.get(model, :compiled_filter_regex) ||
              case Regex.compile(query) do
                {:ok, compiled} -> compiled
                _ -> nil
              end

          if re do
            Enum.filter(model.logs, fn
              %{message: msg} -> Regex.match?(re, msg)
              line when is_binary(line) -> Regex.match?(re, line)
            end)
          else
            model.logs
          end
        else
          Enum.filter(model.logs, fn
            %{message: msg} -> String.contains?(msg, query)
            line when is_binary(line) -> String.contains?(line, query)
          end)
        end
      else
        model.logs
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
    Enum.reduce(lines, 0, fn line, acc ->
      acc + visual_line_count(line, width)
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
    w = max(1, width)
    do_wrap_spans(spans, w, w, [], [])
  end

  defp do_wrap_spans([], _max_w, _rem_w, current_line, acc) do
    case current_line do
      [] -> Enum.reverse(acc)
      _ -> Enum.reverse([Enum.reverse(current_line) | acc])
    end
  end

  defp do_wrap_spans([%Span{content: ""} = span | rest_spans], max_w, rem_w, current_line, acc) do
    do_wrap_spans(rest_spans, max_w, rem_w, [span | current_line], acc)
  end

  defp do_wrap_spans([span | rest_spans], max_w, rem_w, current_line, acc) do
    len = String.length(span.content)

    cond do
      len <= rem_w ->
        do_wrap_spans(rest_spans, max_w, rem_w - len, [span | current_line], acc)

      true ->
        {chunk_str, rest_str} = String.split_at(span.content, rem_w)
        chunk_span = %{span | content: chunk_str}
        rest_span = %{span | content: rest_str}

        new_line = Enum.reverse([chunk_span | current_line])
        do_wrap_spans([rest_span | rest_spans], max_w, max_w, [], [new_line | acc])
    end
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

      old_logs
      |> Stream.with_index()
      |> Stream.filter(fn {item, _idx} -> item == first_new end)
      |> Enum.find_value(fn {_item, idx} ->
        remaining_old = Enum.drop(old_logs, idx)

        if List.starts_with?(new_logs, remaining_old) do
          idx
        else
          nil
        end
      end)
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
        image = Map.get(c, :image)

        is_service =
          image in ["systemd", "launchd"] or
            String.starts_with?(id_str, "systemd:") or
            String.starts_with?(id_str, "launchd:")

        if is_service do
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
end
