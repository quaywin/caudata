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

    Process.sleep(50)

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

    Process.sleep(50)

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

    Process.sleep(50)
    snapshot = LogStore.get_snapshot(TestLogStore, "source_ts")

    assert snapshot == [
             %{timestamp: "2026-08-04T10:00:00Z", stream: :stdout, message: "line with timestamp"},
             %{timestamp: nil, stream: :stdout, message: "line without timestamp 1"},
             %{timestamp: nil, stream: :stdout, message: "line without timestamp 2"}
           ]
  end
end
