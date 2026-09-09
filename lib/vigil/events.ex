defmodule Vigil.Events do
  @moduledoc """
  Computes `current`/`snapshot` event windows over an already-filtered list
  of event-typed file records.

  Pure: takes `events` (a plain list, the `type == :event` file records
  `Vigil.Store.event_files/0` already filters) and a resolved `now`, returns
  data — no ETS access of its own.

  Not named after "the time envelope" — that term is reserved in
  `docs/design.md` for the `_`/`_t`/`_!` field mechanism
  `Vigil.MCP.Envelope.Decision` computes. This module feeds it a snapshot;
  it isn't the envelope itself.
  """

  @near_horizon_seconds 7 * 86_400
  @upcoming_horizon_seconds 30 * 86_400
  @recently_past_horizon_seconds 7 * 86_400

  @doc "%{now:, active:, upcoming:, recently_past:} — today's `current` shape."
  def current(events, now) do
    active = events |> active_events(now) |> Enum.map(&active_view(&1, now))

    upcoming =
      events
      |> upcoming_events(now, @upcoming_horizon_seconds)
      |> Enum.map(&upcoming_view(&1, now))

    recently_past = events |> recently_past_events(now) |> Enum.map(&recently_past_view(&1, now))

    %{
      now: DateTime.to_iso8601(now),
      active: active,
      upcoming: upcoming,
      recently_past: recently_past
    }
  end

  @doc "%{active_ids:, near:, titles:} — today's `snapshot` shape."
  def snapshot(events, now) do
    active_ids = events |> active_events(now) |> Enum.map(& &1.path) |> MapSet.new()
    near = near_summary_view(events, now)
    titles = Map.new(events, &{&1.path, &1.title})

    %{active_ids: active_ids, near: near, titles: titles}
  end

  # Events active at `now`, soonest-ending first — the shared basis for
  # near_summary_view's `active`, current's `active`, and snapshot's
  # `active`/`active_ids`.
  defp active_events(events, now) do
    events
    |> Enum.filter(fn e ->
      DateTime.compare(now, e.starts) != :lt and DateTime.compare(now, e.ends) != :gt
    end)
    |> Enum.sort_by(& &1.ends, DateTime)
  end

  # Events starting within `horizon_seconds` of `now`, soonest-first.
  defp upcoming_events(events, now, horizon_seconds) do
    cutoff = DateTime.add(now, horizon_seconds, :second)

    events
    |> Enum.filter(fn e ->
      DateTime.compare(e.starts, now) == :gt and DateTime.compare(e.starts, cutoff) != :gt
    end)
    |> Enum.sort_by(& &1.starts, DateTime)
  end

  # Events that ended within @recently_past_horizon_seconds of `now`,
  # most-recently-ended first.
  defp recently_past_events(events, now) do
    cutoff = DateTime.add(now, -@recently_past_horizon_seconds, :second)

    events
    |> Enum.filter(fn e ->
      DateTime.compare(e.ends, now) == :lt and DateTime.compare(e.ends, cutoff) != :lt
    end)
    |> Enum.sort_by(& &1.ends, {:desc, DateTime})
  end

  defp active_view(e, now) do
    %{id: e.path, title: e.title, ends_in: Vigil.TimeFmt.duration(DateTime.diff(e.ends, now))}
  end

  defp upcoming_view(e, now) do
    %{id: e.path, title: e.title, starts_in: Vigil.TimeFmt.duration(DateTime.diff(e.starts, now))}
  end

  defp recently_past_view(e, now) do
    %{id: e.path, title: e.title, ended: Vigil.TimeFmt.ago(DateTime.diff(now, e.ends))}
  end

  # %{active:, upcoming:} over the near horizon — feeds snapshot/2, the time
  # envelope's single query.
  defp near_summary_view(events, now) do
    active = events |> active_events(now) |> Enum.map(&active_view(&1, now))

    upcoming =
      events
      |> upcoming_events(now, @near_horizon_seconds)
      |> Enum.map(&upcoming_view(&1, now))

    %{active: active, upcoming: upcoming}
  end
end
