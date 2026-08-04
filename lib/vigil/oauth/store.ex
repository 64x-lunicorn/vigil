defmodule Vigil.OAuth.Store do
  @moduledoc """
  Persistence for OAuth clients, authorization codes, and tokens.

  Three `:dets` files (survive restarts) plus two ephemeral `:ets` tables
  (rate-limit counters, CIMD cache). `:dets` serializes its own writes, so
  callers use the module functions directly — no `GenServer.call` indirection
  on the `/mcp` hot path.
  """
  use GenServer
  require Logger

  @clients :oauth_clients
  @codes :oauth_codes
  @tokens :oauth_tokens
  @rate_limits :oauth_rate_limits
  @cimd_cache :oauth_cimd_cache

  @rate_limit_window 900
  @rate_limit_max_attempts 5
  @cimd_ttl 3600

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

  ## Clients

  def put_client(client_id, attrs) do
    :dets.insert(@clients, {client_id, attrs})
    :dets.sync(@clients)
  end

  def get_client(client_id) do
    case :dets.lookup(@clients, client_id) do
      [{^client_id, attrs}] -> {:ok, attrs}
      [] -> :error
    end
  end

  ## Authorization codes

  def put_code(code, attrs) do
    :dets.insert(@codes, {code, attrs})
    :dets.sync(@codes)
  end

  @doc "Looks up and immediately deletes a code (one-time use)."
  def take_code(code) do
    case :dets.lookup(@codes, code) do
      [{^code, attrs}] ->
        :dets.delete(@codes, code)
        :dets.sync(@codes)
        {:ok, attrs}

      [] ->
        :error
    end
  end

  def all_codes, do: :dets.foldl(fn {code, attrs}, acc -> [{code, attrs} | acc] end, [], @codes)

  def delete_code(code) do
    :dets.delete(@codes, code)
    :dets.sync(@codes)
  end

  ## Tokens (access + refresh share a table)

  def put_token(token, attrs) do
    :dets.insert(@tokens, {token, attrs})
    :dets.sync(@tokens)
  end

  def get_token(token) do
    case :dets.lookup(@tokens, token) do
      [{^token, attrs}] -> {:ok, attrs}
      [] -> :error
    end
  end

  def delete_token(token) do
    :dets.delete(@tokens, token)
    :dets.sync(@tokens)
  end

  def all_tokens,
    do: :dets.foldl(fn {token, attrs}, acc -> [{token, attrs} | acc] end, [], @tokens)

  ## Rate limiting (consent password attempts, per IP)

  def rate_limited?(ip, now) do
    case :ets.lookup(@rate_limits, ip) do
      [{^ip, count, window_start}] ->
        count >= @rate_limit_max_attempts and now - window_start <= @rate_limit_window

      [] ->
        false
    end
  end

  def record_failure(ip, now) do
    case :ets.lookup(@rate_limits, ip) do
      [{^ip, count, window_start}] when now - window_start <= @rate_limit_window ->
        :ets.insert(@rate_limits, {ip, count + 1, window_start})

      _ ->
        :ets.insert(@rate_limits, {ip, 1, now})
    end
  end

  def reset_rate_limit(ip), do: :ets.delete(@rate_limits, ip)

  def sweep_rate_limits(now) do
    :ets.foldl(
      fn {ip, _count, window_start}, acc ->
        if now - window_start > @rate_limit_window, do: [ip | acc], else: acc
      end,
      [],
      @rate_limits
    )
    |> Enum.each(&:ets.delete(@rate_limits, &1))
  end

  ## CIMD cache (1h TTL, ephemeral)

  def cimd_cache_get(url, now) do
    case :ets.lookup(@cimd_cache, url) do
      [{^url, doc, expires_at}] when expires_at > now -> {:ok, doc}
      _ -> :error
    end
  end

  def cimd_cache_put(url, doc, now) do
    :ets.insert(@cimd_cache, {url, doc, now + @cimd_ttl})
  end

  ## Janitor sweeps

  def sweep_expired(now) do
    Enum.each(all_codes(), fn {code, attrs} ->
      if attrs.expires_at <= now, do: delete_code(code)
    end)

    Enum.each(all_tokens(), fn {token, attrs} ->
      if attrs.expires_at <= now, do: delete_token(token)
    end)

    sweep_rate_limits(now)
  end
end
