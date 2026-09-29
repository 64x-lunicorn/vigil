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

  Codes and tokens are kept under `Vigil.OAuth.Token.digest/1` of their
  value, never the value: `{{:sha256, digest}, attrs}`. Hashing happens here,
  before every write, lookup and delete, so a copy of the state dir holds no
  credential and no caller ever handles a digest. Clients are kept under
  their `client_id`, which is public. State written before that change is
  rekeyed when the tables are opened, in `init/1`.

  Everything below `over_tables/0` is private, the nineteen answers included.
  They are captured from inside this module, so the value is the only way to
  reach them and the sentence above is a fact rather than a convention.
  """
  use GenServer
  require Logger

  alias Vigil.OAuth.{Client, Code, Persistence, Token}

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
         :ok <- open_dets_files(state_dir),
         :ok <- rekey_legacy_rows(state_dir) do
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

  @files [
    {@clients, "oauth_clients.dets"},
    {@codes, "oauth_codes.dets"},
    {@tokens, "oauth_tokens.dets"}
  ]

  defp open_dets_files(state_dir) do
    Enum.reduce_while(@files, :ok, fn {name, filename}, :ok ->
      case open(name, Path.join(state_dir, filename)) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp open(name, path, extra \\ []) do
    case :dets.open_file(name, [file: String.to_charlist(path), type: :set] ++ extra) do
      {:ok, ^name} ->
        File.chmod(path, 0o600)
        :ok

      {:error, reason} ->
        {:error, {:dets_open_failed, path, reason}}
    end
  end

  # State written before hashing keyed each code and token by its raw value, a
  # binary; a digest is `{:sha256, _}`, so the two cannot be mistaken for one
  # another. Every binary key is rehashed in place on boot — the attrs are
  # untouched — which keeps every client connected before the deploy
  # connected: the token it holds is looked up by its digest and found.
  #
  # Deleting a row does not erase it: `:dets` reuses the space without
  # zeroing it, so the old values would still be readable in the file. A table
  # that was rekeyed is therefore rewritten from its live rows alone.
  #
  # Idempotent: the new row goes in before the old one goes out, and a boot
  # interrupted anywhere finds whatever is still binary and writes the same
  # digest again. A boot that cannot write refuses to start rather than serve
  # with credentials still on disk.
  defp rekey_legacy_rows(state_dir) do
    Enum.reduce_while([@codes, @tokens], :ok, fn table, :ok ->
      case rekey(table, for({key, _} = row <- all_rows(table), is_binary(key), do: row)) do
        :unchanged -> {:cont, :ok}
        :ok -> {:cont, rewrite(table, state_dir)}
        {:error, reason} -> {:halt, {:error, {:rekey_failed, table, reason}}}
      end
    end)
  end

  defp rekey(_table, []), do: :unchanged

  defp rekey(table, legacy) do
    with :ok <- :dets.insert(table, for({key, attrs} <- legacy, do: {Token.digest(key), attrs})),
         :ok <- delete_each(table, Enum.map(legacy, &elem(&1, 0))),
         :ok <- :dets.sync(table) do
      # A count, never a key: those keys were bearer credentials.
      Logger.info("Vigil.OAuth.Store: rekeyed #{length(legacy)} #{table} rows to their digests")
    end
  end

  defp delete_each(table, keys) do
    Enum.reduce_while(keys, :ok, fn key, :ok ->
      case :dets.delete(table, key) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  # Writes the table's live rows into a fresh file and moves it over the old
  # one. `repair: :force` would do the same, but announces itself on stdout
  # outside Logger; this says nothing it was not asked to.
  defp rewrite(table, state_dir) do
    {^table, filename} = List.keyfind(@files, table, 0)
    path = Path.join(state_dir, filename)
    fresh = path <> ".rekeyed"
    rows = all_rows(table)

    with :ok <- :dets.close(table),
         :ok <- write_fresh(fresh, rows),
         :ok <- File.rename(fresh, path) do
      open(table, path)
    end
  end

  defp write_fresh(path, rows) do
    File.rm(path)

    with {:ok, fresh} <- :dets.open_file(make_ref(), file: String.to_charlist(path), type: :set) do
      File.chmod(path, 0o600)
      result = :dets.insert(fresh, rows)
      :ok = :dets.close(fresh)
      result
    end
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
      count_clients: &count_clients/0,
      list_clients: &list_clients/0,
      delete_client: &delete_client/1,
      put_code: &put_code/2,
      take_code: &take_code/1,
      put_token: &put_token/2,
      get_token: &get_token/1,
      delete_token: &delete_token/1,
      revoke_grant: &revoke_grant/1,
      list_tokens: &list_tokens/0,
      revoke_all: &revoke_all/0,
      rate_limited?: &rate_limited?/2,
      record_failure: &record_failure/2,
      reset_rate_limit: &reset_rate_limit/1,
      cimd_cache_get: &cimd_cache_get/2,
      cimd_cache_put: &cimd_cache_put/3,
      sweep_expired: &sweep_expired/1
    )
  end

  ## Clients

  defp put_client(client_id, attrs), do: write(@clients, {client_id, attrs})

  defp get_client(client_id) do
    case :dets.lookup(@clients, client_id) do
      [{^client_id, attrs}] -> {:ok, attrs}
      [] -> :error
    end
  end

  defp count_clients, do: :dets.info(@clients, :size)

  defp list_clients, do: all_rows(@clients)

  # The codes first: a code outstanding for a client that is gone would still
  # redeem into a pair, since redemption checks the code, not the client.
  defp delete_client(client_id) do
    Enum.each(all_rows(@codes), fn {key, attrs} ->
      if attrs.client_id == client_id, do: delete_key(@codes, key)
    end)

    delete_key(@clients, client_id)
  end

  ## Authorization codes
  #
  # Kept under `Token.digest/1` of the code, never the code itself — hashed
  # here, before every write, lookup and delete, so no caller holds a digest
  # and no row holds a code.

  defp put_code(code, attrs), do: write(@codes, {Token.digest(code), attrs})

  # Looks up and immediately deletes a code (one-time use).
  defp take_code(code) do
    key = Token.digest(code)

    case :dets.lookup(@codes, key) do
      [{^key, attrs}] ->
        delete_key(@codes, key)
        {:ok, attrs}

      [] ->
        :error
    end
  end

  ## Tokens (access + refresh share a table, keyed by digest like the codes)

  defp put_token(token, attrs), do: write(@tokens, {Token.digest(token), attrs})

  defp get_token(token) do
    key = Token.digest(token)

    case :dets.lookup(@tokens, key) do
      [{^key, attrs}] -> {:ok, attrs}
      [] -> :error
    end
  end

  defp delete_token(token), do: delete_key(@tokens, Token.digest(token))

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
    Enum.each(all_rows(@tokens), fn {key, attrs} ->
      if Token.grant_of(attrs) == grant_id, do: delete_key(@tokens, key)
    end)
  end

  defp list_tokens, do: for({_digest, attrs} <- all_rows(@tokens), do: attrs)

  # Codes too: one minted a moment ago would otherwise redeem into a fresh
  # pair after everything else was revoked.
  defp revoke_all do
    for table <- [@tokens, @codes] do
      :ok = :dets.delete_all_objects(table)
      :ok = :dets.sync(table)
    end

    :ok
  end

  # A write is stored or it is an error: `:dets.insert/2` answers
  # `{:error, reason}` on a full disk or at the size limit, and the answer is
  # handed back rather than dropped, so `Vigil.OAuth.Persistence.stored!/1`
  # can refuse the request instead of handing out a value nobody can look up.
  defp write(table, row) do
    with :ok <- :dets.insert(table, row), do: :dets.sync(table)
  end

  defp delete_key(table, key) do
    :dets.delete(table, key)
    :dets.sync(table)
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
    Enum.each(all_rows(@clients), fn {client_id, attrs} ->
      if Client.unused?(attrs, now), do: delete_key(@clients, client_id)
    end)

    Enum.each(all_rows(@codes), fn {key, attrs} ->
      if Code.expired?(attrs, now), do: delete_key(@codes, key)
    end)

    Enum.each(all_rows(@tokens), fn {key, attrs} ->
      if Token.expired?(attrs, now), do: delete_key(@tokens, key)
    end)

    sweep_rate_limits(now)
    sweep_cimd_cache(now)
  end

  ## The fold the answers above are built on

  # Every row as stored, digest and all: what walks it deletes by the key it
  # found rather than hashing it a second time.
  defp all_rows(table), do: :dets.foldl(fn row, acc -> [row | acc] end, [], table)
end
