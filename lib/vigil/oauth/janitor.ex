defmodule Vigil.OAuth.Janitor do
  @moduledoc """
  Wakes on an interval and asks everything that owns a table with an expiry to
  sweep what has expired.

  The list is the janitor's own rather than one module's inventory. While it
  was the OAuth store's in effect, the one swept table that store does not own
  was swept by nobody; `docs/oauth.md` records what that cost.

  Five facts it needs are arguments with production defaults: the interval it
  sleeps for, the instant it sweeps against, the persistence whose expiries it
  sweeps, the rate limiter whose elapsed windows it reclaims, and the name it
  registers under. The first two baked in, the only way to observe a sweep was
  to wait five minutes; the next two baked in, a sweep could only ever be
  observed against the one globally registered `:dets` store and the one
  globally named limiter table.

  The name is the last of them and is an argument for the same reason: a
  janitor registered under this module is the node's one janitor, so two of
  them cannot exist at once and a test that drives one cannot run beside
  anything else that does. `name: nil` starts an unregistered janitor its
  starter reaches by pid, which is what `test/vigil/oauth/janitor_test.exs`
  asks for.

  The instant arrives as a function rather than a value because the janitor
  outlives any one of them — a fixed instant would be right for the first
  sweep and stale for every one after it.
  """
  use GenServer

  alias Vigil.OAuth.Store
  alias Vigil.RateLimit

  @interval :timer.minutes(5)

  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)

    case name do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @impl true
  def init(opts) do
    state = %{
      interval: Keyword.get(opts, :interval, @interval),
      now: Keyword.get(opts, :now, fn -> System.system_time(:second) end),
      persistence: Keyword.get_lazy(opts, :persistence, &Store.over_tables/0),
      limiter: Keyword.get_lazy(opts, :limiter, &RateLimit.over_table/0)
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

  # Each takes the instant to sweep against, and each is asked through a value
  # the janitor was handed: OAuth persistence sweeps four tables of its own,
  # the rate limiter sweeps the one table persistence does not own. The list is
  # the janitor's and names no module — which is the whole point of it
  # belonging to the janitor rather than to either of the two things on it.
  defp sweeps(state), do: [state.persistence.sweep_expired, state.limiter.sweep_expired]

  defp schedule(state), do: Process.send_after(self(), :sweep, state.interval)
end
