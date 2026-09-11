defmodule Vigil.OAuth.Store do
  @moduledoc """
  The `:dets`/`:ets` adapter behind `Vigil.OAuth.Persistence`: where what the
  authorization server remembers actually lives.

  Three `:dets` files (survive restarts) plus two ephemeral `:ets` tables
  (rate-limit counters, CIMD cache). The process owns the files' lifecycle —
  opened under the state dir at init, `chmod 0600`, closed on terminate — and
  nothing else: `:dets` serializes its own writes, so the questions below are
  answered in the caller's process, with no `GenServer.call` indirection on
  the `/mcp` hot path.

  `over_tables/0` is the adapter, a function here beside the implementation it
  wires rather than closures assembled by a caller. Nothing names the
  functions below any more — not `lib/`, where six modules ask through the
  value they are handed, and not the suite, which asks the same way. The one
  exception is `test/vigil/oauth/persistence_test.exs`, the contract suite,
  which starts this process to run every claim against these tables as well
  as against `Vigil.OAuth.Persistence.Memory`. It is the only test that opens
  a `:dets` file at all.

  Everything below `over_tables/0` is private, the fourteen answers included.
  They are captured from inside this module, so the value is the only way to
  reach them and the sentence above is a fact rather than a convention.
  """
  use GenServer
  require Logger

  alias Vigil.OAuth.{Code, Persistence, Token}

  @clients :oauth_clients
  @codes :oauth_codes
  @tokens :oauth_tokens
  @rate_limits :oauth_rate_limits
  @cimd_cache :oauth_cimd_cache

  # The lockout's budget and window and the cache's hour belong to the
  # contract, not to this adapter: the in-memory one has to measure them the
  # same way for the claims in `test/vigil/oauth/persistence_test.exs` to mean
  # one thing. How they are counted is this adapter's own.
  @rate_limit_window Persistence.rate_limit_window()
  @rate_limit_max_attempts Persistence.rate_limit_max_attempts()
  @cimd_ttl Persistence.cimd_ttl()

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    state_dir = Keyword.fetch!(opts, :state_dir)

    with :ok <- safe_mkdir_p(state_dir),
         :ok <- open_dets_files(state_dir) do
      for name <- [@rate_limits, @cimd_cache] do
        if :ets.whereis(name) == :undefined do
          :ets.new(name, [:set, :named_table, :public])
        end
      end

      {:ok, %{}}
    else
      {:error, reason} ->
        Logger.error("Vigil.OAuth.Store failed to start: #{inspect(reason)}")
        {:stop, {:oauth_store_init_failed, reason}}
    end
  end

  defp safe_mkdir_p(path) do
    case File.mkdir_p(path) do
      :ok -> :ok
      {:error, reason} -> {:error, {:mkdir_failed, path, reason}}
    end
  end

  defp open_dets_files(state_dir) do
    files = [
      {@clients, "oauth_clients.dets"},
      {@codes, "oauth_codes.dets"},
      {@tokens, "oauth_tokens.dets"}
    ]

    Enum.reduce_while(files, :ok, fn {name, filename}, :ok ->
      path = Path.join(state_dir, filename)

      case :dets.open_file(name, file: String.to_charlist(path), type: :set) do
        {:ok, ^name} ->
          File.chmod(path, 0o600)
          {:cont, :ok}

        {:error, reason} ->
          {:halt, {:error, {:dets_open_failed, path, reason}}}
      end
    end)
  end

  @impl true
  def terminate(_reason, _state) do
    for name <- [@clients, @codes, @tokens], do: :dets.close(name)
    :ok
  end

  @doc """
  The production adapter: every question answered against the tables this
  process owns.
  """
  @spec over_tables() :: Persistence.t()
  def over_tables do
    Persistence.new(
      put_client: &put_client/2,
      get_client: &get_client/1,
      put_code: &put_code/2,
      take_code: &take_code/1,
      put_token: &put_token/2,
      get_token: &get_token/1,
      delete_token: &delete_token/1,
      revoke_grant: &revoke_grant/1,
      rate_limited?: &rate_limited?/2,
      record_failure: &record_failure/2,
      reset_rate_limit: &reset_rate_limit/1,
      cimd_cache_get: &cimd_cache_get/2,
      cimd_cache_put: &cimd_cache_put/3,
      sweep_expired: &sweep_expired/1
    )
  end

  ## Clients

  defp put_client(client_id, attrs) do
    :dets.insert(@clients, {client_id, attrs})
    :dets.sync(@clients)
  end

  defp get_client(client_id) do
    case :dets.lookup(@clients, client_id) do
      [{^client_id, attrs}] -> {:ok, attrs}
      [] -> :error
    end
  end

  ## Authorization codes

  defp put_code(code, attrs) do
    :dets.insert(@codes, {code, attrs})
    :dets.sync(@codes)
  end

  # Looks up and immediately deletes a code (one-time use).
  defp take_code(code) do
    case :dets.lookup(@codes, code) do
      [{^code, attrs}] ->
        :dets.delete(@codes, code)
        :dets.sync(@codes)
        {:ok, attrs}

      [] ->
        :error
    end
  end

  ## Tokens (access + refresh share a table)

  defp put_token(token, attrs) do
    :dets.insert(@tokens, {token, attrs})
    :dets.sync(@tokens)
  end

  defp get_token(token) do
    case :dets.lookup(@tokens, token) do
      [{^token, attrs}] -> {:ok, attrs}
      [] -> :error
    end
  end

  defp delete_token(token) do
    :dets.delete(@tokens, token)
    :dets.sync(@tokens)
  end

  # Deletes every token descended from one authorization grant.
  #
  # Keyed on the grant rather than the client on purpose: a client legitimately
  # holds more than one grant over time, and revoking by `client_id` would take
  # down authorizations that have nothing to do with the replay.
  #
  # A `nil` grant revokes nothing — that is what `Vigil.OAuth.Token.grant_of/1`
  # answers for a token written before grants existed, and "every token whose
  # grant is unknown" is not a family.
  defp revoke_grant(nil), do: :ok

  defp revoke_grant(grant_id) do
    Enum.each(all_tokens(), fn {token, attrs} ->
      if Token.grant_of(attrs) == grant_id, do: delete_token(token)
    end)
  end

  ## Rate limiting (consent password attempts, per IP)

  defp rate_limited?(ip, now) do
    case :ets.lookup(@rate_limits, ip) do
      [{^ip, count, window_start}] ->
        count >= @rate_limit_max_attempts and now - window_start <= @rate_limit_window

      [] ->
        false
    end
  end

  defp record_failure(ip, now) do
    case :ets.lookup(@rate_limits, ip) do
      [{^ip, count, window_start}] when now - window_start <= @rate_limit_window ->
        :ets.insert(@rate_limits, {ip, count + 1, window_start})

      _ ->
        :ets.insert(@rate_limits, {ip, 1, now})
    end

    :ok
  end

  defp reset_rate_limit(ip) do
    :ets.delete(@rate_limits, ip)
    :ok
  end

  defp sweep_rate_limits(now) do
    sweep_table(@rate_limits, fn {_ip, _count, window_start} ->
      now - window_start > @rate_limit_window
    end)
  end

  ## CIMD cache (1h TTL, ephemeral)

  defp cimd_cache_get(url, now) do
    case :ets.lookup(@cimd_cache, url) do
      [{^url, doc, expires_at}] when expires_at > now -> {:ok, doc}
      _ -> :error
    end
  end

  defp cimd_cache_put(url, doc, now) do
    :ets.insert(@cimd_cache, {url, doc, now + @cimd_ttl})
    :ok
  end

  # Drops CIMD cache entries whose hour is up.
  #
  # This table is keyed on the `client_id` URL a client supplies, and it is
  # filled from `GET /oauth/authorize`, so it grows on input from outside. Two
  # separate things bound it: `Vigil.OAuth.Endpoint`'s per-address limit bounds
  # the rate at which a caller can add to it, and this sweep bounds the total by
  # dropping what has expired. Neither substitutes for the other.
  defp sweep_cimd_cache(now) do
    sweep_table(@cimd_cache, fn {_url, _doc, expires_at} -> expires_at <= now end)
  end

  # Collect first, delete after: deleting inside the fold would mutate the
  # table being walked.
  defp sweep_table(table, expired?) do
    :ets.foldl(
      fn entry, acc -> if expired?.(entry), do: [elem(entry, 0) | acc], else: acc end,
      [],
      table
    )
    |> Enum.each(&:ets.delete(table, &1))
  end

  ## Janitor sweeps

  defp sweep_expired(now) do
    Enum.each(all_codes(), fn {code, attrs} ->
      if Code.expired?(attrs, now), do: delete_code(code)
    end)

    Enum.each(all_tokens(), fn {token, attrs} ->
      if Token.expired?(attrs, now), do: delete_token(token)
    end)

    sweep_rate_limits(now)
    sweep_cimd_cache(now)
  end

  ## The folds the answers above are built on

  defp all_codes, do: :dets.foldl(fn {code, attrs}, acc -> [{code, attrs} | acc] end, [], @codes)

  defp all_tokens,
    do: :dets.foldl(fn {token, attrs}, acc -> [{token, attrs} | acc] end, [], @tokens)

  defp delete_code(code) do
    :dets.delete(@codes, code)
    :dets.sync(@codes)
  end
end
