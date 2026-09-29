defmodule Vigil.OAuth.GrantsTest do
  @moduledoc """
  What an operator on the host lists and revokes (`docs/guide.md`, "Revoking
  access"): the grants, the clients, one grant, every grant, a client with its
  grants — and that a revoked grant's tokens are refused where a client would
  present them, at `/mcp` and at `/oauth/token`.

  Grants are made the way production makes them: a code minted through the
  modules that own it and redeemed through `Vigil.OAuth.Flow`, a token seeded
  through `Vigil.OAuth.Token.issue_out_of_band/5`. The persistence is the
  in-memory adapter; that both adapters answer the listing and revoking
  questions alike is `Vigil.OAuth.PersistenceTest`'s.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO
  import Plug.Conn
  import Plug.Test

  alias Vigil.MCP.Server
  alias Vigil.OAuth
  alias Vigil.OAuth.{Client, Flow, Grants, Token}
  alias Vigil.OAuthCase

  @now 1_700_000_000
  @day 86_400

  # The RFC 7636 appendix B verifier: `Vigil.OAuthCase.mint_code/2` issues its
  # codes against the matching challenge.
  @verifier "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"

  setup do
    OAuthCase.setup!()
  end

  # A grant as a client obtains one: a code minted for a registered client and
  # redeemed into a pair. Answers the client's id and the pair.
  defp flow_grant(persistence, now \\ @now) do
    code = OAuthCase.mint_code(persistence, now)
    {:ok, record} = persistence.take_code.(code)
    :ok = persistence.put_code.(code, record)

    {:ok, pair} =
      Flow.grant(persistence, redemption(code, record.client_id), now)

    {record.client_id, pair}
  end

  defp redemption(code, client_id) do
    %{
      "grant_type" => "authorization_code",
      "code" => code,
      "client_id" => client_id,
      "redirect_uri" => OAuthCase.redirect_uri(),
      "code_verifier" => @verifier
    }
  end

  defp grant_of(persistence, token) do
    {:ok, record} = persistence.get_token.(token)
    Token.grant_of(record)
  end

  defp seed(persistence, resource, scope, now \\ @now),
    do: Token.issue_out_of_band(persistence, resource, scope, 90 * @day, now)

  describe "list/2" do
    test "names each grant's id, client, scope, issue and expiry", %{
      persistence: persistence,
      resource: resource
    } do
      {client_id, pair} = flow_grant(persistence, @now)
      seeded = seed(persistence, resource, OAuth.read_scope(), @now + 60)

      assert Grants.list(persistence, @now + 120) == [
               %{
                 grant_id: grant_of(persistence, pair.access_token),
                 client_id: client_id,
                 client_name: "Client",
                 scope: OAuth.scope(),
                 granted_at: @now,
                 expires_at: @now + 30 * @day
               },
               %{
                 grant_id: grant_of(persistence, seeded),
                 client_id: nil,
                 client_name: nil,
                 scope: OAuth.read_scope(),
                 granted_at: @now + 60,
                 expires_at: @now + 60 + 90 * @day
               }
             ]
    end

    test "a rotation keeps the grant and the instant it was granted", %{
      persistence: persistence
    } do
      {client_id, pair} = flow_grant(persistence, @now)

      {:ok, rotated} =
        Flow.grant(
          persistence,
          %{
            "grant_type" => "refresh_token",
            "refresh_token" => pair.refresh_token,
            "client_id" => client_id
          },
          @now + @day
        )

      assert [grant] = Grants.list(persistence, @now + @day)
      assert grant.grant_id == grant_of(persistence, rotated.access_token)
      assert grant.granted_at == @now
      assert grant.expires_at == @now + 31 * @day
    end

    test "an expired grant is not listed", %{persistence: persistence, resource: resource} do
      seed(persistence, resource, OAuth.scope(), @now - 91 * @day)

      assert Grants.list(persistence, @now) == []
    end

    test "tokens from before grants existed are listed together, under none", %{
      persistence: persistence,
      resource: resource
    } do
      for token <- ["legacy-1", "legacy-2"] do
        :ok = persistence.put_token.(token, %{aud: resource, expires_at: @now + 3600})
      end

      assert [%{grant_id: nil, client_id: nil, granted_at: nil, scope: "vault"}] =
               Grants.list(persistence, @now)
    end

    test "the printed list shows every column and no token value", %{
      persistence: persistence,
      resource: resource
    } do
      {client_id, pair} = flow_grant(persistence, @now)
      # A minute later, so the two rows come out in one order: oldest first.
      seeded = seed(persistence, resource, OAuth.read_scope(), @now + 60)

      {:ok, text} = Grants.command(persistence, @now + 60, ["list"])
      [header, flow_row, seeded_row] = String.split(text, "\n")

      assert header =~ ~r/^GRANT\s+CLIENT\s+CLIENT ID\s+SCOPE\s+ISSUED\s+EXPIRES$/

      assert flow_row =~ grant_of(persistence, pair.access_token)
      assert flow_row =~ "Client"
      assert flow_row =~ client_id
      assert flow_row =~ "2023-11-14 22:13Z"
      assert flow_row =~ "2023-12-14 22:13Z"

      assert seeded_row =~ grant_of(persistence, seeded)
      assert seeded_row =~ "(seeded)"
      assert seeded_row =~ "vault:read"

      for token <- [pair.access_token, pair.refresh_token, seeded] do
        refute text =~ token
      end
    end

    test "an empty list says so", %{persistence: persistence} do
      assert Grants.command(persistence, @now, ["list"]) == {:ok, "No live grants."}
    end
  end

  describe "clients/2" do
    test "lists each registered client with the live grants it holds", %{
      persistence: persistence
    } do
      {client_id, _pair} = flow_grant(persistence, @now)
      idle = Client.register(persistence, "Idle", [OAuthCase.redirect_uri()], @now + 10)

      assert [
               %{client_id: ^client_id, name: "Client", issued_at: @now, grants: 1},
               %{client_id: idle_id, name: "Idle", issued_at: issued, grants: 0}
             ] = Grants.clients(persistence, @now)

      assert idle_id == idle.client_id
      assert issued == @now + 10

      {:ok, text} = Grants.command(persistence, @now, ["clients"])
      assert text =~ ~r/^CLIENT ID\s+NAME\s+REGISTERED\s+FIRST CODE\s+GRANTS\n/
      assert text =~ idle.client_id
    end
  end

  describe "revoke/2" do
    test "takes the grant's access and refresh tokens, and no other grant's", %{
      persistence: persistence,
      resource: resource
    } do
      {_client_id, pair} = flow_grant(persistence)
      {_other_client, other} = flow_grant(persistence)
      seeded = seed(persistence, resource, OAuth.scope())

      assert :ok = Grants.revoke(persistence, grant_of(persistence, pair.access_token))

      assert :error = persistence.get_token.(pair.access_token)
      assert :error = persistence.get_token.(pair.refresh_token)
      assert {:ok, _} = persistence.get_token.(other.access_token)
      assert {:ok, _} = persistence.get_token.(seeded)
    end

    test "an unknown grant is reported, not silently revoked", %{persistence: persistence} do
      assert :error = Grants.revoke(persistence, "no-such-grant")

      assert {:error, "no grant no-such-grant" <> _} =
               Grants.command(persistence, @now, ["revoke", "no-such-grant"])
    end
  end

  describe "revoke_all/2" do
    test "takes every token, every unredeemed code, and leaves the clients", %{
      persistence: persistence,
      resource: resource
    } do
      {client_id, pair} = flow_grant(persistence)
      seeded = seed(persistence, resource, OAuth.scope())
      :ok = persistence.put_token.("legacy", %{aud: resource, expires_at: @now + 3600})
      code = OAuthCase.mint_code(persistence, @now)

      assert {:ok, 3} = Grants.revoke_all(persistence, @now)

      for token <- [pair.access_token, pair.refresh_token, seeded, "legacy"] do
        assert :error = persistence.get_token.(token)
      end

      assert :error = persistence.take_code.(code)
      assert {:ok, _} = persistence.get_client.(client_id)
    end
  end

  describe "delete_client/2" do
    test "deletes the client and revokes its grants, and no other client's", %{
      persistence: persistence,
      resource: resource
    } do
      {client_id, pair} = flow_grant(persistence)
      {other_client, other} = flow_grant(persistence)
      seeded = seed(persistence, resource, OAuth.scope())

      assert {:ok, 1} = Grants.delete_client(persistence, client_id)

      assert :error = persistence.get_client.(client_id)
      assert :error = persistence.get_token.(pair.access_token)
      assert :error = persistence.get_token.(pair.refresh_token)
      assert {:ok, _} = persistence.get_client.(other_client)
      assert {:ok, _} = persistence.get_token.(other.refresh_token)
      assert {:ok, _} = persistence.get_token.(seeded)
    end

    # A CIMD client names itself by URL and has no record: deleting it is
    # revoking what it holds.
    test "a client with grants and no record has its grants revoked", %{
      persistence: persistence,
      resource: resource
    } do
      cimd = "https://client.example.org/metadata.json"

      :ok =
        persistence.put_token.("refresh", %{
          type: :refresh,
          grant_id: "grant-cimd",
          client_id: cimd,
          aud: resource,
          scope: OAuth.scope(),
          expires_at: @now + @day
        })

      assert {:ok, 1} = Grants.delete_client(persistence, cimd)
      assert :error = persistence.get_token.("refresh")
    end

    test "an unknown client is reported", %{persistence: persistence} do
      assert :error = Grants.delete_client(persistence, "no-such-client")

      assert {:error, "no client no-such-client" <> _} =
               Grants.command(persistence, @now, ["delete-client", "no-such-client"])
    end
  end

  describe "rpc/3" do
    # The encoding `scripts/grants.sh` sends: every word on a line of its own,
    # base64 over the whole, so no id is ever spliced into evaluated Elixir.
    defp encoded(argv), do: argv |> Enum.map_join(&(&1 <> "\n")) |> Base.encode64()

    test "runs the command the script encoded and prints the answer", %{
      persistence: persistence
    } do
      {_client_id, pair} = flow_grant(persistence)
      grant_id = grant_of(persistence, pair.access_token)

      assert capture_io(fn -> Grants.rpc(persistence, @now, encoded(["list"])) end) =~ grant_id

      assert capture_io(fn -> Grants.rpc(persistence, @now, encoded(["revoke", grant_id])) end) ==
               "Revoked grant #{grant_id}: its access and refresh tokens are refused.\n"

      assert :error = persistence.get_token.(pair.refresh_token)
    end

    test "prints a failure behind error:, which is what the script exits on", %{
      persistence: persistence
    } do
      assert capture_io(fn -> Grants.rpc(persistence, @now, encoded(["revoke", "x"])) end) =~
               ~r/^error: no grant x/

      assert capture_io(fn -> Grants.rpc(persistence, @now, encoded(["bogus"])) end) ==
               "error: unknown command\n"

      assert capture_io(fn -> Grants.rpc(persistence, @now, "not base64!") end) ==
               "error: unknown command\n"
    end

    test "an id the operator types is data, never code", %{persistence: persistence} do
      hostile = ~S|"<>System.halt()<>"|

      assert capture_io(fn -> Grants.rpc(persistence, @now, encoded(["revoke", hostile])) end) ==
               "error: no grant #{hostile} (see the list command)\n"
    end
  end

  ## Where it counts: the endpoints a client presents its tokens to

  describe "a revoked grant, over HTTP" do
    setup %{persistence: persistence} do
      endpoint =
        OAuth.Endpoint.init(
          persistence: persistence,
          limiter: Vigil.RateLimit.Counter.new(),
          client_addr: [header: nil, trusted: []],
          settings: OAuthCase.stated_settings()
        )

      %{endpoint: endpoint}
    end

    defp mcp_status(endpoint, token) do
      conn(:post, "/mcp", Jason.encode!(%{jsonrpc: "2.0", id: 1, method: "ping"}))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer #{token}")
      |> Server.call(Server.init(oauth: endpoint))
      |> Map.fetch!(:status)
    end

    defp refresh_status(endpoint, client_id, refresh_token) do
      conn(
        :post,
        "/oauth/token",
        URI.encode_query(%{
          "grant_type" => "refresh_token",
          "refresh_token" => refresh_token,
          "client_id" => client_id
        })
      )
      |> put_req_header("content-type", "application/x-www-form-urlencoded")
      |> OAuth.Endpoint.call(endpoint)
      |> Map.fetch!(:status)
    end

    test "its tokens are refused at /mcp and /oauth/token at once", %{
      persistence: persistence,
      endpoint: endpoint
    } do
      now = System.system_time(:second)
      {client_id, pair} = flow_grant(persistence, now)
      {other_client, other} = flow_grant(persistence, now)

      assert mcp_status(endpoint, pair.access_token) != 401

      :ok = Grants.revoke(persistence, grant_of(persistence, pair.access_token))

      assert mcp_status(endpoint, pair.access_token) == 401
      assert refresh_status(endpoint, client_id, pair.refresh_token) == 400

      assert mcp_status(endpoint, other.access_token) != 401
      assert refresh_status(endpoint, other_client, other.refresh_token) == 200
    end

    test "after revoke-all nothing is accepted", %{
      persistence: persistence,
      endpoint: endpoint,
      resource: resource
    } do
      now = System.system_time(:second)
      {client_id, pair} = flow_grant(persistence, now)
      seeded = Token.issue_out_of_band(persistence, resource, OAuth.scope(), 90 * @day, now)

      {:ok, 2} = Grants.revoke_all(persistence, now)

      assert mcp_status(endpoint, pair.access_token) == 401
      assert mcp_status(endpoint, seeded) == 401
      assert refresh_status(endpoint, client_id, pair.refresh_token) == 400
    end
  end
end
