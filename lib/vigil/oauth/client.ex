defmodule Vigil.OAuth.Client do
  @moduledoc """
  Resolves a `client_id` to `%{client_id:, name:, redirect_uris:}` — either a
  DCR-registered client (looked up in `:dets`) or an `https://` CIMD URL
  (fetched and validated). Returns `{:ok, client}` or `:error`.

  This is the join between the two registration paths: `now` and `net` are
  taken here rather than defaulted away, so a caller that needs to drive a
  CIMD client through a test — including the flow that calls this — can, and
  the production values stay the default for everyone who does not.
  """

  alias Vigil.OAuth.{Store, Cimd}

  def resolve(client_id, now \\ System.system_time(:second), net \\ Cimd.net()) do
    case Store.get_client(client_id) do
      {:ok, attrs} ->
        {:ok, %{client_id: client_id, name: attrs.name, redirect_uris: attrs.redirect_uris}}

      :error ->
        if String.starts_with?(client_id, "https://") do
          Cimd.fetch(client_id, now, net)
        else
          :error
        end
    end
  end
end
