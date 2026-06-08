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
end
