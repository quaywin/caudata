defmodule Caudata.LogStoreTest do
  use ExUnit.Case, async: true
  alias Caudata.LogStore

  setup do
    # Start LogStore under a unique name for this test run
    # to avoid conflict with the globally running Caudata.LogStore
    start_supervised!({LogStore, name: TestLogStore, capacity: 5})
    :ok
  end

  test "stores and retrieves log lines in chronological order" do
    LogStore.append_logs(TestLogStore, "source1", ["line 1", "line 2"])
    _ = LogStore.get_stats(TestLogStore, "source1")

    snapshot = LogStore.get_snapshot(TestLogStore, "source1")

    assert snapshot == [
             %{timestamp: nil, stream: :stdout, message: "line 1"},
             %{timestamp: nil, stream: :stdout, message: "line 2"}
           ]

    stats = LogStore.get_stats(TestLogStore, "source1")
    assert stats.size == 2
    assert stats.drop_count == 0
  end

  test "drops oldest rows when capacity is exceeded and increments drop count" do
    # Capacity is 5
    LogStore.append_logs(TestLogStore, "source1", ["1", "2", "3"])
    LogStore.append_logs(TestLogStore, "source1", ["4", "5", "6", "7"])
    _ = LogStore.get_stats(TestLogStore, "source1")

    snapshot = LogStore.get_snapshot(TestLogStore, "source1")

    assert snapshot == [
             %{timestamp: nil, stream: :stdout, message: "3"},
             %{timestamp: nil, stream: :stdout, message: "4"},
             %{timestamp: nil, stream: :stdout, message: "5"},
             %{timestamp: nil, stream: :stdout, message: "6"},
             %{timestamp: nil, stream: :stdout, message: "7"}
           ]

    stats = LogStore.get_stats(TestLogStore, "source1")
    assert stats.size == 5
    assert stats.drop_count == 2
  end

  test "broadcasts updates on PubSub" do
    # Uses the global PubSub that is already running
    Phoenix.PubSub.subscribe(Caudata.PubSub, "logs:source_pub")

    LogStore.append_logs(TestLogStore, "source_pub", ["hello"])

    assert_receive {:logs_updated, "source_pub", %{size: 1, drop_count: 0}}, 500

    LogStore.clear_logs(TestLogStore, "source_pub")
    assert_receive {:logs_cleared, "source_pub"}, 500
  end

  test "deletes stream asynchronously with delete_stream" do
    Phoenix.PubSub.subscribe(Caudata.PubSub, "logs:source_del")

    LogStore.append_logs(TestLogStore, "source_del", ["test message"])
    assert_receive {:logs_updated, "source_del", %{size: 1, drop_count: 0}}, 500

    LogStore.delete_stream(TestLogStore, "source_del")
    assert_receive {:logs_cleared, "source_del"}, 500

    snapshot = LogStore.get_snapshot(TestLogStore, "source_del")
    assert snapshot == []
  end

  test "keeps new log lines without timestamps at the end of the stream" do
    LogStore.append_logs(TestLogStore, "source_ts", [
      "2026-08-04T10:00:00Z line with timestamp",
      "line without timestamp 1",
      "line without timestamp 2"
    ])

    _ = LogStore.get_stats(TestLogStore, "source_ts")

    snapshot = LogStore.get_snapshot(TestLogStore, "source_ts")

    assert snapshot == [
             %{
               timestamp: "2026-08-04T10:00:00Z",
               stream: :stdout,
               message: "line with timestamp"
             },
             %{timestamp: nil, stream: :stdout, message: "line without timestamp 1"},
             %{timestamp: nil, stream: :stdout, message: "line without timestamp 2"}
           ]
  end

  test "deduplicates leading log line if identical to last line in store" do
    LogStore.append_logs(TestLogStore, "source_dedup", [
      "2026-08-04T10:00:00Z line 1"
    ])

    _ = LogStore.get_stats(TestLogStore, "source_dedup")

    # Re-append same line (from --since inclusive response) plus a new line
    LogStore.append_logs(TestLogStore, "source_dedup", [
      "2026-08-04T10:00:00Z line 1",
      "2026-08-04T10:00:01Z line 2"
    ])

    _ = LogStore.get_stats(TestLogStore, "source_dedup")

    snapshot = LogStore.get_snapshot(TestLogStore, "source_dedup")

    assert snapshot == [
             %{timestamp: "2026-08-04T10:00:00Z", stream: :stdout, message: "line 1"},
             %{timestamp: "2026-08-04T10:00:01Z", stream: :stdout, message: "line 2"}
           ]
  end

  test "retrieves snapshots accurately across limits (tail, medium, and full)" do
    logs = Enum.map(1..1200, fn i -> "line #{i}" end)
    store_name = :"MultiLimitStore_#{System.unique_integer([:positive])}"
    start_supervised!({LogStore, name: store_name, capacity: 2000}, id: store_name)

    LogStore.append_logs(store_name, "multi_limit", logs)
    _ = LogStore.get_stats(store_name, "multi_limit")

    # Limit <= 500 uses :snapshot_tail
    tail = LogStore.get_snapshot(store_name, "multi_limit", 300)
    assert length(tail) == 300
    assert List.last(tail).message == "line 1200"

    # Limit <= 1500 uses :snapshot_medium
    medium = LogStore.get_snapshot(store_name, "multi_limit", 1000)
    assert length(medium) == 1000
    assert List.last(medium).message == "line 1200"

    # Limit > 1500 uses :snapshot
    full = LogStore.get_snapshot(store_name, "multi_limit", 1600)
    assert length(full) == 1200
    assert List.first(full).message == "line 1"
    assert List.last(full).message == "line 1200"
  end

  test "prepend_logs prepends historical lines maintaining chronological order" do
    LogStore.append_logs(TestLogStore, "source_prepend", [
      "2026-08-04T10:00:02Z line 3",
      "2026-08-04T10:00:03Z line 4"
    ])

    LogStore.prepend_logs(TestLogStore, "source_prepend", [
      "2026-08-04T10:00:00Z line 1",
      "2026-08-04T10:00:01Z line 2"
    ])

    _ = LogStore.get_stats(TestLogStore, "source_prepend")
    snapshot = LogStore.get_snapshot(TestLogStore, "source_prepend")

    assert snapshot == [
             %{timestamp: "2026-08-04T10:00:00Z", stream: :stdout, message: "line 1"},
             %{timestamp: "2026-08-04T10:00:01Z", stream: :stdout, message: "line 2"},
             %{timestamp: "2026-08-04T10:00:02Z", stream: :stdout, message: "line 3"},
             %{timestamp: "2026-08-04T10:00:03Z", stream: :stdout, message: "line 4"}
           ]

    stats = LogStore.get_stats(TestLogStore, "source_prepend")
    assert stats.size == 4
    assert stats.drop_count == 0
    assert stats.first_ts == "2026-08-04T10:00:00Z"
    assert stats.last_ts == "2026-08-04T10:00:03Z"
  end

  test "prepend_logs deduplicates boundary overlap with existing queue head" do
    LogStore.append_logs(TestLogStore, "source_overlap", [
      "2026-08-04T10:00:02Z line 2",
      "2026-08-04T10:00:03Z line 3"
    ])

    # Backfill returns line 1 and line 2 (line 2 is boundary duplicate from --until)
    LogStore.prepend_logs(TestLogStore, "source_overlap", [
      "2026-08-04T10:00:01Z line 1",
      "2026-08-04T10:00:02Z line 2"
    ])

    _ = LogStore.get_stats(TestLogStore, "source_overlap")
    snapshot = LogStore.get_snapshot(TestLogStore, "source_overlap")

    assert snapshot == [
             %{timestamp: "2026-08-04T10:00:01Z", stream: :stdout, message: "line 1"},
             %{timestamp: "2026-08-04T10:00:02Z", stream: :stdout, message: "line 2"},
             %{timestamp: "2026-08-04T10:00:03Z", stream: :stdout, message: "line 3"}
           ]

    stats = LogStore.get_stats(TestLogStore, "source_overlap")
    assert stats.size == 3
  end

  test "prepend_logs respects capacity and increments drop count for oldest backfill overflow" do
    # Capacity is 5
    LogStore.append_logs(TestLogStore, "source_cap", ["3", "4", "5"])

    # Attempt to prepend 4 historical lines (total would be 7, exceeds capacity 5)
    LogStore.prepend_logs(TestLogStore, "source_cap", ["-1", "0", "1", "2"])

    _ = LogStore.get_stats(TestLogStore, "source_cap")
    snapshot = LogStore.get_snapshot(TestLogStore, "source_cap")

    assert snapshot == [
             %{timestamp: nil, stream: :stdout, message: "1"},
             %{timestamp: nil, stream: :stdout, message: "2"},
             %{timestamp: nil, stream: :stdout, message: "3"},
             %{timestamp: nil, stream: :stdout, message: "4"},
             %{timestamp: nil, stream: :stdout, message: "5"}
           ]

    stats = LogStore.get_stats(TestLogStore, "source_cap")
    assert stats.size == 5
    assert stats.drop_count == 2
  end

  test "prepend_logs updates ETS snapshots and broadcasts PubSub message" do
    Phoenix.PubSub.subscribe(Caudata.PubSub, "logs:source_ets")

    LogStore.append_logs(TestLogStore, "source_ets", ["line 2"])
    assert_receive {:logs_updated, "source_ets", %{size: 1, drop_count: 0}}, 500

    LogStore.prepend_logs(TestLogStore, "source_ets", ["line 1"])
    assert_receive {:logs_updated, "source_ets", %{size: 2, drop_count: 0}}, 500

    snapshot = LogStore.get_snapshot(TestLogStore, "source_ets")
    assert length(snapshot) == 2
    assert List.first(snapshot).message == "line 1"
    assert List.last(snapshot).message == "line 2"
  end

  test "set_capacity can shrink capacity and trims existing buffers" do
    LogStore.append_logs(TestLogStore, "source_shrink", ["1", "2", "3", "4", "5"])
    _ = LogStore.get_stats(TestLogStore, "source_shrink")

    assert :ok = LogStore.set_capacity(TestLogStore, 3)

    snapshot = LogStore.get_snapshot(TestLogStore, "source_shrink")

    assert snapshot == [
             %{timestamp: nil, stream: :stdout, message: "3"},
             %{timestamp: nil, stream: :stdout, message: "4"},
             %{timestamp: nil, stream: :stdout, message: "5"}
           ]

    stats = LogStore.get_stats(TestLogStore, "source_shrink")
    assert stats.size == 3
    assert stats.drop_count == 2
  end

  test "get_snapshot_window returns monotonic seq metadata and supports append_prepared_logs" do
    entries = [
      %{timestamp: "2026-08-04T10:00:00Z", stream: :stdout, message: "first"},
      %{timestamp: "2026-08-04T10:00:01Z", stream: :stdout, message: "second"},
      %{timestamp: "2026-08-04T10:00:02Z", stream: :stdout, message: "third"}
    ]

    LogStore.append_prepared_logs(TestLogStore, "source_win", entries)
    _ = LogStore.get_stats(TestLogStore, "source_win")

    {tail_lines, meta} = LogStore.get_snapshot_window(TestLogStore, "source_win", 2)
    assert Enum.map(tail_lines, & &1.message) == ["second", "third"]
    assert meta.first_seq == 1
    assert meta.last_seq == 2
    assert meta.size == 3
    assert is_integer(meta.gen)

    # Overflowing capacity shifts first_seq forward monotonically within same gen
    LogStore.append_prepared_logs(TestLogStore, "source_win", [
      %{timestamp: "2026-08-04T10:00:03Z", stream: :stdout, message: "fourth"},
      %{timestamp: "2026-08-04T10:00:04Z", stream: :stdout, message: "fifth"},
      %{timestamp: "2026-08-04T10:00:05Z", stream: :stdout, message: "sixth"}
    ])

    _ = LogStore.get_stats(TestLogStore, "source_win")

    {full_lines, meta2} = LogStore.get_snapshot_window(TestLogStore, "source_win", 5)
    assert Enum.map(full_lines, & &1.message) == ["second", "third", "fourth", "fifth", "sixth"]
    assert meta2.first_seq == 1
    assert meta2.last_seq == 5
    assert meta2.gen == meta.gen
    assert meta2.drop_count == 1
  end

  test "out-of-order batch sorts affected tail and respects full capacity eviction" do
    LogStore.append_logs(TestLogStore, "source_ooo", [
      "2026-08-04T10:00:01Z line 1",
      "2026-08-04T10:00:02Z line 2",
      "2026-08-04T10:00:04Z line 4",
      "2026-08-04T10:00:06Z line 6",
      "2026-08-04T10:00:08Z line 8"
    ])

    # Out-of-order batch (T10:00:03 and T10:00:05) arriving when buffer is already at capacity 5
    LogStore.append_logs(TestLogStore, "source_ooo", [
      "2026-08-04T10:00:03Z line 3",
      "2026-08-04T10:00:05Z line 5"
    ])

    _ = LogStore.get_stats(TestLogStore, "source_ooo")
    snapshot = LogStore.get_snapshot(TestLogStore, "source_ooo")

    assert Enum.map(snapshot, & &1.message) == [
             "line 3",
             "line 4",
             "line 5",
             "line 6",
             "line 8"
           ]

    stats = LogStore.get_stats(TestLogStore, "source_ooo")
    assert stats.size == 5
    assert stats.drop_count == 2
  end

  test "out-of-order batch preserves chronological order when interleaved with nil timestamps" do
    LogStore.append_prepared_logs(TestLogStore, "source_ooo_nil", [
      %{timestamp: "2026-08-04T10:00:01Z", stream: :stdout, message: "t1"},
      %{timestamp: nil, stream: :stdout, message: "plain"},
      %{timestamp: "2026-08-04T10:00:05Z", stream: :stdout, message: "t5"}
    ])

    LogStore.append_prepared_logs(TestLogStore, "source_ooo_nil", [
      %{timestamp: "2026-08-04T10:00:03Z", stream: :stdout, message: "t3"}
    ])

    _ = LogStore.get_stats(TestLogStore, "source_ooo_nil")
    snapshot = LogStore.get_snapshot(TestLogStore, "source_ooo_nil")

    assert Enum.map(snapshot, & &1.message) == ["t1", "plain", "t3", "t5"]
  end
end
