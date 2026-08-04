defmodule Vigil.MCP.ServerTest do
  use ExUnit.Case, async: false
  use Plug.Test

  alias Vigil.Store
  alias Vigil.MCP.Server
  alias Vigil.OAuth

  setup do
    {vault, _remote} = Vigil.FixtureVault.build(remote: true)
    on_exit(fn -> Vigil.FixtureVault.cleanup(vault) end)
    start_supervised!({Store, vault_path: vault, exclude: [], git_remote: "origin"})
    start_supervised!(Vigil.MCP.Envelope)
    start_supervised!(Vigil.MCP.RateLimit)

    oauth = Vigil.OAuthCase.setup!()

    token = OAuth.Token.random()

    OAuth.Store.put_token(token, %{
      aud: oauth.resource,
      expires_at: System.system_time(:second) + 3600
    })

    %{vault: vault, token: token, oauth: oauth}
  end

  defp post(token, body, headers \\ []) do
    conn =
      conn(:post, "/mcp", Jason.encode!(body))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer #{token}")

    conn = Enum.reduce(headers, conn, fn {k, v}, c -> put_req_header(c, k, v) end)
    Server.call(conn, Server.init([]))
  end

  test "request without a token gets 401 with a WWW-Authenticate challenge" do
    conn =
      conn(:post, "/mcp", Jason.encode!(%{jsonrpc: "2.0", id: 1, method: "ping"}))
      |> put_req_header("content-type", "application/json")

    conn = Server.call(conn, Server.init([]))
    assert conn.status == 401
    assert conn.resp_body == ""
    [challenge] = get_resp_header(conn, "www-authenticate")
    assert challenge =~ "resource_metadata="
    assert challenge =~ "scope=\"vault\""
  end

  test "request with an unknown token gets 401", %{token: token} do
    conn =
      conn(:post, "/mcp", Jason.encode!(%{jsonrpc: "2.0", id: 1, method: "ping"}))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer wrong#{token}")

    conn = Server.call(conn, Server.init([]))
    assert conn.status == 401
  end

  test "initialize returns instructions and a session id header", %{token: token} do
    conn =
      post(token, %{
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
  end

  test "unknown method returns JSON-RPC -32601", %{token: token} do
    conn =
      post(token, %{jsonrpc: "2.0", id: 7, method: "resources/list"}, [{"mcp-session-id", "abc"}])

    body = Jason.decode!(conn.resp_body)
    assert body["error"]["code"] == -32601
  end

  test "tools/list contains exactly seventeen tools", %{token: token} do
    conn =
      post(token, %{jsonrpc: "2.0", id: 2, method: "tools/list"}, [{"mcp-session-id", "abc"}])

    body = Jason.decode!(conn.resp_body)
    assert length(body["result"]["tools"]) == 17
  end

  test "tools/call search returns an envelope alongside the result", %{token: token} do
    conn =
      post(
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

  test "second call in the same session gets the time-only envelope", %{token: token} do
    post(
      token,
      %{jsonrpc: "2.0", id: 1, method: "tools/call", params: %{name: "reload", arguments: %{}}},
      [
        {"mcp-session-id", "session-b"}
      ]
    )

    conn =
      post(
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

  test "current always gets only the time envelope, even as the first call", %{token: token} do
    conn =
      post(
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

  test "tool errors set isError and return a plain-text message", %{token: token} do
    key = Vigil.SkillKey.current(Vigil.SkillKey.secret())

    conn =
      post(
        token,
        %{
          jsonrpc: "2.0",
          id: 4,
          method: "tools/call",
          params: %{
            name: "create",
            arguments: %{
              path: "bike/terra-speed.md",
              type: "reference",
              content: "# X\nx",
              skill_key: key
            }
          }
        },
        [{"mcp-session-id", "session-d"}]
      )

    body = Jason.decode!(conn.resp_body)
    result = body["result"]
    assert result["isError"] == true
    assert hd(result["content"])["text"] =~ "already exists"
  end

  describe "SkillKey" do
    test "a write tool without skill_key is rejected before reaching the Store", %{
      token: token,
      vault: vault
    } do
      conn =
        post(
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

    test "a write tool with a fresh skill_key succeeds", %{token: token, vault: vault} do
      key = Vigil.SkillKey.current(Vigil.SkillKey.secret())

      conn =
        post(
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

    test "a skill_key from two hours ago is rejected", %{token: token} do
      stale_key =
        Vigil.SkillKey.current(Vigil.SkillKey.secret(), System.system_time(:second) - 7200)

      conn =
        post(
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

    test "skill_read prepends the current SkillKey to the content", %{token: token} do
      conn =
        post(
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
      token: token,
      vault: vault
    } do
      key = Vigil.SkillKey.current(Vigil.SkillKey.secret())

      no_key =
        post(
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
         %{token: token} do
      no_key =
        post(
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
    test "a vault:read token can call links without a skill_key", %{oauth: oauth} do
      read_token = OAuth.Token.random()

      OAuth.Store.put_token(read_token, %{
        aud: oauth.resource,
        scope: "vault:read",
        expires_at: System.system_time(:second) + 3600
      })

      conn =
        post(
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

    test "depth 3 is rejected with isError", %{token: token} do
      conn =
        post(
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
    test "a vault:read token can search/read/current but not create", %{oauth: oauth} do
      read_token = OAuth.Token.random()

      OAuth.Store.put_token(read_token, %{
        aud: oauth.resource,
        scope: "vault:read",
        expires_at: System.system_time(:second) + 3600
      })

      conn =
        post(
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

    test "a vault:read token cannot call skill_write either", %{oauth: oauth} do
      read_token = OAuth.Token.random()

      OAuth.Store.put_token(read_token, %{
        aud: oauth.resource,
        scope: "vault:read",
        expires_at: System.system_time(:second) + 3600
      })

      conn =
        post(
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
  end

  describe "rate limiting (AP-6.3)" do
    test "the 61st tools/call within a minute is rejected with 429", %{token: token} do
      for n <- 1..60 do
        conn =
          post(
            token,
            %{
              jsonrpc: "2.0",
              id: n,
              method: "tools/call",
              params: %{name: "current", arguments: %{}}
            },
            [{"mcp-session-id", "session-rl"}]
          )

        assert conn.status == 200
      end

      conn =
        post(
          token,
          %{
            jsonrpc: "2.0",
            id: 61,
            method: "tools/call",
            params: %{name: "current", arguments: %{}}
          },
          [{"mcp-session-id", "session-rl"}]
        )

      assert conn.status == 429
    end
  end

  test "an access token with the wrong audience is rejected", %{} do
    bad_token = OAuth.Token.random()

    OAuth.Store.put_token(bad_token, %{
      aud: "https://andere.tld/mcp",
      expires_at: System.system_time(:second) + 3600
    })

    conn = post(bad_token, %{jsonrpc: "2.0", id: 1, method: "ping"})
    assert conn.status == 401
  end

  test "a refresh token presented as an access token is rejected" do
    refresh = OAuth.Token.random()

    OAuth.Store.put_token(refresh, %{
      type: :refresh,
      client_id: "abc",
      aud: "https://vault.factory-lab.org/mcp",
      expires_at: System.system_time(:second) + 3600
    })

    conn = post(refresh, %{jsonrpc: "2.0", id: 1, method: "ping"})
    assert conn.status == 401
  end

  test "an expired access token is rejected and removed" do
    expired = OAuth.Token.random()

    OAuth.Store.put_token(expired, %{
      aud: "https://vault.factory-lab.org/mcp",
      expires_at: System.system_time(:second) - 1
    })

    conn = post(expired, %{jsonrpc: "2.0", id: 1, method: "ping"})
    assert conn.status == 401
    assert OAuth.Store.get_token(expired) == :error
  end
end
