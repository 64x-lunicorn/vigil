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
    case :ets.lookup(@table, key) do
      [{^key, count, window_start}] when now - window_start <= @window_seconds ->
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
end
