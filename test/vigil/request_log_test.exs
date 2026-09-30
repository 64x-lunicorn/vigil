defmodule Vigil.RequestLogTest do
  # docs/design.md, "A retried write is applied once": the writer remembers
  # what a write answered under the id its caller gave it, for a bounded
  # number of writes and a bounded time. The clock is handed in, so both
  # bounds are asserted without waiting for either.
  use ExUnit.Case, async: true

  alias Vigil.RequestLog

  @result {:ok, %{path: "bike/a.md", pushed: true}}

  test "an id never seen is unknown" do
    assert RequestLog.lookup(RequestLog.new(), "r1", :append_a, 0) == :unknown
  end

  test "a remembered id answers the result it was remembered with" do
    log = RequestLog.new() |> RequestLog.remember("r1", :append_a, @result, 0)

    assert RequestLog.lookup(log, "r1", :append_a, 1_000) == {:applied, @result}
  end

  test "the same id for a different write is a conflict, not the first result" do
    log = RequestLog.new() |> RequestLog.remember("r1", :append_a, @result, 0)

    assert RequestLog.lookup(log, "r1", :append_b, 1_000) == :conflict
  end

  test "an id older than the age bound is forgotten" do
    log =
      RequestLog.new(max_age_ms: 10_000)
      |> RequestLog.remember("r1", :append_a, @result, 0)

    assert RequestLog.lookup(log, "r1", :append_a, 10_000) == {:applied, @result}
    assert RequestLog.lookup(log, "r1", :append_a, 10_001) == :unknown
  end

  test "past the count bound the oldest id goes first" do
    log =
      Enum.reduce(1..3, RequestLog.new(max_entries: 2), fn n, log ->
        RequestLog.remember(log, "r#{n}", :write, {:ok, n}, n)
      end)

    assert RequestLog.lookup(log, "r1", :write, 3) == :unknown
    assert RequestLog.lookup(log, "r2", :write, 3) == {:applied, {:ok, 2}}
    assert RequestLog.lookup(log, "r3", :write, 3) == {:applied, {:ok, 3}}
    assert RequestLog.size(log) == 2
  end

  test "expired ids do not count against the count bound" do
    log =
      RequestLog.new(max_entries: 2, max_age_ms: 10)
      |> RequestLog.remember("r1", :write, {:ok, 1}, 0)
      |> RequestLog.remember("r2", :write, {:ok, 2}, 0)
      |> RequestLog.remember("r3", :write, {:ok, 3}, 100)

    assert RequestLog.size(log) == 1
    assert RequestLog.lookup(log, "r3", :write, 100) == {:applied, {:ok, 3}}
  end

  test "an id remembered again after it expired is remembered once" do
    log =
      RequestLog.new(max_age_ms: 10)
      |> RequestLog.remember("r1", :write, {:ok, 1}, 0)
      |> RequestLog.remember("r1", :write, {:ok, 2}, 100)

    assert RequestLog.size(log) == 1
    assert RequestLog.lookup(log, "r1", :write, 100) == {:applied, {:ok, 2}}
  end
end
