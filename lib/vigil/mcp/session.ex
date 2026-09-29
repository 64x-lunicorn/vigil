defmodule Vigil.MCP.Session do
  @moduledoc """
  MCP sessions: issued at `initialize`, bound to the token that initialized
  them, expired after a spell without a request, and ended on `DELETE /mcp`
  (`docs/design.md`, "The time envelope").

  A session is one row of the session table `Vigil.MCP.Envelope` owns —
  `{id, token_digest, last_active, envelope_state}` — and this module is the
  only one that knows its shape. The envelope asks for its state and records
  it through `envelope_state/2` and `put_envelope_state/3`; everything else
  here decides whether a row is a session at all.

  Only `issue/3` adds a row. An id nobody issued, one presented with another
  token, and one past its lifetime are all the same answer — `:error`, which
  the router sends as 404 — and none of them writes anything. That is what
  keeps the table bounded: rows arrive only through `initialize`, which needs
  a valid token and spends its budget, and the janitor's sweep reclaims every
  row whose lifetime has run out.

  The token is kept as the digest the router already counts it under
  (`Vigil.OAuth.Token.digest/1`), never as itself. `now` is Unix seconds and an
  argument, like the rate limiter's, so a test can name the instant rather
  than wait out an hour.
  """

  # One hour without a request, the same as an access token lives: a session
  # is bound to the token that initialized it, so it cannot be used past that
  # token anyway, and a client that refreshes re-initializes.
  @lifetime_seconds 3600

  @doc "How long a session lives without a request, in seconds."
  @spec lifetime_seconds() :: pos_integer()
  def lifetime_seconds, do: @lifetime_seconds

  @doc """
  A new session for the token under `token_digest`, active at `now`. Returns
  its id, which the router sends as `Mcp-Session-Id`.
  """
  @spec issue(atom(), binary(), integer()) :: binary()
  def issue(sessions, token_digest, now) do
    id = Vigil.Uuid.v4()
    :ets.insert(sessions, {id, token_digest, now, nil})
    id
  end

  @doc """
  Whether `id` is a live session of the token under `token_digest` at `now`.
  `:ok` starts its lifetime over; `:error` means it is unknown, another
  token's or expired.
  """
  @spec resume(atom(), binary(), binary(), integer()) :: :ok | :error
  def resume(sessions, id, token_digest, now) do
    if live?(sessions, id, token_digest, now) do
      :ets.update_element(sessions, id, {3, now})
      :ok
    else
      :error
    end
  end

  @doc """
  Ends `id` if it is a live session of the token under `token_digest` at
  `now`; `:error` on the same terms as `resume/4`.
  """
  @spec finish(atom(), binary(), binary(), integer()) :: :ok | :error
  def finish(sessions, id, token_digest, now) do
    if live?(sessions, id, token_digest, now) do
      :ets.delete(sessions, id)
      :ok
    else
      :error
    end
  end

  @doc """
  Drops every session whose lifetime has run out at `now` and answers how many.

  The table is the envelope's process's and is gone while that process
  restarts, and the restart already dropped every session — so no table is
  nothing to reclaim, not an error for the janitor that asked.
  """
  @spec sweep_expired(atom(), integer()) :: non_neg_integer()
  def sweep_expired(sessions, now) do
    case :ets.whereis(sessions) do
      :undefined ->
        0

      table ->
        cutoff = cutoff(now)
        :ets.select_delete(table, [{{:_, :_, :"$1", :_}, [{:"=<", :"$1", cutoff}], [true]}])
    end
  end

  @doc "The envelope's state for session `id`, `nil` while it has none."
  def envelope_state(sessions, id) do
    case :ets.lookup(sessions, id) do
      [{^id, _digest, _last_active, state}] -> state
      [] -> nil
    end
  end

  @doc """
  Records the envelope's state for session `id`. A session ended in the
  meantime stays ended: this updates a row and never adds one.
  """
  def put_envelope_state(sessions, id, state) do
    :ets.update_element(sessions, id, {4, state})
    :ok
  end

  # A session is live while its last request is after the cutoff. `resume/4`
  # and the sweep compare against the same instant, so a row the sweep has not
  # reached yet is refused exactly as one it has — and is dropped on the spot,
  # since the sweep would drop it next anyway. Only the token the session is
  # bound to gets that far: another token's guess leaves the row alone.
  defp live?(sessions, id, token_digest, now) do
    case :ets.lookup(sessions, id) do
      [{^id, ^token_digest, last_active, _state}] ->
        if last_active > cutoff(now) do
          true
        else
          :ets.delete(sessions, id)
          false
        end

      _ ->
        false
    end
  end

  defp cutoff(now), do: now - @lifetime_seconds
end
