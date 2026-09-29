defmodule Vigil.MCP.ServerTest do
  # async: true, and what made it possible is the OAuth fixture. This file used
  # to start `Vigil.OAuth.Store` against a temp state dir just to hold a
  # token; it asks an in-memory persistence of its own now, handed to the
  # router at init like any other caller.
  #
  # The writer is this file's own now, under a name it supplies and hands to
  # the router — which threads it to both halves of a response, the tool call
  # and the envelope that wraps it. The session table is the same: a name of
  # this file's own. The limiter is the test's own too, counting in a process
  # rather than in the node's one table — `Vigil.RateLimitTest` is the only
  # file that starts that, and it is async because it is the only one.
  use ExUnit.Case, async: true
  import Plug.Conn
  import Plug.Test

  alias Vigil.RateLimit
  alias Vigil.Store
  alias Vigil.MCP.Server
  alias Vigil.MCP.Session
  alias Vigil.MCP.Tools
  alias Vigil.OAuth

  # One writer and one session table for this file, under names of their own
  # rather than the registrations production uses.
  @store __MODULE__.Writer
  @sessions __MODULE__.Sessions

  @initialize %{
    jsonrpc: "2.0",
    id: 1,
    method: "initialize",
    params: %{protocolVersion: "2025-11-25"}
  }

  setup do
    vault = Vigil.FixtureVault.build()
    on_exit(fn -> Vigil.FixtureVault.cleanup(vault) end)

    start_supervised!(
      {Store,
       vault_path: vault,
       exclude: [],
       git_remote: "origin",
       git: Vigil.Git.CommitLog.new(vault),
       name: @store}
    )

    start_supervised!({Vigil.MCP.Envelope, name: @sessions})

    oauth = Vigil.OAuthCase.setup!()

    %{vault: vault, token: seed_token(oauth), oauth: oauth, persistence: oauth.persistence}
  end

  # A real access token, minted by the module that owns the record. The tests
  # that hand-write one below do it on purpose: those are the shapes `/mcp`
  # has to refuse, and no minting path produces them.
  defp seed_token(oauth, scope \\ OAuth.scope()) do
    OAuth.Token.issue_out_of_band(
      oauth.persistence,
      oauth.resource,
      scope,
      3600,
      System.system_time(:second)
    )
  end

  # `/mcp` verifies against whatever the authorization server was initialized
  # with, so handing the router this test's persistence is all it takes for
  # the token minted above to be the token verified here.
  # The limiter defaults to counting state this router alone holds, so a test
  # that is not about rate limiting cannot spend a budget another test is
  # counting in, and nothing here needs the node's one table. A test that *is*
  # about rate limiting names one instead, and every request in it is counted
  # against the same windows.
  defp opts(persistence, extra \\ []) do
    {limiter, extra} = Keyword.pop_lazy(extra, :limiter, &RateLimit.Counter.new/0)

    Server.init(
      Keyword.merge(
        [
          store: @store,
          sessions: @sessions,
          oauth: OAuth.Endpoint.init(persistence: persistence, limiter: limiter)
        ],
        extra
      )
    )
  end

  # The SkillKey the router under test gates on. This file hands the router no
  # settings, so it resolves the deployment's — and a token signed with any
  # other key would be refused by the gate rather than by the assertion.
  defp deployment_key, do: Vigil.SkillKey.key(Vigil.Settings.from_env())

  # A session is issued at `initialize` and bound to the token that asked for
  # it, so an `mcp-session-id` a test names is a name, not an id: the first
  # request under it initializes a session for that token, and every later one
  # carries the id that came back. `raw_post/4` sends headers as they are, for
  # the tests about ids nobody issued.
  defp post(persistence, token, body, headers \\ []) do
    raw_post(persistence, token, body, Enum.map(headers, &issued(persistence, token, &1)))
  end

  defp issued(persistence, token, {"mcp-session-id", name}),
    do: {"mcp-session-id", session(persistence, token, name)}

  defp issued(_persistence, _token, header), do: header

  defp session(persistence, token, name) do
    case Process.get({:session, token, name}) do
      nil ->
        id = initialize!(persistence, token)
        Process.put({:session, token, name}, id)
        id

      id ->
        id
    end
  end

  defp initialize!(persistence, token) do
    conn = raw_post(persistence, token, @initialize)
    assert conn.status == 200
    [id] = get_resp_header(conn, "mcp-session-id")
    id
  end

  defp raw_post(persistence, token, body, headers \\ []) do
    conn =
      conn(:post, "/mcp", Jason.encode!(body))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer #{token}")

    conn = Enum.reduce(headers, conn, fn {k, v}, c -> put_req_header(c, k, v) end)
    Server.call(conn, opts(persistence))
  end

  # Verification and minting are the same store by construction, not two
  # resolutions that happen to agree: the router reads persistence back out of
  # the authorization server's own options, including when those are handed in
  # ready-made. The limiter is read back the same way, so `/mcp` and the
  # authorization server count in the same windows.
  test "the router's persistence and limiter are the authorization server's", %{
    persistence: persistence
  } do
    limiter = RateLimit.Counter.new()

    handed_in =
      Server.init(oauth: OAuth.Endpoint.init(persistence: persistence, limiter: limiter))

    assert handed_in[:persistence] == persistence
    assert handed_in[:oauth][:persistence] == persistence
    assert handed_in[:limiter] == limiter
    assert handed_in[:oauth][:limiter] == limiter

    # And with nothing handed in, both halves reach production's adapters.
    default = Server.init([])

    assert default[:persistence] == OAuth.Store.over_tables()
    assert default[:oauth][:persistence] == default[:persistence]
    assert default[:limiter] == RateLimit.over_table()
    assert default[:oauth][:limiter] == default[:limiter]
  end

  # The writer and the session table are the router's too: both halves of a
  # response are decided against the ones it was handed, and neither half
  # keeps a default of its own to fall back to.
  test "the router names the writer and the session table" do
    default = Server.init([])

    assert default[:store] == Store.default_name()
    assert default[:sessions] == Vigil.MCP.Envelope.default_name()
  end

  test "request without a token gets 401 with a WWW-Authenticate challenge", %{
    persistence: persistence
  } do
    conn =
      conn(:post, "/mcp", Jason.encode!(%{jsonrpc: "2.0", id: 1, method: "ping"}))
      |> put_req_header("content-type", "application/json")

    conn = Server.call(conn, opts(persistence))
    assert conn.status == 401
    assert conn.resp_body == ""
    [challenge] = get_resp_header(conn, "www-authenticate")
    assert challenge =~ "resource_metadata="
    assert challenge =~ "scope=\"vault\""
  end

  test "request with an unknown token gets 401", %{persistence: persistence, token: token} do
    conn =
      conn(:post, "/mcp", Jason.encode!(%{jsonrpc: "2.0", id: 1, method: "ping"}))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer wrong#{token}")

    conn = Server.call(conn, opts(persistence))
    assert conn.status == 401
  end

  # RFC 6750 §3.1: a request that presented a token is told it was not
  # accepted; one that presented none gets the bare challenge.
  test "a presented but invalid token's challenge says invalid_token", %{
    persistence: persistence,
    token: token
  } do
    presented = auth_post(persistence, "Bearer wrong#{token}")
    assert presented.status == 401
    assert [challenge] = get_resp_header(presented, "www-authenticate")
    assert challenge =~ ~r/^Bearer error="invalid_token", /
    assert challenge =~ "resource_metadata="

    for header <- [nil, "Basic #{token}", "Bearer "] do
      conn = auth_post(persistence, header)
      assert conn.status == 401
      assert [challenge] = get_resp_header(conn, "www-authenticate")
      refute challenge =~ "error="
    end
  end

  test "the Bearer scheme is matched case-insensitively", %{
    persistence: persistence,
    token: token
  } do
    for scheme <- ["bearer", "BEARER", "BeArEr"] do
      conn = auth_post(persistence, "#{scheme} #{token}", @initialize)
      assert conn.status == 200
    end
  end

  defp auth_post(persistence, authorization, body \\ %{jsonrpc: "2.0", id: 1, method: "ping"}) do
    conn =
      conn(:post, "/mcp", Jason.encode!(body))
      |> put_req_header("content-type", "application/json")

    conn =
      if authorization, do: put_req_header(conn, "authorization", authorization), else: conn

    Server.call(conn, opts(persistence))
  end

  test "GET and every other unsupported method on /mcp is a 405 naming what is allowed", %{
    persistence: persistence,
    token: token
  } do
    for method <- [:get, :put, :patch] do
      conn =
        conn(method, "/mcp")
        |> put_req_header("authorization", "Bearer #{token}")
        |> Server.call(opts(persistence))

      assert conn.status == 405
      assert get_resp_header(conn, "allow") == ["POST, DELETE"]
    end
  end

  test "initialize returns instructions and a session id header", %{
    persistence: persistence,
    token: token
  } do
    conn =
      post(persistence, token, %{
        jsonrpc: "2.0",
        id: 1,
        method: "initialize",
        params: %{protocolVersion: "2025-11-25"}
      })

    assert conn.status == 200
    [session_id] = get_resp_header(conn, "mcp-session-id")
    assert session_id != ""

    body = Jason.decode!(conn.resp_body)
    assert body["result"]["instructions"] =~ "Voice:"
    assert body["result"]["protocolVersion"] == "2025-11-25"

    server_info = body["result"]["serverInfo"]
    assert server_info["name"] == "vigil"
    assert server_info["title"] == "Vigil"
    assert server_info["websiteUrl"] == "https://github.com/64x-lunicorn/vigil"
  end

  test "unknown method returns JSON-RPC -32601", %{persistence: persistence, token: token} do
    conn =
      post(persistence, token, %{jsonrpc: "2.0", id: 7, method: "resources/list"}, [
        {"mcp-session-id", "abc"}
      ])

    body = Jason.decode!(conn.resp_body)
    assert body["error"]["code"] == -32601
  end

  # A body that parses but is not one request object used to crash the
  # handler into a 500. Each is a protocol error with an answer.
  test "a batch or a scalar body is an Invalid Request", %{
    persistence: persistence,
    token: token
  } do
    for body <- [[%{jsonrpc: "2.0", id: 1, method: "ping"}], 42, "ping"] do
      conn = post(persistence, token, body, [{"mcp-session-id", "abc"}])

      assert conn.status == 200
      assert Jason.decode!(conn.resp_body)["error"]["code"] == -32600
    end
  end

  describe "protocol versions" do
    defp initialize_with(persistence, token, version) do
      raw_post(persistence, token, %{
        jsonrpc: "2.0",
        id: 1,
        method: "initialize",
        params: %{protocolVersion: version}
      })
    end

    defp negotiated(conn), do: Jason.decode!(conn.resp_body)["result"]["protocolVersion"]

    defp ping_with(persistence, token, session_id, headers) do
      raw_post(
        persistence,
        token,
        %{jsonrpc: "2.0", id: 2, method: "ping"},
        [{"mcp-session-id", session_id} | headers]
      )
    end

    test "each supported version is answered with itself", %{
      persistence: persistence,
      token: token
    } do
      for version <- ["2025-11-25", "2025-06-18", "2025-03-26"] do
        conn = initialize_with(persistence, token, version)
        assert conn.status == 200
        assert negotiated(conn) == version
      end
    end

    test "an unsupported or missing version is answered with the latest", %{
      persistence: persistence,
      token: token
    } do
      for version <- ["2024-11-05", "2099-01-01", 42, nil] do
        assert negotiated(initialize_with(persistence, token, version)) == "2025-11-25"
      end
    end

    test "later requests carry the negotiated version, or none", %{
      persistence: persistence,
      token: token
    } do
      for version <- ["2025-11-25", "2025-06-18", "2025-03-26"] do
        [session_id] =
          get_resp_header(initialize_with(persistence, token, version), "mcp-session-id")

        assert ping_with(persistence, token, session_id, [{"mcp-protocol-version", version}]).status ==
                 200

        assert ping_with(persistence, token, session_id, []).status == 200
      end
    end

    test "a supported version other than the session's is a 400", %{
      persistence: persistence,
      token: token
    } do
      [session_id] =
        get_resp_header(initialize_with(persistence, token, "2025-06-18"), "mcp-session-id")

      conn = ping_with(persistence, token, session_id, [{"mcp-protocol-version", "2025-11-25"}])
      assert conn.status == 400
    end

    test "a version this server does not speak is a 400", %{
      persistence: persistence,
      token: token
    } do
      [session_id] =
        get_resp_header(initialize_with(persistence, token, "2025-11-25"), "mcp-session-id")

      conn = ping_with(persistence, token, session_id, [{"mcp-protocol-version", "2024-11-05"}])
      assert conn.status == 400
    end
  end

  describe "messages without a method" do
    test "a response the client posts is accepted with 202", %{
      persistence: persistence,
      token: token
    } do
      for message <- [
            %{jsonrpc: "2.0", id: 5, result: %{}},
            %{jsonrpc: "2.0", id: 5, error: %{code: -32601, message: "Method not found"}}
          ] do
        conn = post(persistence, token, message, [{"mcp-session-id", "abc"}])
        assert conn.status == 202
        assert conn.resp_body == ""
      end
    end

    test "an object with neither a method nor a result or error is an Invalid Request", %{
      persistence: persistence,
      token: token
    } do
      for message <- [%{jsonrpc: "2.0", id: 5}, %{jsonrpc: "2.0", id: 5, method: 7}] do
        conn = post(persistence, token, message, [{"mcp-session-id", "abc"}])
        assert conn.status == 200
        body = Jason.decode!(conn.resp_body)
        assert body["id"] == 5
        assert body["error"]["code"] == -32600
      end
    end
  end

  test "tools/call of an unknown tool is Invalid params, with no envelope", %{
    persistence: persistence,
    token: token
  } do
    conn =
      post(
        persistence,
        token,
        %{jsonrpc: "2.0", id: 4, method: "tools/call", params: %{name: "does_not_exist"}},
        [{"mcp-session-id", "abc"}]
      )

    body = Jason.decode!(conn.resp_body)
    assert body["id"] == 4
    assert body["error"]["code"] == -32602
    refute Map.has_key?(body, "result")
  end

  test "tools/call with a name that is not a string is Invalid params, not a 500", %{
    persistence: persistence,
    token: token
  } do
    for name <- [%{"a" => 1}, 42, nil, ["search"]] do
      conn =
        post(
          persistence,
          token,
          %{jsonrpc: "2.0", id: 6, method: "tools/call", params: %{name: name}},
          [{"mcp-session-id", "abc"}]
        )

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["id"] == 6
      assert body["error"]["code"] == -32602
    end
  end

  test "tools/call with params that are not an object is Invalid params", %{
    persistence: persistence,
    token: token
  } do
    conn =
      post(persistence, token, %{jsonrpc: "2.0", id: 3, method: "tools/call", params: [1]}, [
        {"mcp-session-id", "abc"}
      ])

    body = Jason.decode!(conn.resp_body)
    assert body["id"] == 3
    assert body["error"]["code"] == -32602
  end

  test "two protocol-version headers are refused, not crashed on", %{
    persistence: persistence,
    token: token
  } do
    conn =
      conn(:post, "/mcp", Jason.encode!(%{jsonrpc: "2.0", id: 1, method: "ping"}))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer #{token}")
      |> Map.update!(:req_headers, fn headers ->
        headers ++
          [{"mcp-protocol-version", "2025-11-25"}, {"mcp-protocol-version", "2025-06-18"}]
      end)
      |> Server.call(opts(persistence))

    assert conn.status == 400
  end

  test "tools/list contains exactly eighteen tools", %{persistence: persistence, token: token} do
    conn =
      post(persistence, token, %{jsonrpc: "2.0", id: 2, method: "tools/list"}, [
        {"mcp-session-id", "abc"}
      ])

    body = Jason.decode!(conn.resp_body)
    assert length(body["result"]["tools"]) == 18
  end

  # A reader is shown what it may call. Offering it the writes only to refuse
  # every one of them is how users learn to approve without reading.
  test "tools/list for a vault:read token lists no write tool", %{
    persistence: persistence,
    oauth: oauth
  } do
    read_token = seed_token(oauth, OAuth.read_scope())

    conn =
      post(persistence, read_token, %{jsonrpc: "2.0", id: 2, method: "tools/list"}, [
        {"mcp-session-id", "abc"}
      ])

    names = for tool <- Jason.decode!(conn.resp_body)["result"]["tools"], do: tool["name"]

    assert names != []
    assert Enum.filter(names, &Tools.write_tool?/1) == []
    assert "reload" in names
    assert length(names) == length(Tools.definitions(writes: false))
  end

  test "tools/call search returns an envelope alongside the result", %{
    persistence: persistence,
    token: token
  } do
    conn =
      post(
        persistence,
        token,
        %{
          jsonrpc: "2.0",
          id: 3,
          method: "tools/call",
          params: %{name: "search", arguments: %{query: "tires", domain: "bike"}}
        },
        [{"mcp-session-id", "session-a"}]
      )

    body = Jason.decode!(conn.resp_body)
    text = hd(body["result"]["content"])["text"]
    payload = Jason.decode!(text)
    assert is_list(payload["result"])
    assert Map.has_key?(payload, "_")
  end

  # docs/design.md, "Reads see what another clone pushed": a read answered
  # while the vault could not be brought up to date says so beside its
  # result, and `status` says since when and why.
  describe "a remote that cannot be reached" do
    setup %{vault: vault} do
      :ok = stop_supervised(Store)
      git = %{Vigil.Git.CommitLog.new(vault) | fetch: fn _, _, _ -> {:error, "unreachable"} end}

      start_supervised!(
        {Store, vault_path: vault, git: git, name: @store, read_fetch_interval: 60}
      )

      :ok
    end

    defp tool_payload(persistence, token, name, arguments) do
      conn =
        post(
          persistence,
          token,
          %{
            jsonrpc: "2.0",
            id: 3,
            method: "tools/call",
            params: %{name: name, arguments: arguments}
          },
          [{"mcp-session-id", "session-stale"}]
        )

      conn.resp_body
      |> Jason.decode!()
      |> get_in(["result", "content"])
      |> hd()
      |> Map.fetch!("text")
      |> Jason.decode!()
    end

    @tag :capture_log
    test "a read succeeds from the current index, with stale: true beside its result", %{
      persistence: persistence,
      token: token
    } do
      payload = tool_payload(persistence, token, "search", %{query: "tires", domain: "bike"})

      assert [_ | _] = payload["result"]
      assert payload["stale"] == true
    end

    @tag :capture_log
    test "status says since when and why; /healthz leaves out why", %{
      persistence: persistence,
      token: token
    } do
      assert %{"stale" => %{"at" => _, "error" => "unreachable"}} =
               tool_payload(persistence, token, "status", %{})["result"]

      conn =
        conn(:get, "/healthz") |> Map.put(:host, "localhost") |> Server.call(opts(persistence))

      assert conn.status == 200
      assert %{"healthy" => true, "stale" => stale} = Jason.decode!(conn.resp_body)
      assert Map.keys(stale) == ["at"]
    end
  end

  test "a fresh vault's read carries no stale field", %{persistence: persistence, token: token} do
    conn =
      post(
        persistence,
        token,
        %{
          jsonrpc: "2.0",
          id: 3,
          method: "tools/call",
          params: %{name: "search", arguments: %{query: "tires"}}
        },
        [{"mcp-session-id", "session-fresh"}]
      )

    text = conn.resp_body |> Jason.decode!() |> get_in(["result", "content"]) |> hd()
    refute Map.has_key?(Jason.decode!(text["text"]), "stale")
  end

  test "second call in the same session gets the time-only envelope", %{
    persistence: persistence,
    token: token
  } do
    post(
      persistence,
      token,
      %{jsonrpc: "2.0", id: 1, method: "tools/call", params: %{name: "reload", arguments: %{}}},
      [
        {"mcp-session-id", "session-b"}
      ]
    )

    conn =
      post(
        persistence,
        token,
        %{jsonrpc: "2.0", id: 2, method: "tools/call", params: %{name: "reload", arguments: %{}}},
        [
          {"mcp-session-id", "session-b"}
        ]
      )

    body = Jason.decode!(conn.resp_body)
    text = hd(body["result"]["content"])["text"]
    payload = Jason.decode!(text)
    assert Map.has_key?(payload, "_t")
  end

  test "current always gets only the time envelope, even as the first call", %{
    persistence: persistence,
    token: token
  } do
    conn =
      post(
        persistence,
        token,
        %{
          jsonrpc: "2.0",
          id: 1,
          method: "tools/call",
          params: %{name: "current", arguments: %{}}
        },
        [
          {"mcp-session-id", "session-c"}
        ]
      )

    body = Jason.decode!(conn.resp_body)
    payload = Jason.decode!(hd(body["result"]["content"])["text"])
    assert Map.has_key?(payload, "_t")
    refute Map.has_key?(payload, "_")

    conn2 =
      post(
        persistence,
        token,
        %{jsonrpc: "2.0", id: 2, method: "tools/call", params: %{name: "reload", arguments: %{}}},
        [
          {"mcp-session-id", "session-c"}
        ]
      )

    payload2 = Jason.decode!(hd(Jason.decode!(conn2.resp_body)["result"]["content"])["text"])
    assert Map.has_key?(payload2, "_t")
    refute Map.has_key?(payload2, "_")
  end

  # The one tool whose whole job is answering what time it is must not
  # disagree with the envelope above it. Two halves: the call is made at the
  # instant the envelope was decided at — pinned exactly, so it cannot pass by
  # two clock reads happening to land in the same minute — and the response
  # the router assembles carries both readings of that one instant.
  test "current's reported time and its envelope come from the same instant", %{
    persistence: persistence,
    token: token
  } do
    pinned = ~U[2026-07-09 11:20:00Z] |> DateTime.shift_zone!("Europe/Berlin")

    assert {:ok, %{now: reported}} =
             Tools.dispatch(@store, "current", %{}, pinned, deployment_key())

    assert reported == DateTime.to_iso8601(pinned)

    conn =
      post(
        persistence,
        token,
        %{
          jsonrpc: "2.0",
          id: 1,
          method: "tools/call",
          params: %{name: "current", arguments: %{}}
        },
        [{"mcp-session-id", "session-instant"}]
      )

    payload = Jason.decode!(hd(Jason.decode!(conn.resp_body)["result"]["content"])["text"])
    {:ok, utc, offset} = DateTime.from_iso8601(payload["result"]["now"])

    assert payload["_t"] == Calendar.strftime(DateTime.add(utc, offset, :second), "%H:%M")
  end

  test "tool errors set isError and carry the message alongside an envelope", %{
    persistence: persistence,
    token: token
  } do
    conn = failing_create(persistence, token, "session-d", 4)

    body = Jason.decode!(conn.resp_body)
    result = body["result"]
    assert result["isError"] == true

    payload = Jason.decode!(hd(result["content"])["text"])
    assert payload["error"] =~ "already exists"
    assert Map.has_key?(payload, "_")
    refute Map.has_key?(payload, "_t")
  end

  # An error is a response the session made, so it advances the session's
  # envelope state: without that, a session whose first call failed would get
  # the long first-response form all over again on its next one.
  test "a failed first call is not repeated as a first call", %{
    persistence: persistence,
    token: token
  } do
    failing_create(persistence, token, "session-e", 5)

    conn =
      post(
        persistence,
        token,
        %{jsonrpc: "2.0", id: 6, method: "tools/call", params: %{name: "reload", arguments: %{}}},
        [{"mcp-session-id", "session-e"}]
      )

    payload = Jason.decode!(hd(Jason.decode!(conn.resp_body)["result"]["content"])["text"])
    assert Map.has_key?(payload, "_t")
    refute Map.has_key?(payload, "_")
  end

  # A JSON-RPC message whose `arguments` is the wrong container is still a
  # tools/call the session made: it is told what was expected, in a tool error
  # carrying the envelope like every other, for a read and for a write — whose
  # SkillKey gate is the first thing to look inside the arguments.
  test "arguments that are not an object are a tool error with an envelope", %{
    persistence: persistence,
    token: token
  } do
    calls = [{"search", []}, {"search", "tires"}, {"create", 42}]

    for {{name, arguments}, n} <- Enum.with_index(calls) do
      conn =
        post(
          persistence,
          token,
          %{
            jsonrpc: "2.0",
            id: n,
            method: "tools/call",
            params: %{name: name, arguments: arguments}
          },
          [{"mcp-session-id", "session-arguments-#{n}"}]
        )

      assert conn.status == 200
      result = Jason.decode!(conn.resp_body)["result"]
      assert result["isError"] == true

      payload = Jason.decode!(hd(result["content"])["text"])
      assert payload["error"] == "Invalid arguments: expected an object"
      assert Map.has_key?(payload, "_")
    end
  end

  # One byte past what `Plug.Conn.read_body/1` reads in one go, so the body
  # arrives as `{:more, partial, conn}`. It is refused the way a body that
  # could not be read is, rather than raising out of the router.
  test "a body longer than one read is a 400, not a crash", %{
    persistence: persistence,
    token: token
  } do
    conn =
      conn(:post, "/mcp", String.duplicate(" ", 8_000_001))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer #{token}")
      |> Server.call(opts(persistence))

    assert conn.status == 400
    assert conn.resp_body == ""
  end

  defp failing_create(persistence, token, session_id, id) do
    post(
      persistence,
      token,
      %{
        jsonrpc: "2.0",
        id: id,
        method: "tools/call",
        params: %{
          name: "create",
          arguments: %{
            path: "bike/terra-speed.md",
            type: "reference",
            content: "# X\nx",
            skill_key: Vigil.SkillKey.current(deployment_key())
          }
        }
      },
      [{"mcp-session-id", session_id}]
    )
  end

  describe "SkillKey" do
    test "a write tool without skill_key is rejected before reaching the Store", %{
      persistence: persistence,
      token: token,
      vault: vault
    } do
      conn =
        post(
          persistence,
          token,
          %{
            jsonrpc: "2.0",
            id: 5,
            method: "tools/call",
            params: %{
              name: "create",
              arguments: %{path: "bike/new.md", type: "reference", content: "# New\ntext"}
            }
          },
          [{"mcp-session-id", "session-e"}]
        )

      body = Jason.decode!(conn.resp_body)
      result = body["result"]
      assert result["isError"] == true
      assert hd(result["content"])["text"] =~ "SkillKey"
      refute File.exists?(Path.join(vault, "bike/new.md"))
    end

    test "a write tool with a fresh skill_key succeeds", %{
      persistence: persistence,
      token: token,
      vault: vault
    } do
      key = Vigil.SkillKey.current(deployment_key())

      conn =
        post(
          persistence,
          token,
          %{
            jsonrpc: "2.0",
            id: 6,
            method: "tools/call",
            params: %{
              name: "create",
              arguments: %{
                path: "bike/new.md",
                type: "reference",
                content: "# New\ntext",
                skill_key: key
              }
            }
          },
          [{"mcp-session-id", "session-f"}]
        )

      body = Jason.decode!(conn.resp_body)
      result = body["result"]
      refute Map.get(result, "isError")
      assert File.exists?(Path.join(vault, "bike/new.md"))
    end

    test "a skill_key from two hours ago is rejected", %{persistence: persistence, token: token} do
      stale_key =
        Vigil.SkillKey.current(deployment_key(), System.system_time(:second) - 7200)

      conn =
        post(
          persistence,
          token,
          %{
            jsonrpc: "2.0",
            id: 7,
            method: "tools/call",
            params: %{
              name: "create",
              arguments: %{
                path: "bike/new.md",
                type: "reference",
                content: "# New\ntext",
                skill_key: stale_key
              }
            }
          },
          [{"mcp-session-id", "session-g"}]
        )

      body = Jason.decode!(conn.resp_body)
      assert body["result"]["isError"] == true
      assert hd(body["result"]["content"])["text"] =~ "SkillKey"
    end

    test "skill_read prepends the current SkillKey to the content", %{
      persistence: persistence,
      token: token
    } do
      conn =
        post(
          persistence,
          token,
          %{
            jsonrpc: "2.0",
            id: 8,
            method: "tools/call",
            params: %{name: "skill_read", arguments: %{name: "tdd"}}
          },
          [{"mcp-session-id", "session-h"}]
        )

      body = Jason.decode!(conn.resp_body)
      text = hd(body["result"]["content"])["text"]
      payload = Jason.decode!(text)
      assert payload["result"]["content"] =~ "SkillKey: "
    end

    test "delete_note and move_note (AP9a rename) are gated by skill_key, then work", %{
      persistence: persistence,
      token: token,
      vault: vault
    } do
      key = Vigil.SkillKey.current(deployment_key())

      no_key =
        post(
          persistence,
          token,
          %{
            jsonrpc: "2.0",
            id: 9,
            method: "tools/call",
            params: %{
              name: "move_note",
              arguments: %{from: "bike/terra-speed.md", to: "bike/x.md", confirm: true}
            }
          },
          [{"mcp-session-id", "session-i"}]
        )

      assert Jason.decode!(no_key.resp_body)["result"]["isError"] == true

      moved =
        post(
          persistence,
          token,
          %{
            jsonrpc: "2.0",
            id: 10,
            method: "tools/call",
            params: %{
              name: "move_note",
              arguments: %{
                from: "bike/terra-speed.md",
                to: "bike/x.md",
                confirm: true,
                skill_key: key
              }
            }
          },
          [{"mcp-session-id", "session-j"}]
        )

      refute Map.get(Jason.decode!(moved.resp_body)["result"], "isError")
      assert File.exists?(Path.join(vault, "bike/x.md"))

      deleted =
        post(
          persistence,
          token,
          %{
            jsonrpc: "2.0",
            id: 11,
            method: "tools/call",
            params: %{
              name: "delete_note",
              arguments: %{path: "bike/x.md", confirm: true, skill_key: key}
            }
          },
          [{"mcp-session-id", "session-k"}]
        )

      refute Map.get(Jason.decode!(deleted.resp_body)["result"], "isError")
      refute File.exists?(Path.join(vault, "bike/x.md"))
    end

    test "skill_write requires a skill_key; the bootstrap key from a failed skill_read works",
         %{persistence: persistence, token: token} do
      no_key =
        post(
          persistence,
          token,
          %{
            jsonrpc: "2.0",
            id: 12,
            method: "tools/call",
            params: %{
              name: "skill_write",
              arguments: %{name: "neu", content: "---\nname: neu\ndescription: x\n---\n# X"}
            }
          },
          [{"mcp-session-id", "session-l"}]
        )

      assert Jason.decode!(no_key.resp_body)["result"]["isError"] == true

      bootstrap_lookup =
        post(
          persistence,
          token,
          %{
            jsonrpc: "2.0",
            id: 13,
            method: "tools/call",
            params: %{name: "skill_read", arguments: %{name: "does-not-exist"}}
          },
          [{"mcp-session-id", "session-m"}]
        )

      bootstrap_body = Jason.decode!(bootstrap_lookup.resp_body)
      assert bootstrap_body["result"]["isError"] == true
      error_text = hd(bootstrap_body["result"]["content"])["text"]
      assert error_text =~ "SkillKey:"
      [_, bootstrap_key] = Regex.run(~r/SkillKey: ([0-9a-f]+)/, error_text)

      written =
        post(
          persistence,
          token,
          %{
            jsonrpc: "2.0",
            id: 14,
            method: "tools/call",
            params: %{
              name: "skill_write",
              arguments: %{
                name: "neu",
                content: "---\nname: neu\ndescription: x\n---\n# X",
                skill_key: bootstrap_key
              }
            }
          },
          [{"mcp-session-id", "session-n"}]
        )

      refute Map.get(Jason.decode!(written.resp_body)["result"], "isError")
    end
  end

  describe "links" do
    test "a vault:read token can call links without a skill_key", %{
      persistence: persistence,
      oauth: oauth
    } do
      read_token = seed_token(oauth, OAuth.read_scope())

      conn =
        post(
          persistence,
          read_token,
          %{
            jsonrpc: "2.0",
            id: 1,
            method: "tools/call",
            params: %{name: "links", arguments: %{id: "bike/via-carolina.md"}}
          },
          [{"mcp-session-id", "session-links"}]
        )

      body = Jason.decode!(conn.resp_body)
      refute Map.get(body["result"], "isError")
      text = hd(body["result"]["content"])["text"]
      payload = Jason.decode!(text)
      assert payload["result"]["id"] == "bike/via-carolina.md"
      assert is_list(payload["result"]["outgoing"])
      assert is_list(payload["result"]["incoming"])
    end

    test "depth 3 is rejected with isError", %{persistence: persistence, token: token} do
      conn =
        post(
          persistence,
          token,
          %{
            jsonrpc: "2.0",
            id: 1,
            method: "tools/call",
            params: %{name: "links", arguments: %{id: "bike/via-carolina.md", depth: 3}}
          },
          [{"mcp-session-id", "session-links-depth"}]
        )

      body = Jason.decode!(conn.resp_body)
      assert body["result"]["isError"] == true
      assert hd(body["result"]["content"])["text"] =~ "depth"
    end
  end

  describe "read-only scope" do
    test "a vault:read token can search/read/current but not create", %{
      persistence: persistence,
      oauth: oauth
    } do
      read_token = seed_token(oauth, OAuth.read_scope())

      conn =
        post(
          persistence,
          read_token,
          %{
            jsonrpc: "2.0",
            id: 1,
            method: "tools/call",
            params: %{name: "search", arguments: %{query: "tires", domain: "bike"}}
          },
          [{"mcp-session-id", "session-r1"}]
        )

      body = Jason.decode!(conn.resp_body)
      refute Map.get(body["result"], "isError")

      conn2 =
        post(
          persistence,
          read_token,
          %{
            jsonrpc: "2.0",
            id: 2,
            method: "tools/call",
            params: %{
              name: "create",
              arguments: %{path: "bike/new.md", type: "reference", content: "# New\ntext"}
            }
          },
          [{"mcp-session-id", "session-r2"}]
        )

      body2 = Jason.decode!(conn2.resp_body)
      assert body2["result"]["isError"] == true
      assert hd(body2["result"]["content"])["text"] =~ "Read-only token"
    end

    test "a vault:read token cannot call skill_write either", %{
      persistence: persistence,
      oauth: oauth
    } do
      read_token = seed_token(oauth, OAuth.read_scope())

      conn =
        post(
          persistence,
          read_token,
          %{
            jsonrpc: "2.0",
            id: 1,
            method: "tools/call",
            params: %{
              name: "skill_write",
              arguments: %{name: "neu", content: "---\nname: neu\ndescription: x\n---\n# X"}
            }
          },
          [{"mcp-session-id", "session-r3"}]
        )

      body = Jason.decode!(conn.resp_body)
      assert body["result"]["isError"] == true
      assert hd(body["result"]["content"])["text"] =~ "Read-only token"
    end

    # The scope is an allow-list: `vault` writes, and nothing else does. The
    # empty string is what a code consented with `scope=""` used to carry; an
    # unknown scope cannot be minted by the flow, but a record is a record.
    test "a token with any scope other than vault cannot write", %{
      persistence: persistence,
      oauth: oauth
    } do
      for scope <- [OAuth.read_scope(), "", "vault:admin", "VAULT"] do
        token = seed_token(oauth, scope)

        conn =
          post(
            persistence,
            token,
            %{
              jsonrpc: "2.0",
              id: 1,
              method: "tools/call",
              params: %{
                name: "create",
                arguments: %{path: "bike/new.md", type: "reference", content: "# New\ntext"}
              }
            },
            [{"mcp-session-id", "session-scope"}]
          )

        body = Jason.decode!(conn.resp_body)
        assert body["result"]["isError"] == true, "scope #{inspect(scope)} was let write"
        assert hd(body["result"]["content"])["text"] =~ "write access denied"

        listed =
          post(persistence, token, %{jsonrpc: "2.0", id: 2, method: "tools/list"}, [
            {"mcp-session-id", "session-scope"}
          ])

        names = for t <- Jason.decode!(listed.resp_body)["result"]["tools"], do: t["name"]
        assert Enum.filter(names, &Tools.write_tool?/1) == []
      end
    end

    test "a vault:read token can call reload without a skill_key", %{
      persistence: persistence,
      oauth: oauth
    } do
      read_token = seed_token(oauth, OAuth.read_scope())

      conn =
        post(
          persistence,
          read_token,
          %{
            jsonrpc: "2.0",
            id: 1,
            method: "tools/call",
            params: %{name: "reload", arguments: %{}}
          },
          [{"mcp-session-id", "session-r4"}]
        )

      body = Jason.decode!(conn.resp_body)
      refute Map.get(body["result"], "isError")
      text = hd(body["result"]["content"])["text"]
      payload = Jason.decode!(text)
      assert payload["result"]["reloaded"] == true
    end
  end

  describe "sessions" do
    defp ping(persistence, token, session_id) do
      raw_post(persistence, token, %{jsonrpc: "2.0", id: 9, method: "ping"}, [
        {"mcp-session-id", session_id}
      ])
    end

    defp delete(persistence, token, headers) do
      conn(:delete, "/mcp")
      |> put_req_header("authorization", "Bearer #{token}")
      |> then(&Enum.reduce(headers, &1, fn {k, v}, c -> put_req_header(c, k, v) end))
      |> Server.call(opts(persistence))
    end

    test "initialize issues a session the token then works in", %{
      persistence: persistence,
      token: token
    } do
      session_id = initialize!(persistence, token)

      conn = ping(persistence, token, session_id)
      assert conn.status == 200
      assert Jason.decode!(conn.resp_body)["result"] == %{}
    end

    test "a request with no session id is a 400", %{persistence: persistence, token: token} do
      conn = raw_post(persistence, token, %{jsonrpc: "2.0", id: 2, method: "tools/list"})
      assert conn.status == 400
    end

    # 404 is what the transport tells a client to re-initialize on — after a
    # server restart as much as after an id it made up.
    test "an unknown session id gets 404", %{persistence: persistence, token: token} do
      for method <- ["ping", "tools/list", "tools/call", "notifications/initialized"] do
        conn =
          raw_post(
            persistence,
            token,
            %{
              jsonrpc: "2.0",
              id: 1,
              method: method,
              params: %{name: "current", arguments: %{}}
            },
            [{"mcp-session-id", "never-issued"}]
          )

        assert conn.status == 404, method
        assert conn.resp_body == ""
      end
    end

    test "a session id used with a different token gets 404", %{
      persistence: persistence,
      token: token,
      oauth: oauth
    } do
      session_id = initialize!(persistence, token)
      other = seed_token(oauth)

      assert ping(persistence, other, session_id).status == 404
      assert delete(persistence, other, [{"mcp-session-id", session_id}]).status == 404

      # The other token's attempt neither took the session over nor ended it.
      assert ping(persistence, token, session_id).status == 200
    end

    test "an expired session is swept and then gets 404", %{
      persistence: persistence,
      token: token
    } do
      session_id = initialize!(persistence, token)
      later = System.system_time(:second) + Session.lifetime_seconds()

      assert Session.sweep_expired(@sessions, later) == 1
      assert :ets.lookup(@sessions, session_id) == []
      assert ping(persistence, token, session_id).status == 404
    end

    test "DELETE /mcp ends the session with 204, and it then gets 404", %{
      persistence: persistence,
      token: token
    } do
      session_id = initialize!(persistence, token)

      conn = delete(persistence, token, [{"mcp-session-id", session_id}])
      assert conn.status == 204
      assert conn.resp_body == ""

      assert ping(persistence, token, session_id).status == 404
      assert delete(persistence, token, [{"mcp-session-id", session_id}]).status == 404
    end

    test "DELETE /mcp needs a token and a session id", %{persistence: persistence, token: token} do
      no_token = conn(:delete, "/mcp") |> Server.call(opts(persistence))
      assert no_token.status == 401
      assert [_challenge] = get_resp_header(no_token, "www-authenticate")

      assert delete(persistence, token, []).status == 400
    end

    # Only `initialize` adds a row. Before this, every distinct id a client
    # sent was a row of its own, never removed.
    test "the session table stays bounded under rotating ids", %{
      persistence: persistence,
      token: token
    } do
      initialize!(persistence, token)
      size = :ets.info(@sessions, :size)

      for n <- 1..200 do
        call = %{
          jsonrpc: "2.0",
          id: n,
          method: "tools/call",
          params: %{name: "current", arguments: %{}}
        }

        conn = raw_post(persistence, token, call, [{"mcp-session-id", "rotating-#{n}"}])
        assert conn.status == 404
      end

      assert :ets.info(@sessions, :size) == size
    end

    test "the session table keeps the token's digest, never the token", %{
      persistence: persistence,
      token: token
    } do
      session_id = initialize!(persistence, token)
      digest = OAuth.Token.digest(token)

      assert [{^session_id, ^digest, _last_active, _state, _version}] =
               :ets.lookup(@sessions, session_id)

      refute digest == token
    end
  end

  describe "Origin" do
    # The deployment's issuer, which this file's routers resolve because it
    # hands them no settings: its origin is allowed without being listed. The
    # listed ones are handed to the authorization server's options, which is
    # where `/mcp` reads them back from.
    @issuer_origin "https://vault.factory-lab.org"

    defp initialize_from(persistence, token, origin, listed \\ []) do
      origins = Vigil.Origin.allowed(Vigil.Settings.from_env().issuer, listed)

      conn(:post, "/mcp", Jason.encode!(@initialize))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer #{token}")
      |> put_req_header("origin", origin)
      |> Server.call(
        Server.init(
          store: @store,
          sessions: @sessions,
          oauth:
            OAuth.Endpoint.init(
              persistence: persistence,
              limiter: RateLimit.Counter.new(),
              origins: origins
            )
        )
      )
    end

    test "a request with no Origin is answered", %{persistence: persistence, token: token} do
      conn = post(persistence, token, @initialize)
      assert conn.status == 200
    end

    test "a request from the issuer's origin is answered", %{
      persistence: persistence,
      token: token
    } do
      assert initialize_from(persistence, token, @issuer_origin).status == 200
    end

    test "a request from a listed origin is answered", %{persistence: persistence, token: token} do
      assert initialize_from(persistence, token, "https://claude.ai", ["https://claude.ai"]).status ==
               200
    end

    test "a request from any other origin is refused with 403", %{
      persistence: persistence,
      token: token
    } do
      for origin <- ["https://claude.ai", "https://evil.example", "http://127.0.0.1:4000", "null"] do
        conn = initialize_from(persistence, token, origin)
        assert conn.status == 403, origin
        assert conn.resp_body == ""
      end
    end

    test "the refusal comes before authentication and before the body is read", %{
      persistence: persistence
    } do
      conn =
        conn(:post, "/mcp", String.duplicate(" ", 8_000_001))
        |> put_req_header("origin", "https://evil.example")
        |> Server.call(opts(persistence))

      # No token and a body longer than one read: 401 or 400 had either been
      # looked at first.
      assert conn.status == 403
      assert get_resp_header(conn, "www-authenticate") == []
    end

    test "every method on /mcp is checked", %{persistence: persistence} do
      for method <- [:get, :delete] do
        conn =
          conn(method, "/mcp")
          |> put_req_header("origin", "https://evil.example")
          |> Server.call(opts(persistence))

        assert conn.status == 403
      end
    end
  end

  describe "rate limiting (AP-6.3)" do
    # A small explicit budget (rather than the default 60) keeps this an
    # integration test of the wiring — Server.init/1 resolving the budget
    # and handle_mcp/1 enforcing it — without needing dozens of requests;
    # Vigil.RateLimitTest covers the limiter's own behavior directly.
    defp post_with_budget(persistence, limiter, token, body, budget, headers) do
      conn =
        conn(:post, "/mcp", Jason.encode!(body))
        |> put_req_header("content-type", "application/json")
        |> put_req_header("authorization", "Bearer #{token}")

      conn =
        headers
        |> Enum.map(&issued(persistence, token, &1))
        |> Enum.reduce(conn, fn {k, v}, c -> put_req_header(c, k, v) end)

      Server.call(conn, opts(persistence, rate_limit_budget: budget, limiter: limiter))
    end

    test "the (budget+1)th tools/call within a minute is rejected with 429", %{
      persistence: persistence,
      token: token
    } do
      # One set of windows for every request below, so the fourth is counted
      # against the same state as the first.
      limiter = RateLimit.Counter.new()

      for n <- 1..3 do
        conn =
          post_with_budget(
            persistence,
            limiter,
            token,
            %{
              jsonrpc: "2.0",
              id: n,
              method: "tools/call",
              params: %{name: "current", arguments: %{}}
            },
            3,
            [{"mcp-session-id", "session-rl"}]
          )

        assert conn.status == 200
      end

      conn =
        post_with_budget(
          persistence,
          limiter,
          token,
          %{
            jsonrpc: "2.0",
            id: 4,
            method: "tools/call",
            params: %{name: "current", arguments: %{}}
          },
          3,
          [{"mcp-session-id", "session-rl"}]
        )

      assert conn.status == 429
      assert get_resp_header(conn, "retry-after") == ["60"]
    end

    # Each reload pulls and reparses inside the writer, so it has a budget of
    # its own, well below the one every request is counted against. Past it,
    # reload answers a rate-limit error; the session and every other tool go
    # on as before.
    test "reload past its own budget answers a rate-limit error", %{
      persistence: persistence,
      token: token
    } do
      limiter = RateLimit.Counter.new()

      call = fn id, name ->
        conn =
          conn(
            :post,
            "/mcp",
            Jason.encode!(%{
              jsonrpc: "2.0",
              id: id,
              method: "tools/call",
              params: %{name: name, arguments: %{}}
            })
          )
          |> put_req_header("content-type", "application/json")
          |> put_req_header("authorization", "Bearer #{token}")
          |> put_req_header("mcp-session-id", session(persistence, token, "session-reload-rl"))
          |> Server.call(
            opts(persistence,
              rate_limit_budget: 100,
              reload_rate_limit_budget: 2,
              limiter: limiter
            )
          )

        assert conn.status == 200
        Jason.decode!(conn.resp_body)["result"]
      end

      for id <- 1..2 do
        refute Map.get(call.(id, "reload"), "isError")
      end

      limited = call.(3, "reload")
      assert limited["isError"] == true
      assert Jason.decode!(hd(limited["content"])["text"])["error"] =~ "Rate limit"

      refute Map.get(call.(4, "current"), "isError")
    end

    # The limiter's table is a copy of what the server holds like any other,
    # so it counts a token under its digest and never holds the token — in
    # both windows a `reload` is counted in.
    test "a token's requests are counted under its digest", %{
      persistence: persistence,
      token: token
    } do
      test = self()

      limiter =
        RateLimit.new(
          limited?: fn key, _budget, _now ->
            send(test, {:counted, key})
            false
          end,
          sweep_expired: fn _now -> :ok end
        )

      conn =
        post_with_budget(
          persistence,
          limiter,
          token,
          %{
            jsonrpc: "2.0",
            id: 1,
            method: "tools/call",
            params: %{name: "reload", arguments: %{}}
          },
          3,
          [{"mcp-session-id", "session-digest"}]
        )

      assert conn.status == 200
      digest = OAuth.Token.digest(token)
      # Once for the request, once more for `reload`'s own window.
      assert_received {:counted, ^digest}
      assert_received {:counted, {:reload, ^digest}}
      refute_received {:counted, _}
      refute digest == token
    end
  end

  test "an access token with the wrong audience is rejected", %{persistence: persistence} do
    bad_token = OAuth.Token.random()

    persistence.put_token.(bad_token, %{
      aud: "https://andere.tld/mcp",
      expires_at: System.system_time(:second) + 3600
    })

    conn = post(persistence, bad_token, %{jsonrpc: "2.0", id: 1, method: "ping"})
    assert conn.status == 401
  end

  test "a refresh token presented as an access token is rejected", %{
    persistence: persistence,
    oauth: oauth
  } do
    refresh = OAuth.Token.random()

    persistence.put_token.(refresh, %{
      type: :refresh,
      client_id: "abc",
      aud: oauth.resource,
      expires_at: System.system_time(:second) + 3600
    })

    conn = post(persistence, refresh, %{jsonrpc: "2.0", id: 1, method: "ping"})
    assert conn.status == 401
  end

  test "an expired access token is rejected and removed", %{
    persistence: persistence,
    oauth: oauth
  } do
    expired = OAuth.Token.random()

    persistence.put_token.(expired, %{
      aud: oauth.resource,
      expires_at: System.system_time(:second) - 1
    })

    conn = post(persistence, expired, %{jsonrpc: "2.0", id: 1, method: "ping"})
    assert conn.status == 401
    assert persistence.get_token.(expired) == :error
  end

  # The call `dispatch/5` builds is the one frame nothing else looks at:
  # validation runs before it, and the write path's own defenses (Facts,
  # Decision, Plan) all sit after it. Now that it comes from `@tools` rather
  # than from a clause per tool, driving every declared tool once through the
  # MCP surface is what proves each row's `call:` and parameter names are the
  # ones its Store operation actually accepts.
  #
  # The list is checked against `Tools.definitions/0` first, so a tool added to
  # `@tools` without an entry here fails the suite instead of quietly going
  # unexercised.
  # docs/design.md, "The server stays in step with the remote": answered on
  # this host without a token, and to nobody else.
  describe "/healthz" do
    defp healthz(persistence, fun \\ & &1, extra \\ []) do
      conn(:get, "/healthz")
      |> Map.put(:host, "localhost")
      |> fun.()
      |> Server.call(opts(persistence, extra))
    end

    test "answers 200 on loopback without a token, with where the vault stands", %{
      persistence: persistence
    } do
      conn = healthz(persistence)

      assert conn.status == 200

      assert %{
               "healthy" => true,
               "index_loaded" => true,
               "writer_answers" => true,
               "ahead" => 0,
               "behind" => 0,
               "last_push" => nil
             } = Jason.decode!(conn.resp_body)
    end

    test "answers over IPv6 loopback and to 127.0.0.1 by address", %{persistence: persistence} do
      assert healthz(persistence, &%{&1 | remote_ip: {0, 0, 0, 0, 0, 0, 0, 1}, host: "::1"}).status ==
               200

      assert healthz(persistence, &%{&1 | host: "127.0.0.1"}).status == 200
    end

    test "answers 503 when there is no writer to answer", %{persistence: persistence} do
      conn = healthz(persistence, & &1, store: __MODULE__.NoSuchWriter)

      assert conn.status == 503

      assert %{"healthy" => false, "index_loaded" => false, "writer_answers" => false} =
               Jason.decode!(conn.resp_body)
    end

    test "is not there for a peer that is not loopback", %{persistence: persistence} do
      assert healthz(persistence, &%{&1 | remote_ip: {192, 168, 1, 20}}).status == 404
    end

    # The proxy in front is on this host too, so what it forwards arrives from
    # loopback — and says so in a header.
    test "is not there for a request a proxy forwarded", %{persistence: persistence} do
      for header <- ~w(x-forwarded-for cf-connecting-ip forwarded x-real-ip) do
        assert healthz(persistence, &put_req_header(&1, header, "203.0.113.9")).status == 404
      end
    end

    test "is not there for a request that names another host", %{persistence: persistence} do
      assert healthz(persistence, &%{&1 | host: "vault.example.org"}).status == 404
    end

    @tag :capture_log
    test "reports a failed push without git's words", %{persistence: persistence, vault: vault} do
      writer = __MODULE__.FailingPushWriter

      start_supervised!(
        {Store,
         vault_path: vault,
         exclude: [],
         git_remote: "nonexistent-remote",
         git: Vigil.Git.CommitLog.new(vault),
         name: writer},
        id: writer
      )

      {:ok, %{pushed: false}} =
        Store.call(writer, :create, %{
          path: "bike/healthz.md",
          type: "reference",
          content: "# Healthz\ntext",
          force: true
        })

      conn = healthz(persistence, & &1, store: writer)

      assert conn.status == 200
      assert %{"last_push" => last_push} = Jason.decode!(conn.resp_body)
      assert %{"pushed" => false, "at" => _} = last_push
      refute Map.has_key?(last_push, "error")
    end
  end

  describe "dispatch coverage" do
    test "every declared tool is dispatched end to end", %{
      persistence: persistence,
      token: token,
      vault: vault
    } do
      key = Vigil.SkillKey.current(deployment_key())
      calls = dispatch_calls()

      assert MapSet.new(calls, fn {name, _args, _verify} -> name end) ==
               MapSet.new(Tools.definitions(), & &1.name)

      for {{name, args, verify}, index} <- Enum.with_index(calls) do
        args = if Tools.write_tool?(name), do: Map.put(args, :skill_key, key), else: args

        conn =
          post(
            persistence,
            token,
            %{
              jsonrpc: "2.0",
              id: 100 + index,
              method: "tools/call",
              params: %{name: name, arguments: args}
            },
            [{"mcp-session-id", "session-dispatch"}]
          )

        result = Jason.decode!(conn.resp_body)["result"]
        payload = Jason.decode!(hd(result["content"])["text"])

        refute Map.get(result, "isError"), "#{name} returned an error: #{payload["error"]}"
        verify.(%{payload: payload, vault: vault})
      end
    end
  end

  # One `{tool, arguments, verification}` per declared tool, read-only tools
  # first. No verification depends on another entry having run: the two
  # `bike/terra-speed.md` cases name different sections of it, and nothing
  # asserts on a note a later entry rewrites.
  #
  # Three tools carry a pair of same-typed parameters that can be swapped
  # without anything raising, so each is verified where the swap would show:
  # `search` (query/domain) has to find the note the query names inside the
  # domain, `append` (heading/content) has to land its text inside the section
  # the heading names, and `replace_section` (id/content) has to replace the
  # chunk the id names.
  defp dispatch_calls do
    [
      {"search", %{query: "tires", domain: "bike"},
       fn %{payload: payload} ->
         assert Enum.any?(
                  payload["result"],
                  &String.starts_with?(&1["id"], "bike/via-carolina.md")
                )
       end},
      {"read", %{id: "projects/vigil/vigil.md"},
       fn %{payload: payload} -> assert payload["result"]["title"] == "vigil" end},
      {"links", %{id: "bike/via-carolina.md", direction: "out"},
       fn %{payload: payload} -> assert is_list(payload["result"]["outgoing"]) end},
      {"lint", %{},
       fn %{payload: payload} -> assert is_list(payload["result"]["orphaned_links"]) end},
      {"current", %{}, fn %{payload: payload} -> assert is_list(payload["result"]["active"]) end},
      {"reload", %{}, fn %{payload: payload} -> assert payload["result"]["reloaded"] == true end},
      {"status", %{},
       fn %{payload: payload} ->
         assert %{"index_loaded" => true, "writer_answers" => true, "healthy" => true} =
                  payload["result"]
       end},
      {"skill_list", %{},
       fn %{payload: payload} -> assert Enum.any?(payload["result"], &(&1["name"] == "tdd")) end},
      {"skill_read", %{name: "tdd"},
       fn %{payload: payload} -> assert payload["result"]["content"] =~ "# TDD" end},
      {"create",
       %{
         path: "bike/dispatch-created.md",
         type: "reference",
         content: "# Dispatch Created\n\nA note the dispatch table made.\n"
       },
       fn %{vault: vault} ->
         assert File.exists?(Path.join(vault, "bike/dispatch-created.md"))
       end},
      {"append", %{path: "bike/via-carolina.md", heading: "Gear", content: "Extra: repair kit."},
       fn %{vault: vault} ->
         file = File.read!(Path.join(vault, "bike/via-carolina.md"))
         assert section_body(file, "Gear") =~ "Extra: repair kit."
         refute file =~ "## Extra: repair kit."
       end},
      {"replace_section",
       %{id: "bike/terra-speed.md#dimensions", content: "Replaced: 42mm wide."},
       fn %{vault: vault} ->
         file = File.read!(Path.join(vault, "bike/terra-speed.md"))
         assert section_body(file, "Dimensions") =~ "Replaced: 42mm wide."
         refute file =~ "40mm wide"
       end},
      {"rewrite_note",
       %{
         path: "garden/raised-bed.md",
         content: "# Raised Bed\n\n## Levels\nThree levels, south-facing.\n"
       },
       fn %{vault: vault} ->
         assert File.read!(Path.join(vault, "garden/raised-bed.md")) =~ "## Levels"
       end},
      {"delete_section", %{id: "bike/terra-speed.md#gravel-experience"},
       fn %{vault: vault} ->
         refute File.read!(Path.join(vault, "bike/terra-speed.md")) =~ "Gravel Experience"
       end},
      {"update_frontmatter", %{path: "projects/vigil/vigil-mcp-config.md", type: "decision"},
       fn %{vault: vault} ->
         assert File.read!(Path.join(vault, "projects/vigil/vigil-mcp-config.md")) =~
                  "type: decision"
       end},
      {"delete_note", %{path: "journal/2026-07-09.md", confirm: true},
       fn %{vault: vault} -> refute File.exists?(Path.join(vault, "journal/2026-07-09.md")) end},
      {"move_note",
       %{from: "training/note-without-anything.md", to: "training/renamed.md", confirm: true},
       fn %{vault: vault} ->
         assert File.exists?(Path.join(vault, "training/renamed.md"))
         refute File.exists?(Path.join(vault, "training/note-without-anything.md"))
       end},
      {"skill_write",
       %{
         name: "dispatch-skill",
         content:
           "---\nname: dispatch-skill\ndescription: Written by the dispatch table.\n---\n# Dispatch Skill\n"
       },
       fn %{vault: vault} ->
         assert File.exists?(Path.join(vault, "skills/dispatch-skill.md"))
       end}
    ]
  end

  # The body of one `## Heading` section: everything up to the next heading.
  defp section_body(file, heading) do
    [_, rest] = String.split(file, "## " <> heading, parts: 2)
    rest |> String.split(~r/^#/m, parts: 2) |> hd()
  end
end
