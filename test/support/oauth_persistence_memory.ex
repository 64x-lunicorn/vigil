defmodule Vigil.OAuth.Persistence.Memory do
  @moduledoc """
  A `Vigil.OAuth.Persistence` that remembers in a process instead of on disk —
  the second adapter `docs/design.md`, "OAuth persistence is reached through a
  value", records.

  Five maps behind one `Agent`: the registered clients, the authorization
  codes, the tokens, the failed-password windows per address, and the CIMD
  cache. It touches no filesystem, needs no state dir and registers no name,
  so a test that wants one builds it and is isolated by construction — which
  is what lets the OAuth files run in parallel.

  It is not a reimplementation of `Vigil.OAuth.Store` with different storage.
  The two agree on what a record *is* by asking the same owners — a code's
  expiry is `Vigil.OAuth.Code`'s, a token's expiry and its grant are
  `Vigil.OAuth.Token`'s — and on the lockout's window and the cache's hour by
  reading them off the contract rather than restating them. What is left for
  the two to disagree about is exactly what
  `test/vigil/oauth/persistence_test.exs` runs against both.

  It lives with the tests, like `Vigil.Git.CommitLog` and
  `Vigil.Vault.AbsentFacts`, because only they have a use for it.
  """

  alias Vigil.OAuth.{Code, Persistence, Token}

  @window Persistence.rate_limit_window()
  @max_attempts Persistence.rate_limit_max_attempts()
  @cimd_ttl Persistence.cimd_ttl()

  @empty %{clients: %{}, codes: %{}, tokens: %{}, rate_limits: %{}, cimd_cache: %{}}

  @doc """
  A `Vigil.OAuth.Persistence` over a fresh, empty set of tables, and the agent
  holding them.

  The agent is linked to the process that builds it, so it dies with the test
  and nothing has to tear it down.
  """
  @spec holding() :: {Persistence.t(), pid()}
  def holding do
    {:ok, tables} = Agent.start_link(fn -> @empty end)

    persistence =
      Persistence.new(
        put_client: &put(tables, :clients, &1, &2),
        get_client: &fetch(tables, :clients, &1),
        put_code: &put(tables, :codes, &1, &2),
        take_code: &take(tables, :codes, &1),
        put_token: &put(tables, :tokens, &1, &2),
        get_token: &fetch(tables, :tokens, &1),
        delete_token: &drop(tables, :tokens, &1),
        revoke_grant: &revoke_grant(tables, &1),
        rate_limited?: &rate_limited?(tables, &1, &2),
        record_failure: &record_failure(tables, &1, &2),
        reset_rate_limit: &drop(tables, :rate_limits, &1),
        cimd_cache_get: &cimd_cache_get(tables, &1, &2),
        cimd_cache_put: &cimd_cache_put(tables, &1, &2, &3),
        sweep_expired: &sweep_expired(tables, &1)
      )

    {persistence, tables}
  end

  @doc "As `holding/0`, for a caller with no interest in the agent behind it."
  @spec new() :: Persistence.t()
  def new, do: holding() |> elem(0)

  ## The generic three

  defp put(tables, table, key, attrs) do
    Agent.update(tables, &put_in(&1[table][key], attrs))
  end

  defp fetch(tables, table, key) do
    case Agent.get(tables, & &1[table][key]) do
      nil -> :error
      attrs -> {:ok, attrs}
    end
  end

  defp drop(tables, table, key) do
    Agent.update(tables, &update_in(&1[table], fn rows -> Map.delete(rows, key) end))
  end

  # Reading and deleting in one `get_and_update` rather than a read followed by
  # a write: a code is one-time use, and two callers presenting the same code
  # must not both be handed it.
  defp take(tables, table, key) do
    Agent.get_and_update(tables, fn state ->
      case state[table][key] do
        nil -> {:error, state}
        attrs -> {{:ok, attrs}, update_in(state[table], &Map.delete(&1, key))}
      end
    end)
  end

  ## Tokens

  # A `nil` grant revokes nothing: "every token whose grant is unknown" is not
  # a family. `Vigil.OAuth.Token.grant_of/1` is what says so, here and in the
  # `:dets` adapter alike.
  defp revoke_grant(_tables, nil), do: :ok

  defp revoke_grant(tables, grant_id) do
    Agent.update(tables, fn state ->
      update_in(state.tokens, fn tokens ->
        Map.reject(tokens, fn {_token, attrs} -> Token.grant_of(attrs) == grant_id end)
      end)
    end)
  end

  ## Consent password attempts, per address

  defp rate_limited?(tables, address, now) do
    case Agent.get(tables, & &1.rate_limits[address]) do
      {count, window_start} -> count >= @max_attempts and now - window_start <= @window
      nil -> false
    end
  end

  # A failure inside the open window counts against it; one after it has run
  # out opens a new window rather than extending the old one.
  defp record_failure(tables, address, now) do
    Agent.update(tables, fn state ->
      entry =
        case state.rate_limits[address] do
          {count, window_start} when now - window_start <= @window -> {count + 1, window_start}
          _ -> {1, now}
        end

      put_in(state.rate_limits[address], entry)
    end)
  end

  ## The CIMD cache

  defp cimd_cache_get(tables, url, now) do
    case Agent.get(tables, & &1.cimd_cache[url]) do
      {doc, expires_at} when expires_at > now -> {:ok, doc}
      _ -> :error
    end
  end

  defp cimd_cache_put(tables, url, doc, now) do
    Agent.update(tables, &put_in(&1.cimd_cache[url], {doc, now + @cimd_ttl}))
  end

  ## The sweep

  # Every expiry the contract owns, in one pass. Each record is asked its own
  # owner whether it has expired, exactly as the `:dets` adapter asks.
  defp sweep_expired(tables, now) do
    Agent.update(tables, fn state ->
      state
      |> update_in([:codes], &Map.reject(&1, fn {_k, attrs} -> Code.expired?(attrs, now) end))
      |> update_in([:tokens], &Map.reject(&1, fn {_k, attrs} -> Token.expired?(attrs, now) end))
      |> update_in([:rate_limits], &Map.reject(&1, fn {_k, {_c, at}} -> now - at > @window end))
      |> update_in([:cimd_cache], &Map.reject(&1, fn {_k, {_d, at}} -> at <= now end))
    end)
  end
end
