defmodule Vigil.RateLimit.Counter do
  @moduledoc """
  A `Vigil.RateLimit` that counts in a process instead of in the one table the
  node shares — the second adapter `docs/design.md`, "The rate limiter is
  reached through a value", records.

  One map behind an `Agent`: the key, how many requests it has spent, and the
  instant its window opened. It registers no name and creates no table
  anything else can reach, so a test that wants a limiter builds one and is
  isolated by construction.

  It is not a reimplementation of the ETS adapter with different storage. The
  two agree on how long a window lasts by reading it off the contract rather
  than restating it, and disagree — freely — about what a window is made of
  and how one is reclaimed, which is what leaves
  `test/vigil/rate_limit_test.exs` something to catch.

  It lives with the tests, like `Vigil.Git.CommitLog` and
  `Vigil.OAuth.Persistence.Memory`, because only they have a use for it.
  """

  alias Vigil.RateLimit

  @window_seconds RateLimit.window_seconds()

  @doc """
  A `Vigil.RateLimit` over a fresh, empty set of windows.

  The agent behind it is linked to the process that builds it, so it dies with
  the test and nothing has to tear it down.
  """
  @spec new() :: RateLimit.t()
  def new do
    {:ok, windows} = Agent.start_link(fn -> %{} end)

    RateLimit.new(
      limited?: &limited?(windows, &1, &2, &3),
      sweep_expired: &sweep_expired(windows, &1)
    )
  end

  defp limited?(windows, key, budget, now) do
    Agent.get_and_update(windows, fn counted ->
      case Map.get(counted, key) do
        {count, opened_at} when opened_at >= now - @window_seconds ->
          if count >= budget,
            do: {true, counted},
            else: {false, Map.put(counted, key, {count + 1, opened_at})}

        _ ->
          {false, Map.put(counted, key, {1, now})}
      end
    end)
  end

  defp sweep_expired(windows, now) do
    Agent.get_and_update(windows, fn counted ->
      {elapsed, live} =
        Map.split_with(counted, fn {_key, {_count, opened_at}} ->
          opened_at < now - @window_seconds
        end)

      {map_size(elapsed), live}
    end)
  end
end
