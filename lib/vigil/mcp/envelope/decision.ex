defmodule Vigil.MCP.Envelope.Decision do
  @moduledoc """
  The time envelope's wording and its choice between `_`, `_t` and `_!`,
  as a pure function of the session's previous state, a `Vigil.Store`
  snapshot, and an instant. It decides; it does not write anywhere and makes
  no calls into `Vigil.Store` itself — `Vigil.MCP.Envelope` fetches the
  snapshot once per response and passes it in here.
  """

  @stale_after 24 * 3600

  @weekdays {"Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"}

  @doc """
  The envelope for a response to `tool`, given the session's previous state
  (`nil` for a session with none yet). Returns `{envelope, new_session_state}`.

  `current` always gets `_t`: its own response is the full time picture, so the
  long first line under it would say the same thing twice. It still counts as
  the session's first call, and that rule lives here rather than in the
  transport layer — which form a tool gets is a decision about the envelope,
  not about routing.
  """
  def for_tool("current", _prev_state, now, snapshot) do
    {%{"_t" => format_time(now)}, session_state(now, snapshot)}
  end

  def for_tool(_tool, prev_state, now, snapshot) do
    result =
      case prev_state do
        nil ->
          first_line(now, snapshot)

        %{last_active: last_active, active_ids: prev_ids} ->
          cond do
            DateTime.diff(now, last_active) > @stale_after ->
              first_line(now, snapshot)

            MapSet.equal?(prev_ids, snapshot.active_ids) ->
              %{"_t" => format_time(now)}

            true ->
              %{"_!" => phase_change_text(prev_ids, snapshot.active_ids, snapshot.titles)}
          end
      end

    {result, session_state(now, snapshot)}
  end

  defp session_state(now, snapshot), do: %{active_ids: snapshot.active_ids, last_active: now}

  defp format_time(now), do: Calendar.strftime(now, "%H:%M")

  defp first_line(now, snapshot) do
    weekday = elem(@weekdays, Date.day_of_week(now) - 1)
    date = Calendar.strftime(now, "%d.%m.")
    time = format_time(now)

    header = "#{weekday} #{date} #{time}"

    case near_event_summary(snapshot) do
      nil -> %{"_" => header}
      summary -> %{"_" => "#{header} | #{summary}"}
    end
  end

  defp near_event_summary(snapshot) do
    near = snapshot.near

    cond do
      near.active != [] ->
        event = List.first(near.active)
        "#{event.title} #{event.ends_in} left"

      near.upcoming != [] ->
        event = List.first(near.upcoming)
        "#{event.title} in #{event.starts_in}"

      true ->
        nil
    end
  end

  defp phase_change_text(prev_ids, active_ids, titles) do
    newly_active = MapSet.difference(active_ids, prev_ids) |> MapSet.to_list()
    newly_inactive = MapSet.difference(prev_ids, active_ids) |> MapSet.to_list()

    cond do
      newly_active != [] ->
        path = List.first(newly_active)
        "#{title_for(titles, path)} now active"

      newly_inactive != [] ->
        path = List.first(newly_inactive)
        "#{title_for(titles, path)} now finished"

      true ->
        "phase changed"
    end
  end

  defp title_for(titles, path), do: Map.get(titles, path, path)
end
