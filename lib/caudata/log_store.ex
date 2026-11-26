defmodule Caudata.LogStore do
  use GenServer
  require Logger
  alias Caudata.LogSanitizer

  @default_capacity 10_000

  # Client API

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Appends a list of raw log lines to a source's buffer.
  Each line is parsed and sanitized in the caller's process before enqueueing to the store.
  """
  def append_logs(server \\ __MODULE__, source_id, lines) when is_list(lines) do
    prepared = sanitize_lines(lines)
    GenServer.cast(server, {:append_prepared_logs, source_id, prepared})
  end

  @doc """
  Appends a list of already-parsed and sanitized log entries (`%{timestamp, stream, message}`)
  to a source's buffer. Used by `ContainerWorker` to keep sanitization off the store GenServer.
  """
  def append_prepared_logs(server \\ __MODULE__, source_id, entries) when is_list(entries) do
    GenServer.cast(server, {:append_prepared_logs, source_id, entries})
  end

  @doc """
  Prepends a list of historical raw log lines to a source's buffer.
  Used for Phase 2 background log backfill. Each line is parsed and sanitized before insertion.
  """
  def prepend_logs(server \\ __MODULE__, source_id, lines) when is_list(lines) do
    prepared = sanitize_lines(lines)
    GenServer.cast(server, {:prepend_prepared_logs, source_id, prepared})
  end

  @doc """
  Prepends a list of already-parsed and sanitized historical log entries to a source's buffer.
  """
  def prepend_prepared_logs(server \\ __MODULE__, source_id, entries) when is_list(entries) do
    GenServer.cast(server, {:prepend_prepared_logs, source_id, entries})
  end

  @doc """
  Gets a list of up to `limit` lines for a source in chronological order.
  Reads directly from the `:ordered_set` ETS table for zero-latency non-blocking access.
  """
  def get_snapshot(server \\ __MODULE__, source_id, limit \\ @default_capacity) do
    {lines, _meta} = get_snapshot_window(server, source_id, limit)
    lines
  end

  @doc """
  Gets `{lines, meta}` for up to `limit` trailing lines of `source_id` directly from ETS.
  `meta` includes `:first_seq`, `:last_seq`, `:size`, and `:drop_count` for O(1) UI diffing.
  """
  def get_snapshot_window(server \\ __MODULE__, source_id, limit \\ @default_capacity) do
    tab = resolve_ets_table(server)

    case try_ets_window(tab, source_id, limit) do
      {:ok, lines, meta} -> {lines, meta}
      :error -> GenServer.call(server, {:get_snapshot_window, source_id, limit})
    end
  end

  @doc """
  Gets buffer statistics (size, drop_count, first_ts, last_ts) for a source.
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

  # ETS Direct Read Helpers

  defp resolve_ets_table(server) when is_atom(server), do: server

  defp resolve_ets_table(server) when is_pid(server) do
    case Process.info(server, :registered_name) do
      {:registered_name, name} when is_atom(name) -> name
      _ -> server
    end
  end

  defp try_ets_window(tab, source_id, limit) when is_atom(tab) do
    case :ets.info(tab) do
      :undefined ->
        :error

      _ ->
        read_ets_window(tab, source_id, limit)
    end
  end

  defp try_ets_window(tab, source_id, limit) when is_pid(tab) do
    case GenServer.call(tab, :get_table_name) do
      table_name when is_atom(table_name) or is_reference(table_name) ->
        read_ets_window(table_name, source_id, limit)

      _ ->
        :error
    end
  rescue
    _ -> :error
  end

  defp read_ets_window(tab, source_id, limit) do
    case :ets.lookup(tab, {:meta, source_id}) do
      [] ->
        {:ok, [], %{first_seq: nil, last_seq: nil, gen: nil, size: 0, drop_count: 0}}

      [{_, %{size: 0} = meta}] ->
        {:ok, [],
         %{
           first_seq: nil,
           last_seq: nil,
           gen: Map.get(meta, :gen),
           size: 0,
           drop_count: meta.drop_count
         }}

      [{_, meta}] when limit <= 0 ->
        {:ok, [],
         %{
           first_seq: nil,
           last_seq: nil,
           gen: Map.get(meta, :gen),
           size: meta.size,
           drop_count: meta.drop_count
         }}

      [{_, meta}] ->
        count = min(limit, meta.size)
        end_seq = meta.max_seq
        start_seq = max(meta.min_seq, end_seq - count + 1)
        lines = read_ets_range(tab, source_id, start_seq, end_seq, meta.size)

        window_meta = %{
          first_seq: if(lines == [], do: nil, else: start_seq),
          last_seq: if(lines == [], do: nil, else: end_seq),
          gen: Map.get(meta, :gen),
          size: meta.size,
          drop_count: meta.drop_count
        }

        {:ok, lines, window_meta}
    end
  end

  defp read_ets_range(_tab, _source_id, start_seq, end_seq, _total_size)
       when start_seq > end_seq do
    []
  end

  defp read_ets_range(tab, source_id, start_seq, end_seq, total_size) do
    count = end_seq - start_seq + 1

    # When reading more than half the stream, a single C-level select scan is faster than
    # N separate BIF lookups; for small tail slices (100-1000 out of 10k), direct key lookup
    # touches strictly `count` entries without scanning older rows.
    if count > div(total_size, 2) do
      match_spec = [
        {
          {{{:entry, source_id}, :"$1"}, :"$2"},
          [{:andalso, {:>=, :"$1", start_seq}, {:"=<", :"$1", end_seq}}],
          [:"$2"]
        }
      ]

      :ets.select(tab, match_spec)
    else
      collect_range_reverse(tab, source_id, end_seq, start_seq, [])
    end
  end

  defp collect_range_reverse(_tab, _source_id, seq, start_seq, acc) when seq < start_seq, do: acc

  defp collect_range_reverse(tab, source_id, seq, start_seq, acc) do
    next_acc =
      case :ets.lookup(tab, {{:entry, source_id}, seq}) do
        [{_, entry}] -> [entry | acc]
        [] -> acc
      end

    collect_range_reverse(tab, source_id, seq - 1, start_seq, next_acc)
  end

  # GenServer Callbacks

  @impl true
  def init(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    capacity = Keyword.get(opts, :capacity) || @default_capacity

    tab =
      case :ets.info(name) do
        :undefined ->
          :ets.new(name, [:named_table, :public, :ordered_set, {:read_concurrency, true}])

        _ ->
          name
      end

    {:ok, %{table: tab, sources: %{}, capacity: capacity}}
  end

  @impl true
  def handle_cast({:append_prepared_logs, source_id, lines}, state) do
    source_state = get_or_init_source(state.sources, source_id)
    lines = dedup_leading_line(source_state.tail_item, lines)

    {final_last_ts, ordered?, min_batch_ts} = check_batch_order(lines, source_state.last_ts)

    new_source_state =
      if lines == [] do
        source_state
      else
        if ordered? do
          append_ordered_batch(
            state.table,
            source_id,
            source_state,
            lines,
            final_last_ts,
            state.capacity
          )
        else
          append_out_of_order_batch(
            state.table,
            source_id,
            source_state,
            lines,
            min_batch_ts,
            state.capacity
          )
        end
      end

    new_sources = Map.put(state.sources, source_id, new_source_state)

    Phoenix.PubSub.broadcast(
      Caudata.PubSub,
      "logs:#{source_id}",
      {:logs_updated, source_id,
       %{size: new_source_state.size, drop_count: new_source_state.drop_count}}
    )

    {:noreply, %{state | sources: new_sources}}
  end

  @impl true
  def handle_cast({:prepend_prepared_logs, source_id, lines}, state) do
    source_state = get_or_init_source(state.sources, source_id)

    existing_head_sample =
      if source_state.size > 0 do
        sample_end = min(source_state.max_seq, source_state.min_seq + 99)

        read_ets_range(
          state.table,
          source_id,
          source_state.min_seq,
          sample_end,
          source_state.size
        )
      else
        []
      end

    deduped_backfill = strip_boundary_overlap(lines, existing_head_sample)

    available = max(0, state.capacity - source_state.size)
    backfill_count = length(deduped_backfill)

    {kept_backfill, new_drop_count} =
      cond do
        available == 0 ->
          {[], source_state.drop_count + backfill_count}

        backfill_count > available ->
          {Enum.take(deduped_backfill, -available),
           source_state.drop_count + (backfill_count - available)}

        true ->
          {deduped_backfill, source_state.drop_count}
      end

    kept_count = length(kept_backfill)

    new_source_state =
      if kept_count > 0 do
        base_min = if source_state.size == 0, do: 0, else: source_state.min_seq
        new_min_seq = base_min - kept_count
        new_max_seq = if source_state.size == 0, do: -1, else: source_state.max_seq

        entries =
          kept_backfill
          |> Enum.with_index(new_min_seq)
          |> Enum.map(fn {entry, seq} -> {{{:entry, source_id}, seq}, entry} end)

        :ets.insert(state.table, entries)

        new_size = source_state.size + kept_count

        new_first_ts =
          case hd(kept_backfill) do
            %{timestamp: ts} when is_binary(ts) and ts != "" -> ts
            _ -> source_state.first_ts
          end

        new_last_ts =
          if source_state.size == 0 do
            last_non_empty_ts(kept_backfill, nil)
          else
            source_state.last_ts
          end

        new_tail_item =
          if source_state.size == 0 do
            List.last(kept_backfill)
          else
            source_state.tail_item
          end

        updated = %{
          gen: source_state.gen,
          min_seq: new_min_seq,
          max_seq: new_max_seq,
          size: new_size,
          drop_count: new_drop_count,
          first_ts: new_first_ts,
          last_ts: new_last_ts,
          tail_item: new_tail_item
        }

        write_ets_meta(state.table, source_id, updated)
        updated
      else
        updated = %{source_state | drop_count: new_drop_count}
        write_ets_meta(state.table, source_id, updated)
        updated
      end

    new_sources = Map.put(state.sources, source_id, new_source_state)

    Phoenix.PubSub.broadcast(
      Caudata.PubSub,
      "logs:#{source_id}",
      {:logs_updated, source_id,
       %{size: new_source_state.size, drop_count: new_source_state.drop_count}}
    )

    {:noreply, %{state | sources: new_sources}}
  end

  @impl true
  def handle_cast({:delete_stream, source_id}, state) do
    new_state = do_delete_stream(state, source_id)
    {:noreply, new_state}
  end

  @impl true
  def handle_call(:get_table_name, _from, state) do
    {:reply, state.table, state}
  end

  @impl true
  def handle_call({:get_snapshot, source_id, limit}, _from, state) do
    {:ok, lines, _meta} = read_ets_window(state.table, source_id, limit)
    {:reply, lines, state}
  end

  @impl true
  def handle_call({:get_snapshot_window, source_id, limit}, _from, state) do
    {:ok, lines, meta} = read_ets_window(state.table, source_id, limit)
    {:reply, {lines, meta}, state}
  end

  @impl true
  def handle_call({:get_stats, source_id}, _from, state) do
    stats =
      case Map.get(state.sources, source_id) do
        nil ->
          %{size: 0, drop_count: 0, last_ts: nil, first_ts: nil}

        source_state ->
          %{
            size: source_state.size,
            drop_count: source_state.drop_count,
            last_ts: source_state.last_ts,
            first_ts: source_state.first_ts
          }
      end

    {:reply, stats, state}
  end

  @impl true
  def handle_call({:set_capacity, new_capacity}, _from, state) when is_integer(new_capacity) do
    effective_capacity = max(1, new_capacity)

    new_sources =
      if effective_capacity < state.capacity do
        Map.new(state.sources, fn {source_id, source_state} ->
          if source_state.size > effective_capacity do
            excess = source_state.size - effective_capacity
            new_min_seq = source_state.min_seq + excess

            new_first_ts =
              read_entry_ts(state.table, source_id, new_min_seq) || source_state.first_ts

            updated = %{
              source_state
              | min_seq: new_min_seq,
                size: effective_capacity,
                drop_count: source_state.drop_count + excess,
                first_ts: new_first_ts
            }

            write_ets_meta(state.table, source_id, updated)
            delete_ets_range(state.table, source_id, source_state.min_seq, new_min_seq - 1)
            {source_id, updated}
          else
            {source_id, source_state}
          end
        end)
      else
        state.sources
      end

    {:reply, :ok, %{state | capacity: effective_capacity, sources: new_sources}}
  end

  @impl true
  def handle_call({:clear_logs, source_id}, _from, state) do
    new_state = do_delete_stream(state, source_id)
    {:reply, :ok, new_state}
  end

  # Append & Eviction Helpers

  defp get_or_init_source(sources, source_id) do
    Map.get(sources, source_id, %{
      gen: System.unique_integer([:monotonic, :positive]),
      min_seq: 0,
      max_seq: -1,
      size: 0,
      drop_count: 0,
      last_ts: nil,
      first_ts: nil,
      tail_item: nil
    })
  end

  defp dedup_leading_line(
         %{timestamp: ts1, stream: st1, message: msg1},
         [%{timestamp: ts2, stream: st2, message: msg2} | rest]
       )
       when not is_nil(ts1) and ts1 != "" and ts1 == ts2 and st1 == st2 and msg1 == msg2 do
    rest
  end

  defp dedup_leading_line(_tail_item, lines), do: lines

  defp check_batch_order(lines, last_ts) do
    Enum.reduce(lines, {last_ts, true, nil}, fn line, {cur_last_ts, ordered?, min_ts} ->
      line_ts = Map.get(line, :timestamp)
      has_ts? = is_binary(line_ts) and line_ts != ""
      effective_ts = if has_ts?, do: line_ts, else: cur_last_ts
      sort_ts = effective_ts || ""

      still_ordered? =
        ordered? and
          (cur_last_ts in [nil, ""] or sort_ts in ["", nil] or sort_ts >= cur_last_ts)

      new_min_ts =
        if has_ts? and (is_nil(min_ts) or line_ts < min_ts), do: line_ts, else: min_ts

      {effective_ts, still_ordered?, new_min_ts}
    end)
  end

  defp append_ordered_batch(tab, source_id, source_state, lines, final_last_ts, capacity) do
    batch_len = length(lines)
    old_size = source_state.size
    excess = max(0, old_size + batch_len - capacity)
    evict_old = min(old_size, excess)
    drop_new = excess - evict_old

    kept_lines = if drop_new > 0, do: Enum.drop(lines, drop_new), else: lines
    kept_len = batch_len - drop_new

    start_seq =
      if old_size == 0 do
        0
      else
        source_state.max_seq + 1
      end

    if kept_len > 0 do
      entries =
        kept_lines
        |> Enum.with_index(start_seq)
        |> Enum.map(fn {entry, seq} -> {{{:entry, source_id}, seq}, entry} end)

      :ets.insert(tab, entries)
    end

    new_min_seq =
      cond do
        old_size == 0 -> 0
        evict_old >= old_size -> start_seq
        true -> source_state.min_seq + evict_old
      end

    new_max_seq = start_seq + kept_len - 1
    new_size = old_size - evict_old + kept_len
    new_drops = source_state.drop_count + excess

    new_first_ts =
      if new_size > 0 do
        read_entry_ts(tab, source_id, new_min_seq) || source_state.first_ts
      else
        nil
      end

    new_tail_item = List.last(kept_lines) || source_state.tail_item

    updated = %{
      source_state
      | min_seq: new_min_seq,
        max_seq: new_max_seq,
        size: new_size,
        drop_count: new_drops,
        first_ts: new_first_ts,
        last_ts: final_last_ts,
        tail_item: new_tail_item
    }

    # Write meta BEFORE deleting evicted entries so concurrent readers never observe
    # min_seq pointing at already-deleted slots.
    write_ets_meta(tab, source_id, updated)

    if evict_old > 0 do
      delete_ets_range(tab, source_id, source_state.min_seq, source_state.min_seq + evict_old - 1)
    end

    updated
  end

  defp append_out_of_order_batch(tab, source_id, source_state, lines, min_batch_ts, capacity) do
    # Only scan back across the tail affected by the out-of-order timestamp
    {anchor_seq, suffix_entries} =
      if source_state.size == 0 do
        {-1, []}
      else
        collect_affected_suffix(
          tab,
          source_id,
          source_state.max_seq,
          source_state.min_seq,
          min_batch_ts,
          []
        )
      end

    sorted_suffix =
      (suffix_entries ++ lines)
      |> Enum.sort_by(fn line -> Map.get(line, :timestamp) || "" end)

    prefix_count =
      if source_state.size == 0, do: 0, else: max(0, anchor_seq - source_state.min_seq + 1)

    total_size = prefix_count + length(sorted_suffix)
    excess = max(0, total_size - capacity)

    {new_min_seq, kept_suffix, evict_prefix_count} =
      if excess > 0 do
        evict_prefix = min(prefix_count, excess)
        drop_from_suffix = excess - evict_prefix

        kept_suf =
          if drop_from_suffix > 0,
            do: Enum.drop(sorted_suffix, drop_from_suffix),
            else: sorted_suffix

        new_min =
          if evict_prefix < prefix_count do
            source_state.min_seq + evict_prefix
          else
            anchor_seq + 1 + drop_from_suffix
          end

        {new_min, kept_suf, evict_prefix}
      else
        new_min = if source_state.size == 0, do: 0, else: source_state.min_seq
        {new_min, sorted_suffix, 0}
      end

    write_start_seq =
      cond do
        source_state.size == 0 -> 0
        evict_prefix_count >= prefix_count -> new_min_seq
        true -> anchor_seq + 1
      end

    kept_len = length(kept_suffix)

    if kept_len > 0 do
      entries =
        kept_suffix
        |> Enum.with_index(write_start_seq)
        |> Enum.map(fn {entry, seq} -> {{{:entry, source_id}, seq}, entry} end)

      :ets.insert(tab, entries)
    end

    new_max_seq = write_start_seq + kept_len - 1
    new_size = total_size - excess
    new_drops = source_state.drop_count + excess

    new_first_ts =
      if new_size > 0 do
        read_entry_ts(tab, source_id, new_min_seq) || source_state.first_ts
      else
        nil
      end

    new_last_ts = last_non_empty_ts(kept_suffix, source_state.last_ts)
    new_tail_item = List.last(kept_suffix) || source_state.tail_item

    new_gen =
      if source_state.size > 0 and anchor_seq < source_state.max_seq do
        System.unique_integer([:monotonic, :positive])
      else
        source_state.gen
      end

    updated = %{
      source_state
      | gen: new_gen,
        min_seq: new_min_seq,
        max_seq: new_max_seq,
        size: new_size,
        drop_count: new_drops,
        first_ts: new_first_ts,
        last_ts: new_last_ts,
        tail_item: new_tail_item
    }

    write_ets_meta(tab, source_id, updated)

    if excess > 0 and source_state.size > 0 do
      delete_end = min(source_state.max_seq, new_min_seq - 1)

      if delete_end >= source_state.min_seq do
        delete_ets_range(tab, source_id, source_state.min_seq, delete_end)
      end
    end

    updated
  end

  defp collect_affected_suffix(_tab, _source_id, seq, min_seq, _min_ts, acc) when seq < min_seq do
    {min_seq - 1, acc}
  end

  defp collect_affected_suffix(tab, source_id, seq, min_seq, min_ts, acc) do
    case :ets.lookup(tab, {{:entry, source_id}, seq}) do
      [{_, entry}] ->
        entry_ts = Map.get(entry, :timestamp)

        if is_binary(min_ts) and is_binary(entry_ts) and entry_ts != "" and entry_ts <= min_ts do
          {seq, acc}
        else
          collect_affected_suffix(tab, source_id, seq - 1, min_seq, min_ts, [entry | acc])
        end

      [] ->
        collect_affected_suffix(tab, source_id, seq - 1, min_seq, min_ts, acc)
    end
  end

  defp write_ets_meta(tab, source_id, source_state) do
    meta = %{
      gen: source_state.gen,
      min_seq: source_state.min_seq,
      max_seq: source_state.max_seq,
      size: source_state.size,
      drop_count: source_state.drop_count
    }

    :ets.insert(tab, {{:meta, source_id}, meta})
  end

  defp read_entry_ts(tab, source_id, seq) do
    case :ets.lookup(tab, {{:entry, source_id}, seq}) do
      [{_, %{timestamp: ts}}] when is_binary(ts) and ts != "" -> ts
      _ -> nil
    end
  end

  defp delete_ets_range(_tab, _source_id, from_seq, to_seq) when from_seq > to_seq, do: :ok

  defp delete_ets_range(tab, source_id, from_seq, to_seq) do
    Enum.each(from_seq..to_seq, fn seq ->
      :ets.delete(tab, {{:entry, source_id}, seq})
    end)
  end

  defp last_non_empty_ts(lines, fallback) do
    lines
    |> Enum.reverse()
    |> Enum.find_value(fallback, fn
      %{timestamp: ts} when is_binary(ts) and ts != "" -> ts
      _ -> nil
    end)
  end

  defp do_delete_stream(state, source_id) do
    new_sources = Map.delete(state.sources, source_id)

    if Map.has_key?(state, :table) do
      # Delete meta first so concurrent readers see an empty stream immediately
      :ets.delete(state.table, {:meta, source_id})
      :ets.match_delete(state.table, {{{:entry, source_id}, :_}, :_})
    end

    Phoenix.PubSub.broadcast(
      Caudata.PubSub,
      "logs:#{source_id}",
      {:logs_cleared, source_id}
    )

    %{state | sources: new_sources}
  end

  defp sanitize_lines(lines) do
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
  end

  defp parse_docker_log(line) do
    Caudata.Native.parse_docker_log(line)
  end

  defp strip_boundary_overlap([], _existing), do: []
  defp strip_boundary_overlap(backfill, []), do: backfill

  defp strip_boundary_overlap(backfill, existing_head) do
    sample_size = min(100, length(existing_head))
    backfill_tail_sample = Enum.take(backfill, -sample_size)
    max_k = min(length(backfill_tail_sample), length(existing_head))

    matching_k =
      Enum.find(max_k..1//-1, 0, fn k ->
        backfill_suffix = Enum.take(backfill_tail_sample, -k)
        existing_prefix = Enum.take(existing_head, k)
        lines_match?(backfill_suffix, existing_prefix)
      end)

    if matching_k > 0 do
      Enum.drop(backfill, -matching_k)
    else
      backfill
    end
  end

  defp lines_match?(list1, list2) when length(list1) == length(list2) do
    Enum.zip(list1, list2)
    |> Enum.all?(fn {l1, l2} ->
      l1.timestamp == l2.timestamp and l1.stream == l2.stream and l1.message == l2.message
    end)
  end

  defp lines_match?(_, _), do: false
end
