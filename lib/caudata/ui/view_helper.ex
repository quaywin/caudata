defmodule Caudata.UI.ViewHelper do
  @moduledoc """
  Shared helper functions for calculations and state lookup in the UI layer.
  """
  alias ExRatatui.Layout.Rect

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
            Enum.filter(model.logs, &Regex.match?(re, &1))

          _ ->
            model.logs
        end
      else
        model.logs
      end

    cond do
      is_nil(model.selected_container_id) ->
        ["No container selected. Select a container in the sidebar to view logs."]

      filtered_logs == [] ->
        ["No logs captured yet."]

      true ->
        filtered_logs
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
  def visual_line_count(line, width) do
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
    if Map.get(model, :logs_full_screen, false) do
      max(0, model.width - 2)
    else
      max(0, model.width - 40)
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
