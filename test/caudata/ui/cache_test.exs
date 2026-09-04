defmodule Caudata.UI.CacheTest do
  use ExUnit.Case, async: true
  alias Caudata.UI.Cache

  test "fetch/4 caches and retrieves values" do
    calls = :counters.new(1, [:atomics])
    compute = fn ->
      :counters.add(calls, 1, 1)
      "computed_val"
    end

    assert Cache.fetch(:test_cache, "k1", compute) == "computed_val"
    assert :counters.get(calls, 1) == 1

    # Second call hits cache, compute not executed
    assert Cache.fetch(:test_cache, "k1", compute) == "computed_val"
    assert :counters.get(calls, 1) == 1
  end

  test "fetch/4 bounds memory by cycling generations when exceeding max_size" do
    max_size = 5

    # Insert 5 items (fills current_gen)
    Enum.each(1..5, fn i ->
      Cache.fetch(:test_bounded, "key_#{i}", max_size, fn -> "val_#{i}" end)
    end)

    {curr, old} = Process.get(:test_bounded)
    assert map_size(curr) == 5
    assert map_size(old) == 0

    # Insert 6th item (cycles current_gen to old_gen)
    Cache.fetch(:test_bounded, "key_6", max_size, fn -> "val_6" end)
    {curr, old} = Process.get(:test_bounded)
    assert map_size(curr) == 1
    assert map_size(old) == 5

    # Promoting a key from old to curr
    assert Cache.fetch(:test_bounded, "key_1", max_size, fn -> "should_not_call" end) == "val_1"
    {curr, _old} = Process.get(:test_bounded)
    assert Map.has_key?(curr, "key_1")

    # Insert another 5 items to trigger second cycle (evicting initial old_gen)
    Enum.each(7..11, fn i ->
      Cache.fetch(:test_bounded, "key_#{i}", max_size, fn -> "val_#{i}" end)
    end)

    {curr, old} = Process.get(:test_bounded)
    # Memory never exceeds 2 * max_size
    assert map_size(curr) + map_size(old) <= 2 * max_size
  end

  test "fetch_latest/3 caches single latest value and discards previous" do
    calls = :counters.new(1, [:atomics])

    c1 = Cache.fetch_latest(:test_latest, "key_A", fn ->
      :counters.add(calls, 1, 1)
      "res_A"
    end)
    assert c1 == "res_A"
    assert :counters.get(calls, 1) == 1

    # Same key -> cached
    c2 = Cache.fetch_latest(:test_latest, "key_A", fn ->
      :counters.add(calls, 1, 1)
      "res_A"
    end)
    assert c2 == "res_A"
    assert :counters.get(calls, 1) == 1

    # Different key -> replaces previous
    c3 = Cache.fetch_latest(:test_latest, "key_B", fn ->
      :counters.add(calls, 1, 1)
      "res_B"
    end)
    assert c3 == "res_B"
    assert :counters.get(calls, 1) == 2

    # Exactly 1 tuple in process dictionary
    assert Process.get(:test_latest) == {"key_B", "res_B"}
  end
end
