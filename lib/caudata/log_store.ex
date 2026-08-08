defmodule Caudata.LogStore do
  use GenServer
  require Logger
  alias Caudata.LogSanitizer

  @default_capacity 10000

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
  Reads directly from ETS table for zero-latency non-blocking access.
  """
  def get_snapshot(server \\ __MODULE__, source_id, limit \\ @default_capacity) do
    tab = get_table_name(server)

    case try_ets_lookup(tab, {:snapshot, source_id}) do
      {:ok, lines} ->
        Enum.take(lines, -limit)

      :error ->
        GenServer.call(server, {:get_snapshot, source_id, limit})
    end
  end

  defp try_ets_lookup(tab, key) when is_atom(tab) do
    case :ets.info(tab) do
      :undefined -> :error
      _ ->
        case :ets.lookup(tab, key) do
          [{^key, val}] -> {:ok, val}
          [] -> {:ok, []}
        end
    end
  end

  defp try_ets_lookup(tab, key) when is_pid(tab) do
    case GenServer.call(tab, :get_table_name) do
      table_name when is_atom(table_name) or is_reference(table_name) ->
        case :ets.lookup(table_name, key) do
          [{^key, val}] -> {:ok, val}
          [] -> {:ok, []}
        end

      _ ->
        :error
    end
  rescue
    _ -> :error
  end

  defp get_table_name(server) when is_atom(server), do: server
  defp get_table_name(server) when is_pid(server), do: server

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
    name = Keyword.get(opts, :name, __MODULE__)
    capacity = Keyword.get(opts, :capacity) || @default_capacity

    tab =
      case :ets.info(name) do
        :undefined ->
          :ets.new(name, [:named_table, :public, :set, {:read_concurrency, true}])

        _ ->
          name
      end

    {:ok, %{table: tab, sources: %{}, capacity: capacity}}
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
        drop_count: 0,
        next_seq: 0,
        last_ts: nil
      })

    # Drop leading duplicate line if it matches the tail of the existing queue
    last_item_in_queue =
      case :queue.peek_r(source_state.queue) do
        {:value, item} -> item
        :empty -> nil
      end

    sanitized_lines =
      case {last_item_in_queue, sanitized_lines} do
        {%{timestamp: ts1, stream: st1, message: msg1},
         [%{timestamp: ts2, stream: st2, message: msg2} | rest]}
        when not is_nil(ts1) and ts1 != "" and ts1 == ts2 and st1 == st2 and msg1 == msg2 ->
          rest

        _ ->
          sanitized_lines
      end

    next_seq = Map.get(source_state, :next_seq, 0)
    last_ts = Map.get(source_state, :last_ts, nil)

    # Carry an `ordered?` flag through the reduce: it stays true while the
    # effective timestamps are non-decreasing. The common case (a monotonic
    # log stream) leaves it true, which lets us skip the O(n log n) snapshot
    # re-sort below. Only an out-of-order batch (e.g. interleaved docker
    # stdout/stderr streams arriving with earlier timestamps) flips it false.
    {meta_lines, final_seq, final_last_ts, ordered?} =
      Enum.reduce(
        sanitized_lines,
        {[], next_seq, last_ts, true},
        fn line, {acc, seq, cur_last_ts, ordered?} ->
          line_ts = Map.get(line, :timestamp)
          effective_ts = if is_binary(line_ts) and line_ts != "", do: line_ts, else: cur_last_ts
          sort_ts = effective_ts || ""

          still_ordered? =
            ordered? and
              (cur_last_ts in [nil, ""] or sort_ts in ["", nil] or sort_ts >= cur_last_ts)

          item = Map.merge(line, %{seq: seq, sort_ts: sort_ts})
          {[item | acc], seq + 1, effective_ts, still_ordered?}
        end
      )

    sanitized_with_meta = Enum.reverse(meta_lines)

    # Add each line to the queue
    {new_queue, new_size, new_drops} =
      Enum.reduce(
        sanitized_with_meta,
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
      drop_count: new_drops,
      next_seq: final_seq,
      last_ts: final_last_ts
    }

    new_sources = Map.put(state.sources, source_id, new_source_state)

    # Update ETS snapshot table for zero-latency direct reads.
    # The queue is FIFO by `seq`, so when this batch arrived in order the list
    # is already chronologically sorted and we skip the expensive re-sort.
    # Only out-of-order batches (ordered? == false) pay the O(n log n) sort.
    snapshot_lines =
      if ordered? do
        new_queue
        |> :queue.to_list()
        |> Enum.map(fn item -> Map.drop(item, [:seq, :sort_ts]) end)
      else
        new_queue
        |> :queue.to_list()
        |> Enum.sort_by(fn line ->
          ts = Map.get(line, :sort_ts) || Map.get(line, :timestamp) || ""
          seq = Map.get(line, :seq, 0)
          {ts, seq}
        end)
        |> Enum.map(fn item -> Map.drop(item, [:seq, :sort_ts]) end)
      end

    if Map.has_key?(state, :table) do
      :ets.insert(state.table, {{:snapshot, source_id}, snapshot_lines})
    end

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

    if Map.has_key?(state, :table) do
      :ets.delete(state.table, {:snapshot, source_id})
    end

    Phoenix.PubSub.broadcast(
      Caudata.PubSub,
      "logs:#{source_id}",
      {:logs_cleared, source_id}
    )

    {:noreply, %{state | sources: new_sources}}
  end



  @impl true
  def handle_call(:get_table_name, _from, state) do
    {:reply, Map.get(state, :table, state), state}
  end

  @impl true
  def handle_call({:get_snapshot, source_id, limit}, _from, state) do
    case Map.get(state.sources, source_id) do
      nil ->
        {:reply, [], state}

      source_state ->
        lines = :queue.to_list(source_state.queue)

        sorted_lines =
          Enum.sort_by(lines, fn line ->
            ts = Map.get(line, :sort_ts) || Map.get(line, :timestamp) || ""
            seq = Map.get(line, :seq, 0)
            {ts, seq}
          end)

        tail_lines =
          sorted_lines
          |> Enum.take(-limit)
          |> Enum.map(fn item -> Map.drop(item, [:seq, :sort_ts]) end)

        {:reply, tail_lines, state}
    end
  end

  @impl true
  def handle_call({:get_stats, source_id}, _from, state) do
    stats =
      case Map.get(state.sources, source_id) do
        nil ->
          %{size: 0, drop_count: 0, last_ts: nil}

        source_state ->
          %{
            size: source_state.size,
            drop_count: source_state.drop_count,
            last_ts: source_state.last_ts
          }
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
