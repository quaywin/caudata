defmodule Caudata.UI.Cache do
  @moduledoc """
  Lightweight, bounded in-process memoization helpers using the Process Dictionary.
  Prevents unbounded memory growth during continuous log streaming.
  """

  @default_max_size 1_000

  @doc """
  Fetches a value from a process-local 2-generation bounded cache.
  If the key is not found, executes `compute_fn`, stores the result, and returns it.
  Guarantees memory is strictly bounded to at most `2 * max_size` entries.
  """
  def fetch(namespace, key, max_size \\ @default_max_size, compute_fn) when is_function(compute_fn, 0) do
    {curr_gen, old_gen} = Process.get(namespace, {%{}, %{}})

    case Map.fetch(curr_gen, key) do
      {:ok, val} ->
        val

      :error ->
        case Map.fetch(old_gen, key) do
          {:ok, val} ->
            Process.put(namespace, {Map.put(curr_gen, key, val), old_gen})
            val

          :error ->
            val = compute_fn.()

            if map_size(curr_gen) >= max_size do
              Process.put(namespace, {Map.put(%{}, key, val), curr_gen})
            else
              Process.put(namespace, {Map.put(curr_gen, key, val), old_gen})
            end

            val
        end
    end
  end

  @doc """
  Caches only the single most recent `{key, val}` pair for a given namespace.
  Ideal for frame-level aggregates (e.g. displayed logs, total wrapped lines)
  where only the current frame's parameters are ever queried again.
  """
  def fetch_latest(namespace, key, compute_fn) when is_function(compute_fn, 0) do
    case Process.get(namespace) do
      {^key, val} ->
        val

      _ ->
        val = compute_fn.()
        Process.put(namespace, {key, val})
        val
    end
  end
end
