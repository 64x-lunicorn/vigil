defmodule Vigil.EventsTest do
  use ExUnit.Case, async: true

  alias Vigil.Events

  @now ~U[2026-07-10 12:00:00Z]

  defp event(path, title, starts, ends) do
    %{path: path, title: title, starts: starts, ends: ends}
  end

  defp shift(seconds), do: DateTime.add(@now, seconds, :second)

  describe "current/2 — active" do
    test "an event spanning now is active with ends_in" do
      e = event("bike/a.md", "A", shift(-3600), shift(3600))

      result = Events.current([e], @now)

      assert [%{id: "bike/a.md", title: "A", ends_in: "1h"}] = result.active
      assert result.upcoming == []
      assert result.recently_past == []
    end

    test "an event ending exactly at now is still active (boundary is inclusive)" do
      e = event("bike/a.md", "A", shift(-3600), @now)

      result = Events.current([e], @now)

      assert [%{id: "bike/a.md"}] = result.active
      assert result.recently_past == []
    end

    test "multiple active events are sorted soonest-ending first" do
      e1 = event("bike/a.md", "A", shift(-100), shift(7200))
      e2 = event("bike/b.md", "B", shift(-100), shift(3600))

      result = Events.current([e1, e2], @now)

      assert Enum.map(result.active, & &1.id) == ["bike/b.md", "bike/a.md"]
    end
  end

  describe "current/2 — upcoming (30-day horizon)" do
    test "an event starting within 30 days appears with starts_in" do
      e = event("bike/a.md", "A", shift(2 * 86_400), shift(3 * 86_400))

      result = Events.current([e], @now)

      assert [%{id: "bike/a.md", title: "A", starts_in: "2d"}] = result.upcoming
    end

    test "an event starting beyond the 30-day horizon is excluded" do
      e = event("bike/a.md", "A", shift(31 * 86_400), shift(32 * 86_400))

      result = Events.current([e], @now)

      assert result.upcoming == []
    end

    test "multiple upcoming events are sorted soonest-first" do
      e1 = event("bike/a.md", "A", shift(10 * 86_400), shift(11 * 86_400))
      e2 = event("bike/b.md", "B", shift(1 * 86_400), shift(1 * 86_400 + 3600))

      result = Events.current([e1, e2], @now)

      assert Enum.map(result.upcoming, & &1.id) == ["bike/b.md", "bike/a.md"]
    end
  end

  describe "current/2 — recently_past (7-day horizon)" do
    test "an event that ended within the last 7 days appears with ended" do
      e = event("bike/a.md", "A", shift(-2 * 86_400 - 3600), shift(-2 * 86_400))

      result = Events.current([e], @now)

      assert [%{id: "bike/a.md", title: "A", ended: "2d ago"}] = result.recently_past
    end

    test "an event that ended more than 7 days ago is excluded" do
      e = event("bike/a.md", "A", shift(-8 * 86_400 - 3600), shift(-8 * 86_400))

      result = Events.current([e], @now)

      assert result.recently_past == []
    end

    test "multiple recently_past events are sorted most-recently-ended first" do
      e1 = event("bike/a.md", "A", shift(-5 * 86_400 - 100), shift(-5 * 86_400))
      e2 = event("bike/b.md", "B", shift(-1 * 86_400 - 100), shift(-1 * 86_400))

      result = Events.current([e1, e2], @now)

      assert Enum.map(result.recently_past, & &1.id) == ["bike/b.md", "bike/a.md"]
    end
  end

  test "current/2 stamps now as ISO8601" do
    result = Events.current([], @now)
    assert result.now == DateTime.to_iso8601(@now)
  end

  test "current/2 on an empty event list returns empty windows" do
    assert Events.current([], @now) == %{
             now: DateTime.to_iso8601(@now),
             active: [],
             upcoming: [],
             recently_past: []
           }
  end

  describe "snapshot/2" do
    test "active_ids matches active events, near.active carries the same event" do
      e = event("bike/a.md", "A", shift(-100), shift(100))

      result = Events.snapshot([e], @now)

      assert MapSet.member?(result.active_ids, "bike/a.md")
      assert Enum.any?(result.near.active, &(&1.id == "bike/a.md"))
    end

    test "near uses a 7-day horizon, narrower than current/2's 30-day upcoming window" do
      e = event("bike/a.md", "A", shift(10 * 86_400), shift(11 * 86_400))

      current = Events.current([e], @now)
      snapshot = Events.snapshot([e], @now)

      assert Enum.any?(current.upcoming, &(&1.id == "bike/a.md"))
      refute Enum.any?(snapshot.near.upcoming, &(&1.id == "bike/a.md"))
    end

    test "titles cover every event, including ones outside the near horizon" do
      past = event("bike/past.md", "Past", shift(-20 * 86_400 - 100), shift(-20 * 86_400))
      future = event("bike/future.md", "Future", shift(60 * 86_400), shift(61 * 86_400))

      result = Events.snapshot([past, future], @now)

      assert result.titles == %{"bike/past.md" => "Past", "bike/future.md" => "Future"}
      refute MapSet.member?(result.active_ids, "bike/past.md")
      refute Enum.any?(result.near.active ++ result.near.upcoming, &(&1.id == "bike/past.md"))
    end

    test "an empty event list returns empty ids, near lists, and titles" do
      assert Events.snapshot([], @now) == %{
               active_ids: MapSet.new(),
               near: %{active: [], upcoming: []},
               titles: %{}
             }
    end
  end
end
