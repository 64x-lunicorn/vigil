defmodule Vigil.MCP.Envelope do
  @moduledoc false
  use GenServer

  @table :vigil_sessions
  @stale_after 24 * 3600

  @weekdays {"Mo", "Di", "Mi", "Do", "Fr", "Sa", "So"}

  def start_link(_opts), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @doc "Envelope for the `current` tool: always \"_t\", but counts as the session's first call."
  def for_current(session_id) do
    GenServer.call(__MODULE__, {:for_current, session_id})
  end

  @doc "Envelope for any other tool call."
  def for_call(session_id) do
    GenServer.call(__MODULE__, {:for_call, session_id})
  end

  @impl true
  def init(_) do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:set, :named_table, :private])
    end

    {:ok, %{}}
  end

  @impl true
  def handle_call({:for_current, session_id}, _from, state) do
    now = now()
    active_ids = Vigil.Store.active_event_ids(now)
    :ets.insert(@table, {session_id, %{active_ids: active_ids, last_active: now}})
    {:reply, %{"_t" => format_time(now)}, state}
  end

  def handle_call({:for_call, session_id}, _from, state) do
    now = now()
    active_ids = Vigil.Store.active_event_ids(now)

    result =
      case :ets.lookup(@table, session_id) do
        [] ->
          first_line(now, active_ids)

        [{_, %{last_active: last_active, active_ids: prev_ids}}] ->
          cond do
            DateTime.diff(now, last_active) > @stale_after ->
              first_line(now, active_ids)

            MapSet.equal?(prev_ids, active_ids) ->
              %{"_t" => format_time(now)}

            true ->
              %{"_!" => phase_change_text(prev_ids, active_ids)}
          end
      end

    :ets.insert(@table, {session_id, %{active_ids: active_ids, last_active: now}})
    {:reply, result, state}
  end

  defp now, do: DateTime.now!(Application.get_env(:vigil, :tz, "Europe/Berlin"))

  defp format_time(now), do: Calendar.strftime(now, "%H:%M")

  defp first_line(now, active_ids) do
    weekday = elem(@weekdays, Date.day_of_week(now) - 1)
    date = Calendar.strftime(now, "%d.%m.")
    time = format_time(now)

    header = "#{weekday} #{date} #{time}"

    case near_event_summary(now, active_ids) do
      nil -> %{"_" => header}
      summary -> %{"_" => "#{header} | #{summary}"}
    end
  end

  defp near_event_summary(now, _active_ids) do
    summary = Vigil.Store.near_summary(now)

    cond do
      summary.active != [] ->
        event = List.first(summary.active)
        title = Path.basename(event.id, ".md")
        "#{title} noch #{event.ends_in}"

      summary.upcoming != [] ->
        event = List.first(summary.upcoming)
        title = Path.basename(event.id, ".md")
        "#{title} in #{event.starts_in}"

      true ->
        nil
    end
  end

  defp phase_change_text(prev_ids, active_ids) do
    newly_active = MapSet.difference(active_ids, prev_ids) |> MapSet.to_list()
    newly_inactive = MapSet.difference(prev_ids, active_ids) |> MapSet.to_list()

    cond do
      newly_active != [] ->
        path = List.first(newly_active)
        "#{Vigil.Store.file_title(path)} now active"

      newly_inactive != [] ->
        path = List.first(newly_inactive)
        "#{Vigil.Store.file_title(path)} now finished"

      true ->
        "phase changed"
    end
  end
end
