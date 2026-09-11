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
  """

  alias Vigil.OAuth.Cimd

  @doc """
  Writes a newly registered client's record and answers it in the shape
  `resolve/4` answers.

  The `client_id` is minted here: a DCR client is identified by what this
  server hands it, unlike a CIMD client, which arrives naming itself.
  """
  def register(persistence, name, redirect_uris, now) do
    client_id = Vigil.Uuid.v4()

    persistence.put_client.(client_id, %{
      name: name,
      redirect_uris: redirect_uris,
      issued_at: now
    })

    %{client_id: client_id, name: name, redirect_uris: redirect_uris}
  end

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
