defmodule Vigil.MCP.Envelope.DecisionTest do
  use ExUnit.Case, async: true

  alias Vigil.MCP.Envelope.Decision

  @now ~U[2026-07-09 11:20:00Z] |> DateTime.shift_zone!("Europe/Berlin")

  defp snapshot(opts \\ []) do
    %{
      active_ids: Keyword.get(opts, :active_ids, MapSet.new()),
      near: Keyword.get(opts, :near, %{active: [], upcoming: []}),
      titles: Keyword.get(opts, :titles, %{})
    }
  end

  describe "for_current/2" do
    test "always '_t', and its new state counts as the session's first call" do
      {result, state} = Decision.for_current(@now, snapshot())

      assert %{"_t" => "13:20"} = result
      assert state == %{active_ids: MapSet.new(), last_active: @now}
    end
  end

  describe "for_call/3 — first call in the session (prev_state nil)" do
    test "no near event: header only" do
      {result, _state} = Decision.for_call(nil, @now, snapshot())

      assert %{"_" => line} = result
      assert line =~ ~r/^(Mon|Tue|Wed|Thu|Fri|Sat|Sun) \d{2}\.\d{2}\. \d{2}:\d{2}$/
    end

    test "an active near event is summarized in English with its note title, ends_in 'left'" do
      near = %{
        active: [%{id: "bike/via-carolina.md", title: "Via Carolina", ends_in: "28h"}],
        upcoming: []
      }

      {result, _state} = Decision.for_call(nil, @now, snapshot(near: near))

      assert %{"_" => line} = result
      assert line =~ "| Via Carolina 28h left"
    end

    test "an upcoming near event is summarized with its note title and 'in'" do
      near = %{
        active: [],
        upcoming: [%{id: "bike/via-carolina.md", title: "Via Carolina", starts_in: "28h"}]
      }

      {result, _state} = Decision.for_call(nil, @now, snapshot(near: near))

      assert %{"_" => line} = result
      assert line =~ "| Via Carolina in 28h"
    end

    test "new state reflects the snapshot's active_ids and now" do
      active_ids = MapSet.new(["bike/via-carolina.md"])
      {_result, state} = Decision.for_call(nil, @now, snapshot(active_ids: active_ids))

      assert state == %{active_ids: active_ids, last_active: @now}
    end
  end

  describe "for_call/3 — later call, nothing changed" do
    test "same active_ids yields '_t'" do
      active_ids = MapSet.new(["bike/via-carolina.md"])
      prev_state = %{active_ids: active_ids, last_active: DateTime.add(@now, -60)}

      {result, _state} = Decision.for_call(prev_state, @now, snapshot(active_ids: active_ids))

      assert %{"_t" => "13:20"} = result
    end
  end

  describe "for_call/3 — phase change during the session" do
    test "newly active event names itself with its title, not the filename stem" do
      prev_state = %{active_ids: MapSet.new(), last_active: DateTime.add(@now, -60)}
      active_ids = MapSet.new(["bike/via-carolina.md"])
      titles = %{"bike/via-carolina.md" => "Via Carolina"}

      {result, _state} =
        Decision.for_call(prev_state, @now, snapshot(active_ids: active_ids, titles: titles))

      assert %{"_!" => "Via Carolina now active"} = result
    end

    test "newly inactive event reports 'now finished'" do
      prev_state = %{active_ids: MapSet.new(["bike/via-carolina.md"]), last_active: @now}
      titles = %{"bike/via-carolina.md" => "Via Carolina"}

      {result, _state} =
        Decision.for_call(prev_state, @now, snapshot(active_ids: MapSet.new(), titles: titles))

      assert %{"_!" => "Via Carolina now finished"} = result
    end

    test "a title missing from the snapshot's titles falls back to the path" do
      prev_state = %{active_ids: MapSet.new(), last_active: @now}
      active_ids = MapSet.new(["bike/via-carolina.md"])

      {result, _state} = Decision.for_call(prev_state, @now, snapshot(active_ids: active_ids))

      assert %{"_!" => "bike/via-carolina.md now active"} = result
    end
  end

  describe "for_call/3 — a stale session is treated as a new one" do
    test "more than 24h since last_active re-triggers the first-call header" do
      prev_state = %{
        active_ids: MapSet.new(["bike/via-carolina.md"]),
        last_active: DateTime.add(@now, -25 * 3600)
      }

      {result, _state} = Decision.for_call(prev_state, @now, snapshot())

      assert %{"_" => _} = result
    end
  end
end
