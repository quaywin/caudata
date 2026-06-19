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
  Returns the logs list, optionally filtered by regex, or a fallback message if empty.
  """
  def get_displayed_logs(model) do
    filtered_logs =
      if model.filter_regex != "" and not model.filter_error do
        case Regex.compile(model.filter_regex) do
          {:ok, re} ->
            Enum.filter(model.logs, fn
              %{message: msg} -> Regex.match?(re, msg)
              line when is_binary(line) -> Regex.match?(re, line)
            end)

          _ ->
            model.logs
        end
      else
        model.logs
      end

    normalized =
      Enum.map(filtered_logs, fn
        %{timestamp: ts, stream: stream, message: msg} ->
          %{timestamp: ts, stream: stream, message: msg}

        line when is_binary(line) ->
          %{timestamp: nil, stream: :stdout, message: line}
      end)

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
    div(max(0, len - 1), w) + 1
  end

  @doc """
  Pre-wraps a single string line into multiple lines of a given maximum width.
  """
  def wrap_text(line, width) do
    w = max(1, width)
    do_wrap_text(line, w, [])
  end

  defp do_wrap_text("", _width, []), do: [""]
  defp do_wrap_text("", _width, acc), do: Enum.reverse(acc)

  defp do_wrap_text(line, width, acc) do
    {chunk, rest} = String.split_at(line, width)
    do_wrap_text(rest, width, [chunk | acc])
  end

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
  def find_overlap_index(old_logs, new_logs) do
    do_find_overlap_index(old_logs, new_logs, 0)
  end

  defp do_find_overlap_index([], _new_logs, _i), do: nil

  defp do_find_overlap_index(old_logs, new_logs, i) do
    if List.starts_with?(new_logs, old_logs) do
      i
    else
      do_find_overlap_index(tl(old_logs), new_logs, i + 1)
    end
  end

  @doc """
  Calculates the scroll adjustment when the logs snapshot shifts.
  Computes how many wrapped lines of `old_logs` were dropped from the beginning
  in `new_logs`.
  """
  def calculate_scroll_shift(old_logs, new_logs, inner_width) do
    case find_overlap_index(old_logs, new_logs) do
      nil ->
        0

      idx ->
        old_logs
        |> Enum.take(idx)
        |> count_wrapped_lines(inner_width)
    end
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
        is_service = image in ["systemd", "launchd"] or
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
