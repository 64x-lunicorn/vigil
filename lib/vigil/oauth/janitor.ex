defmodule Vigil.OAuth.Janitor do
  @moduledoc """
  Wakes on an interval and asks `Vigil.OAuth.Store` to sweep what has expired.

  Both facts it needs are arguments with production defaults: the interval it
  sleeps for and the instant it sweeps against. Baked in, the only way to
  observe a sweep was to wait five minutes.

  The instant arrives as a function rather than a value because the janitor
  outlives any one of them — a fixed instant would be right for the first
  sweep and stale for every one after it.
  """
  use GenServer

  @interval :timer.minutes(5)

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
    Vigil.OAuth.Store.sweep_expired(state.now.())
    schedule(state)
    {:noreply, state}
  end

  defp schedule(state), do: Process.send_after(self(), :sweep, state.interval)
end
