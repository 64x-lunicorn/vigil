defmodule Vigil.OAuth.Client do
  @moduledoc """
  The registered-client record: what registration writes, and what a
  `client_id` resolves to.

  `resolve/4` answers `%{client_id:, name:, redirect_uris:}` — either a
  DCR-registered client (looked up through `Vigil.OAuth.Persistence`) or an
  `https://` CIMD URL (fetched and validated) — as `{:ok, client}` or `:error`.

  `register/4` writes the record `resolve/4` reads. The two used to sit in
  different modules: registration built the map as a literal in
  `Vigil.OAuth.Flow` and this one destructured it, which is one record, two
  places and a round trip. What stays with the flow is the RFC 7591
  registration *response*, which is a protocol shape rather than a record.

  This is also the join between the two registration paths: `persistence`,
  `now` and `net` are taken here rather than defaulted away, so a caller that
  needs to drive a CIMD client through a test — including the flow that calls
  this — can, and the production values for the last two stay the default for
  everyone who does not.

  The table is bounded twice (`docs/oauth.md`, "Client registration"): at
  most `max_clients/0` records are stored, and a client that received no
  code within `unused_ttl/0` of registering is dropped by the janitor's
  sweep. The record says which is which in one field, `first_code_at`: `nil`
  until `authorized/3` records the first code, the instant after.
  """

  require Logger

  alias Vigil.OAuth.{Cimd, Persistence}

  @max_clients 1_000
  @unused_ttl 86_400

  @doc "How many registered clients are stored at most."
  @spec max_clients() :: pos_integer()
  def max_clients, do: @max_clients

  @doc "How long a registered client may wait for its first code, in seconds."
  @spec unused_ttl() :: pos_integer()
  def unused_ttl, do: @unused_ttl

  @doc """
  Writes a newly registered client's record and answers it in the shape
  `resolve/4` answers.

  The `client_id` is minted here: a DCR client is identified by what this
  server hands it, unlike a CIMD client, which arrives naming itself.

  Raises `Vigil.OAuth.Persistence.Unavailable` when the table already holds
  `max_clients/0` records, or when the record could not be stored: a
  `client_id` that was never written is not handed out, and a full table is
  a warning for the operator rather than a row more on the disk that also
  holds the vault.
  """
  def register(persistence, name, redirect_uris, now) do
    stored = persistence.count_clients.()

    if stored >= @max_clients do
      Logger.warning(
        "Vigil.OAuth.Client: registration refused, #{stored} clients stored (cap #{@max_clients})"
      )

      raise Persistence.Unavailable, reason: :client_cap
    end

    client_id = Vigil.Uuid.v4()

    persistence.put_client.(client_id, %{
      name: name,
      redirect_uris: redirect_uris,
      issued_at: now,
      first_code_at: nil
    })
    |> Persistence.stored!()

    %{client_id: client_id, name: name, redirect_uris: redirect_uris}
  end

  @doc """
  Records that `client_id` is being handed a code at `now`, once: the first
  code is what keeps a registered client from being swept as unused.

  A CIMD client has no record here and needs none, and a client whose first
  code is already recorded is left as it is. Raises
  `Vigil.OAuth.Persistence.Unavailable` when the record could not be
  rewritten, so no code is handed to a client the sweep would still take.
  """
  def authorized(persistence, client_id, now) do
    with {:ok, attrs} <- persistence.get_client.(client_id),
         nil <- Map.get(attrs, :first_code_at) do
      persistence.put_client.(client_id, Map.put(attrs, :first_code_at, now))
      |> Persistence.stored!()
    else
      _ -> :ok
    end
  end

  @doc """
  Whether a stored client record is one the sweep drops at `now`: registered
  `unused_ttl/0` ago or longer and never handed a code.

  A record without the `first_code_at` field was written before it existed,
  by a server that did not know which clients had been authorized; it is
  kept rather than guessed at, and gains the field with its next code.
  """
  def unused?(%{first_code_at: nil, issued_at: issued_at}, now),
    do: issued_at + @unused_ttl <= now

  def unused?(_attrs, _now), do: false

  def resolve(persistence, client_id, now \\ System.system_time(:second), net \\ Cimd.net()) do
    case persistence.get_client.(client_id) do
      {:ok, attrs} ->
        {:ok, %{client_id: client_id, name: attrs.name, redirect_uris: attrs.redirect_uris}}

      :error ->
        if String.starts_with?(client_id, "https://") do
          Cimd.fetch(persistence, client_id, now, net)
        else
          :error
        end
    end
  end
end
