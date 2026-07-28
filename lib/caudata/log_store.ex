defmodule Caudata.LogStore do
  use GenServer
  require Logger
  alias Caudata.LogSanitizer

  @default_capacity 1000

  # Client API

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Appends a list of raw log lines to a source's buffer.
  Each line is sanitized before insertion.
  """
  def append_logs(server \\ __MODULE__, source_id, lines) when is_list(lines) do
    GenServer.cast(server, {:append_logs, source_id, lines})
  end

  @doc """
  Gets a list of all lines for a source in chronological order.
  """
  def get_snapshot(server \\ __MODULE__, source_id, limit \\ @default_capacity) do
    GenServer.call(server, {:get_snapshot, source_id, limit})
  end

  @doc """
  Gets buffer statistics (size and drop count) for a source.
  """
  def get_stats(server \\ __MODULE__, source_id) do
    GenServer.call(server, {:get_stats, source_id})
  end

  @doc """
  Clears the log buffer and drop count for a source.
  """
  def clear_logs(server \\ __MODULE__, source_id) do
    GenServer.call(server, {:clear_logs, source_id})
  end

  @doc """
  Sets the capacity of the log store.
  """
  def set_capacity(server \\ __MODULE__, new_capacity) do
    GenServer.call(server, {:set_capacity, new_capacity})
  end

  @doc """
  Deletes a log stream asynchronously.
  """
  def delete_stream(server \\ __MODULE__, source_id) do
    GenServer.cast(server, {:delete_stream, source_id})
  end

  # GenServer Callbacks

  @impl true
  def init(opts) do
    capacity = Keyword.get(opts, :capacity) || @default_capacity

    # State: %{sources: %{source_id => %{queue: :queue.t(), size: integer(), drop_count: integer()}}, capacity: integer()}
    {:ok, %{sources: %{}, capacity: capacity}}
  end

  @impl true
  def handle_cast({:append_logs, source_id, lines}, state) do
    sanitized_lines =
      Enum.map(lines, fn
        %{timestamp: ts, stream: stream, message: msg} ->
          %{timestamp: ts, stream: stream, message: LogSanitizer.sanitize(msg)}

        {stream, line} ->
          {ts, msg} = parse_docker_log(line)
          %{timestamp: ts, stream: stream, message: LogSanitizer.sanitize(msg)}

        line when is_binary(line) ->
          {ts, msg} = parse_docker_log(line)
          %{timestamp: ts, stream: :stdout, message: LogSanitizer.sanitize(msg)}
      end)

    # Retrieve or initialize the source buffer state
    source_state =
      Map.get(state.sources, source_id, %{
        queue: :queue.new(),
        size: 0,
        drop_count: 0
      })

    # Add each line to the queue
    {new_queue, new_size, new_drops} =
      Enum.reduce(
        sanitized_lines,
        {source_state.queue, source_state.size, source_state.drop_count},
        fn line, {q, sz, dr} ->
          q = :queue.in(line, q)
          sz = sz + 1

          if sz > state.capacity do
            # Drop the oldest item
            case :queue.out(q) do
              {{:value, _}, remaining_q} ->
                {remaining_q, sz - 1, dr + 1}

              {:empty, empty_q} ->
                {empty_q, 0, dr}
            end
          else
            {q, sz, dr}
          end
        end
      )

    new_source_state = %{
      queue: new_queue,
      size: new_size,
      drop_count: new_drops
    }

    new_sources = Map.put(state.sources, source_id, new_source_state)

    # Broadcast notification to PubSub
    Phoenix.PubSub.broadcast(
      Caudata.PubSub,
      "logs:#{source_id}",
      {:logs_updated, source_id, %{size: new_size, drop_count: new_drops}}
    )

    {:noreply, %{state | sources: new_sources}}
  end

  @impl true
  def handle_cast({:delete_stream, source_id}, state) do
    new_sources = Map.delete(state.sources, source_id)

    Phoenix.PubSub.broadcast(
      Caudata.PubSub,
      "logs:#{source_id}",
      {:logs_cleared, source_id}
    )

    {:noreply, %{state | sources: new_sources}}
  end

  @impl true
  def handle_call({:get_snapshot, source_id, limit}, _from, state) do
    case Map.get(state.sources, source_id) do
      nil ->
        {:reply, [], state}

      source_state ->
        lines = :queue.to_list(source_state.queue)

        sorted_lines =
          Enum.sort_by(lines, fn
            %{timestamp: ts} when is_binary(ts) -> ts
            _ -> ""
          end)

        tail_lines = Enum.take(sorted_lines, -limit)
        {:reply, tail_lines, state}
    end
  end

  @impl true
  def handle_call({:get_stats, source_id}, _from, state) do
    stats =
      case Map.get(state.sources, source_id) do
        nil ->
          %{size: 0, drop_count: 0}

        source_state ->
          %{size: source_state.size, drop_count: source_state.drop_count}
      end

    {:reply, stats, state}
  end

  @impl true
  def handle_call({:set_capacity, new_capacity}, _from, state) do
    {:reply, :ok, %{state | capacity: max(state.capacity, new_capacity)}}
  end

  @impl true
  def handle_call({:clear_logs, source_id}, _from, state) do
    new_sources = Map.delete(state.sources, source_id)

    Phoenix.PubSub.broadcast(
      Caudata.PubSub,
      "logs:#{source_id}",
      {:logs_cleared, source_id}
    )

    {:reply, :ok, %{state | sources: new_sources}}
  end

  defp parse_docker_log(line) do
    case String.split(line, " ", parts: 2) do
      [timestamp, msg] ->
        if String.match?(timestamp, ~r/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}/) do
          {timestamp, msg}
        else
          {nil, line}
        end

      _ ->
        {nil, line}
    end
  end
end
