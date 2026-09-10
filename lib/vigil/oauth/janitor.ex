defmodule Vigil.OAuth.Janitor do
  @moduledoc """
  Wakes on an interval and asks every module that owns a table with an expiry
  to sweep what has expired.

  The list is the janitor's own rather than one module's inventory. While it
  was `Vigil.OAuth.Store`'s in effect, the one swept table `Store` does not own
  was swept by nobody; `docs/oauth.md` records what that cost.

  Both facts it needs are arguments with production defaults: the interval it
  sleeps for and the instant it sweeps against. Baked in, the only way to
  observe a sweep was to wait five minutes.

  The instant arrives as a function rather than a value because the janitor
  outlives any one of them — a fixed instant would be right for the first
  sweep and stale for every one after it.
  """
  use GenServer

  @interval :timer.minutes(5)

  # Each answers `sweep_expired/1` with the instant to sweep against.
  @sweepers [Vigil.OAuth.Store, Vigil.RateLimit]

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    state = %{
      interval: Keyword.get(opts, :interval, @interval),
      now: Keyword.get(opts, :now, fn -> System.system_time(:second) end)
    }

    schedule(state)
    {:ok, state}
  end

  @impl true
  def handle_info(:sweep, state) do
    now = state.now.()
    Enum.each(@sweepers, & &1.sweep_expired(now))
    schedule(state)
    {:noreply, state}
  end

  defp schedule(state), do: Process.send_after(self(), :sweep, state.interval)
end
