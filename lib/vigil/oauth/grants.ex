defmodule Vigil.OAuth.Grants do
  @moduledoc """
  What an operator on the host can see of what the authorization server has
  handed out, and take back: the live grants, the registered clients, and
  revocation of one grant, of every grant, or of a client together with its
  grants (`docs/guide.md`, "Revoking access").

  A grant is the unit of revocation (`docs/design.md`, "Security model"). It
  is minted with the authorization code and carried onto every token redeemed
  or rotated from it, so it is what is listed and revoked here, rather than
  tokens: revoking one takes its access and its refresh tokens at once, and
  both are refused from the next request on, at `/mcp` and at
  `/oauth/token` alike, because both look the record up every time.

  A grant is read off the token records that carry it. The client is the one
  its refresh token names — an access token names none, and a token seeded
  out of band has no client at all, which is how a seeded grant is told
  apart. Nothing here holds a token value, and nothing it prints could: the
  store keeps digests, and `list_tokens` hands back the records without them.

  The operator reaches this through `bin/vigil rpc` against the running
  release, never through a second BEAM opening the `:dets` files beside it
  (see `vigil_seed_token` in `scripts/lib.sh` for why). `rpc/3` is the one
  entry point that command evaluates, and `scripts/grants.sh` is what builds
  it.
  """

  alias Vigil.OAuth.{Persistence, Token}

  @type grant :: %{
          grant_id: String.t() | nil,
          client_id: String.t() | nil,
          client_name: String.t() | nil,
          scope: String.t(),
          granted_at: integer() | nil,
          expires_at: integer()
        }

  @doc """
  Every live grant at `now`, oldest first.

  Live means at least one of its tokens can still be used: an expired record
  and a spent refresh token do not keep a grant on the list. A grant expires
  with the last of its tokens, which for a flow's grant is its refresh token.
  Records written before grants existed carry none, and are listed together
  under a `nil` grant — only `revoke_all/2` reaches them.
  """
  @spec list(Persistence.t(), integer()) :: [grant()]
  def list(persistence, now) do
    persistence.list_tokens.()
    |> Enum.reject(&(Token.expired?(&1, now) or Token.classify(&1) == :spent_refresh))
    |> Enum.group_by(&Token.grant_of/1)
    |> Enum.map(fn {grant_id, records} -> grant(persistence, grant_id, records) end)
    |> Enum.sort_by(&{&1.granted_at || 0, &1.grant_id || ""})
  end

  defp grant(persistence, grant_id, records) do
    client_id = Enum.find_value(records, &Map.get(&1, :client_id))

    %{
      grant_id: grant_id,
      client_id: client_id,
      client_name: client_name(persistence, client_id),
      scope: records |> Enum.map(&Token.scope_of/1) |> Enum.uniq() |> Enum.join(" "),
      granted_at:
        records |> Enum.map(&Token.granted_at_of/1) |> Enum.reject(&is_nil/1) |> earliest(),
      expires_at: records |> Enum.map(& &1.expires_at) |> Enum.max()
    }
  end

  defp earliest([]), do: nil
  defp earliest(instants), do: Enum.min(instants)

  # A CIMD client names itself by URL and has no record here, so its name is
  # unknown to this list; its id says who it is.
  defp client_name(_persistence, nil), do: nil

  defp client_name(persistence, client_id) do
    case persistence.get_client.(client_id) do
      {:ok, attrs} -> attrs.name
      :error -> nil
    end
  end

  @doc """
  Every registered client, oldest first, with how many live grants it holds
  at `now`.
  """
  @spec clients(Persistence.t(), integer()) :: [map()]
  def clients(persistence, now) do
    held = list(persistence, now) |> Enum.frequencies_by(& &1.client_id)

    persistence.list_clients.()
    |> Enum.map(fn {client_id, attrs} ->
      %{
        client_id: client_id,
        name: attrs.name,
        issued_at: Map.get(attrs, :issued_at),
        first_code_at: Map.get(attrs, :first_code_at),
        grants: Map.get(held, client_id, 0)
      }
    end)
    |> Enum.sort_by(&{&1.issued_at || 0, &1.client_id})
  end

  @doc """
  Revokes one grant: every access and refresh token descended from it.
  `:error` when no stored token carries it, so a mistyped id is reported
  rather than answered with a revocation that did nothing.
  """
  @spec revoke(Persistence.t(), String.t()) :: :ok | :error
  def revoke(persistence, grant_id) do
    if Enum.any?(persistence.list_tokens.(), &(Token.grant_of(&1) == grant_id)) do
      persistence.revoke_grant.(grant_id)
    else
      :error
    end
  end

  @doc """
  Revokes every grant — every token, and every authorization code not yet
  redeemed — and answers how many live grants there were at `now`. Clients
  stay registered: a registration grants nothing without the consent
  password.
  """
  @spec revoke_all(Persistence.t(), integer()) :: {:ok, non_neg_integer()}
  def revoke_all(persistence, now) do
    live = length(list(persistence, now))
    :ok = persistence.revoke_all.()
    {:ok, live}
  end

  @doc """
  Deletes a client — its record and its outstanding codes — and revokes every
  grant it holds, answering how many that was. A CIMD client has no record
  and is deleted by revoking its grants alone; it comes back, as a
  registered client can register again, only through consent.

  `:error` when there is neither a record nor a grant for `client_id`.
  """
  @spec delete_client(Persistence.t(), String.t()) :: {:ok, non_neg_integer()} | :error
  def delete_client(persistence, client_id) do
    grants =
      for record <- persistence.list_tokens.(),
          Map.get(record, :client_id) == client_id,
          grant_id = Token.grant_of(record),
          uniq: true,
          do: grant_id

    if grants == [] and persistence.get_client.(client_id) == :error do
      :error
    else
      Enum.each(grants, persistence.revoke_grant)
      :ok = persistence.delete_client.(client_id)
      {:ok, length(grants)}
    end
  end

  @doc """
  One operator command, answered as the text to print: `{:ok, text}` or
  `{:error, text}`.

      ["list"]  ["clients"]  ["revoke", grant_id]  ["revoke-all"]
      ["delete-client", client_id]
  """
  @spec command(Persistence.t(), integer(), [String.t()]) :: {:ok | :error, String.t()}
  def command(persistence, now, argv)

  def command(persistence, now, ["list"]) do
    case list(persistence, now) do
      [] -> {:ok, "No live grants."}
      grants -> {:ok, grants_table(grants)}
    end
  end

  def command(persistence, now, ["clients"]) do
    case clients(persistence, now) do
      [] -> {:ok, "No registered clients."}
      clients -> {:ok, clients_table(clients)}
    end
  end

  def command(persistence, _now, ["revoke", grant_id]) do
    case revoke(persistence, grant_id) do
      :ok -> {:ok, "Revoked grant #{grant_id}: its access and refresh tokens are refused."}
      :error -> {:error, "no grant #{grant_id} (see the list command)"}
    end
  end

  def command(persistence, now, ["revoke-all"]) do
    {:ok, count} = revoke_all(persistence, now)
    {:ok, "Revoked every grant (#{count} live) and every unredeemed authorization code."}
  end

  def command(persistence, _now, ["delete-client", client_id]) do
    case delete_client(persistence, client_id) do
      {:ok, count} -> {:ok, "Deleted client #{client_id} and revoked its #{count} grant(s)."}
      :error -> {:error, "no client #{client_id}, and no grant held by one"}
    end
  end

  def command(_persistence, _now, _argv), do: {:error, "unknown command"}

  @doc """
  What `bin/vigil rpc` evaluates: decodes the command `scripts/grants.sh`
  sends — its words base64-encoded, one per line, so no id the operator types
  is ever spliced into the Elixir the node evaluates — runs it, and prints the
  answer. A failure is printed behind `error: `, which is what the script
  reads its exit status from: `rpc` exits 0 on anything that did not raise.
  """
  @spec rpc(Persistence.t(), integer(), String.t()) :: :ok
  def rpc(persistence, now, encoded) do
    argv =
      case Base.decode64(encoded) do
        {:ok, text} -> String.split(text, "\n", trim: true)
        :error -> []
      end

    Vigil.Stdio.utf8()

    case command(persistence, now, argv) do
      {:ok, text} -> IO.puts(text)
      {:error, text} -> IO.puts("error: " <> text)
    end
  end

  ## Printing

  defp grants_table(grants) do
    table(
      ["GRANT", "CLIENT", "CLIENT ID", "SCOPE", "ISSUED", "EXPIRES"],
      for g <- grants do
        [
          g.grant_id || "(none)",
          client_label(g),
          g.client_id || "-",
          g.scope,
          time(g.granted_at),
          time(g.expires_at)
        ]
      end
    )
  end

  defp client_label(%{client_id: nil, grant_id: nil}), do: "-"
  defp client_label(%{client_id: nil}), do: "(seeded)"
  defp client_label(%{client_name: nil}), do: "-"
  defp client_label(%{client_name: name}), do: name

  defp clients_table(clients) do
    table(
      ["CLIENT ID", "NAME", "REGISTERED", "FIRST CODE", "GRANTS"],
      for c <- clients do
        [c.client_id, c.name, time(c.issued_at), time(c.first_code_at), to_string(c.grants)]
      end
    )
  end

  defp time(nil), do: "-"
  defp time(unix), do: unix |> DateTime.from_unix!() |> Calendar.strftime("%Y-%m-%d %H:%MZ")

  # Left-aligned columns two spaces apart; the last one is not padded.
  defp table(header, rows) do
    widths =
      Enum.zip_with([header | rows], fn column ->
        column |> Enum.map(&String.length/1) |> Enum.max()
      end)

    Enum.map_join([header | rows], "\n", fn row ->
      row
      |> Enum.zip(widths)
      |> Enum.map_join("  ", fn {cell, width} -> String.pad_trailing(cell, width) end)
      |> String.trim_trailing()
    end)
  end
end
