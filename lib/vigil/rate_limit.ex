defmodule Vigil.RateLimit do
  @moduledoc """
  One fixed-window rate limit, for every surface that needs one.

  The key is whatever the caller counts by and the budget is the caller's to
  choose, so the same window serves `/mcp` keyed by access token (AP-6.3) and
  the authorization server keyed by client address. Both are defence in depth,
  independent of Cloudflare — not a replacement for it.

  `now` is an argument because a test that cannot name the instant can only
  observe the window by waiting a minute for it.
  """
  use GenServer
  require Logger

  @table :vigil_rate_limits
  @window_seconds 60

  def start_link(_opts \\ []), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @impl true
  def init(_) do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:set, :named_table, :public])
    end

    {:ok, %{}}
  end

  @doc "The window's length in seconds — what a refused caller has to wait out."
  def window_seconds, do: @window_seconds

  @doc """
  The budget configured under `key`, or `default` when what is there is not a
  budget at all.

  Both surfaces take their budget from application config, which means both can
  be handed a mistyped environment variable. Falling back keeps that from
  producing a limit that refuses everything or crashes on the comparison, and
  the warning keeps it from being invisible: a limit that is quietly not the
  one you configured is worse than a loud one.
  """
  def budget(key, default) do
    case Application.get_env(:vigil, key, default) do
      rpm when is_integer(rpm) and rpm > 0 ->
        rpm

      other ->
        Logger.warning("#{key} is #{inspect(other)}, not a positive integer — using #{default}")
        default
    end
  end

  @doc """
  True if `key` has exceeded `budget` requests for the fixed window
  containing `now`; otherwise records the request and returns false.
  """
  def limited?(key, budget, now) do
    cutoff = cutoff(now)

    case :ets.lookup(@table, key) do
      [{^key, count, window_start}] when window_start >= cutoff ->
        if count >= budget do
          true
        else
          :ets.insert(@table, {key, count + 1, window_start})
          false
        end

      _ ->
        :ets.insert(@table, {key, 1, now})
        false
    end
  end

  @doc """
  Drops the windows that have elapsed at `now` and returns how many were
  reclaimed.

  The table is keyed on what arrives from outside — one row per client address
  per authorization-server endpoint, and one per access token ever presented at
  `/mcp`. Refresh rotation mints a new access token about every hour, so even
  normal single-user traffic adds keys for tokens that no longer exist. The
  budget bounds how fast rows arrive and this sweep bounds how many there are;
  neither substitutes for the other.

  Reclaiming is part of the limiter's interface rather than a caller's duty:
  what counts as an elapsed window is the same fact `limited?/3` decides on,
  and only one module should hold it. Only a window `limited?/3` would already
  ignore is dropped, so a sweep can never let a caller past a limit it is still
  subject to — reclaiming an elapsed row and starting a fresh window on the
  next request are the same decision.

  The table belongs to this module's process and is gone while that process is
  restarting, so a sweep can arrive to no table at all. That is not an error to
  report: the restart already dropped every window, so there is nothing left to
  reclaim, and the janitor that asked must not go down over it. `limited?/3`
  deliberately does not do the same: on the request path a missing table means
  the limiter is not running, and crashing the request is the honest answer
  where answering "not limited" would quietly serve every caller unlimited.
  """
  def sweep_expired(now) do
    case :ets.whereis(@table) do
      :undefined ->
        0

      table ->
        cutoff = cutoff(now)
        :ets.select_delete(table, [{{:_, :_, :"$1"}, [{:<, :"$1", cutoff}], [true]}])
    end
  end

  # The one statement of where the current window begins. Both readers of it
  # compare the same stored instant against it, so they cannot drift apart:
  # `limited?/3` counts a window at or after the cutoff, and the sweep reclaims
  # exactly the ones before it.
  defp cutoff(now), do: now - @window_seconds
end
