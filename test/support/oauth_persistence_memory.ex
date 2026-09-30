defmodule Vigil.OAuth.Persistence.Memory do
  @moduledoc """
  A `Vigil.OAuth.Persistence` that remembers in a process instead of on disk —
  the second adapter `docs/design.md`, "OAuth persistence is reached through a
  value", records.

  Five maps behind one `Agent`: the registered clients, the authorization
  codes, the tokens, the consent attempts per key, and the CIMD
  cache. It touches no filesystem, needs no state dir and registers no name,
  so a test that wants one builds it and is isolated by construction — which
  is what lets the OAuth files run in parallel.

  It is not a reimplementation of `Vigil.OAuth.Store` with different storage.
  The two agree on what a record *is* by asking the same owners — a code's
  expiry is `Vigil.OAuth.Code`'s, a token's expiry and its grant are
  `Vigil.OAuth.Token`'s — and on the cache's hour by reading it off the
  contract rather than restating it. Which clients
  the sweep drops is `Vigil.OAuth.Client`'s, asked the same way. What is left for
  the two to disagree about is exactly what
  `test/vigil/oauth/persistence_test.exs` runs against both.

  It lives with the tests, like `Vigil.Git.CommitLog` and
  `Vigil.Vault.AbsentFacts`, because only they have a use for it.
  """

  alias Vigil.OAuth.{Client, Code, Persistence, Token}

  @cimd_ttl Persistence.cimd_ttl()

  @empty %{clients: %{}, codes: %{}, tokens: %{}, rate_limits: %{}, cimd_cache: %{}}

  @doc """
  A `Vigil.OAuth.Persistence` over a fresh, empty set of tables.

  The agent behind it is linked to the process that builds it, so it dies with
  the test and nothing has to tear it down.
  """
  @spec new() :: Persistence.t()
  def new, do: holding() |> elem(0)

  @doc """
  As `new/0`, and the agent behind it.

  For the one claim the contract cannot express: reclaiming an elapsed lockout
  window or a stale cache entry is invisible through the seam — both already
  read as absent before a sweep runs — so only the tables themselves show
  whether the sweep took them. `count/2` is how that is asked here, and
  `:ets.info/2` is how it is asked of the `:dets` adapter.
  """
  @spec holding() :: {Persistence.t(), pid()}
  def holding do
    {:ok, tables} = Agent.start_link(fn -> @empty end)

    persistence =
      Persistence.new(
        put_client: &put(tables, :clients, &1, &2),
        get_client: &fetch(tables, :clients, &1),
        count_clients: fn -> count(tables, :clients) end,
        list_clients: fn -> Agent.get(tables, &Map.to_list(&1.clients)) end,
        delete_client: &delete_client(tables, &1),
        # Codes and tokens under their digest, as the `:dets` adapter keeps
        # them: a test that reads this table sees what a backup would.
        put_code: &put(tables, :codes, Token.digest(&1), &2),
        take_code: &take(tables, :codes, Token.digest(&1)),
        put_token: &put(tables, :tokens, Token.digest(&1), &2),
        get_token: &fetch(tables, :tokens, Token.digest(&1)),
        delete_token: &drop(tables, :tokens, Token.digest(&1)),
        revoke_grant: &revoke_grant(tables, &1),
        list_tokens: fn -> Agent.get(tables, &Map.values(&1.tokens)) end,
        revoke_all: fn -> Agent.update(tables, &%{&1 | tokens: %{}, codes: %{}}) end,
        take_attempt: &take_attempt(tables, &1, &2, &3),
        return_attempt: &return_attempt(tables, &1),
        forget_attempts: &drop(tables, :rate_limits, &1),
        cimd_cache_get: &cimd_cache_get(tables, &1, &2),
        cimd_cache_put: &cimd_cache_put(tables, &1, &2, &3),
        sweep_expired: &sweep_expired(tables, &1)
      )

    {persistence, tables}
  end

  @doc "How many rows one of the five tables is holding."
  @spec count(pid(), :clients | :codes | :tokens | :rate_limits | :cimd_cache) ::
          non_neg_integer()
  def count(tables, table), do: Agent.get(tables, &map_size(&1[table]))

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

  ## Clients

  # The client and every code issued to it, in one update: a code left behind
  # would redeem for a client that no longer exists.
  defp delete_client(tables, client_id) do
    Agent.update(tables, fn state ->
      %{
        state
        | clients: Map.delete(state.clients, client_id),
          codes: Map.reject(state.codes, fn {_key, attrs} -> attrs.client_id == client_id end)
      }
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

  ## Consent password attempts

  # `{count, opened_at, window}` per key. Each change is one
  # `get_and_update`, so the agent answers attempts one at a time and no two
  # are handed the same count. An attempt inside the open window counts
  # against it; one after it has run out opens a new window rather than
  # extending the old one.
  defp take_attempt(tables, key, window, now) do
    Agent.get_and_update(tables, fn state ->
      {count, opened_at, length} =
        case state.rate_limits[key] do
          {count, opened_at, length} when now - opened_at <= length ->
            {count + 1, opened_at, length}

          _ ->
            {1, now, window}
        end

      {count, put_in(state.rate_limits[key], {count, opened_at, length})}
    end)
  end

  defp return_attempt(tables, key) do
    Agent.update(tables, fn state ->
      case state.rate_limits[key] do
        {count, opened_at, length} ->
          put_in(state.rate_limits[key], {max(count - 1, 0), opened_at, length})

        nil ->
          state
      end
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
      |> update_in([:clients], &Map.reject(&1, fn {_k, attrs} -> Client.unused?(attrs, now) end))
      |> update_in([:codes], &Map.reject(&1, fn {_k, attrs} -> Code.expired?(attrs, now) end))
      |> update_in([:tokens], &Map.reject(&1, fn {_k, attrs} -> Token.expired?(attrs, now) end))
      |> update_in(
        [:rate_limits],
        &Map.reject(&1, fn {_k, {_c, at, length}} -> now - at > length end)
      )
      |> update_in([:cimd_cache], &Map.reject(&1, fn {_k, {_d, at}} -> at <= now end))
    end)
  end
end
