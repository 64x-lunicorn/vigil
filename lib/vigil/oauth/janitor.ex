defmodule Vigil.OAuth.Janitor do
  @moduledoc """
  Wakes on an interval and asks everything that owns a table with an expiry to
  sweep what has expired.

  The list is the janitor's own rather than one module's inventory. While it
  was the OAuth store's in effect, the one swept table that store does not own
  was swept by nobody; `docs/oauth.md` records what that cost.

  Three facts it needs are arguments with production defaults: the interval it
  sleeps for, the instant it sweeps against, and the persistence whose expiries
  it sweeps. The first two baked in, the only way to observe a sweep was to
  wait five minutes; the third baked in, a sweep could only ever be observed
  against the one globally registered `:dets` store.

  The instant arrives as a function rather than a value because the janitor
  outlives any one of them — a fixed instant would be right for the first
  sweep and stale for every one after it.
  """
  use GenServer

  alias Vigil.OAuth.Store
  alias Vigil.RateLimit

  @interval :timer.minutes(5)

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    state = %{
      interval: Keyword.get(opts, :interval, @interval),
      now: Keyword.get(opts, :now, fn -> System.system_time(:second) end),
      persistence: Keyword.get_lazy(opts, :persistence, &Store.over_tables/0)
    }

    schedule(state)
    {:ok, state}
  end

  @impl true
  def handle_info(:sweep, state) do
    now = state.now.()
    Enum.each(sweeps(state), & &1.(now))
    schedule(state)
    {:noreply, state}
  end

  # Each takes the instant to sweep against. OAuth persistence sweeps four
  # tables of its own through the value the janitor was handed;
  # `Vigil.RateLimit` owns its one and is named here, which is the whole point
  # of this list belonging to the janitor.
  defp sweeps(state), do: [state.persistence.sweep_expired, &RateLimit.sweep_expired/1]

  defp schedule(state), do: Process.send_after(self(), :sweep, state.interval)
end
