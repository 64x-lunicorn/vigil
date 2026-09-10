defmodule Vigil.MCP.ServerTest do
  # Not async: the whole MCP surface is named singletons — the envelope, the
  # rate limiter, and the Store under its production registration, which is
  # the name Vigil.MCP.Tools and Vigil.MCP.Server find the writer by.
  use ExUnit.Case, async: false
  use Plug.Test

  alias Vigil.Store
  alias Vigil.MCP.Server
  alias Vigil.MCP.Tools
  alias Vigil.OAuth

  setup do
    vault = Vigil.FixtureVault.build()
    on_exit(fn -> Vigil.FixtureVault.cleanup(vault) end)

    start_supervised!(
      {Store,
       vault_path: vault, exclude: [], git_remote: "origin", git: Vigil.Git.CommitLog.new(vault)}
    )

    start_supervised!(Vigil.MCP.Envelope)
    start_supervised!(Vigil.RateLimit)

    oauth = Vigil.OAuthCase.setup!()

    %{vault: vault, token: seed_token(oauth), oauth: oauth}
  end

  # A real access token, minted by the module that owns the record. The tests
  # that hand-write one below do it on purpose: those are the shapes `/mcp`
  # has to refuse, and no minting path produces them.
  defp seed_token(oauth, scope \\ OAuth.scope()) do
    OAuth.Token.issue_out_of_band(oauth.resource, scope, 3600, System.system_time(:second))
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

  # The one tool whose whole job is answering what time it is must not
  # disagree with the envelope above it. Two halves: the call is made at the
  # instant the envelope was decided at — pinned exactly, so it cannot pass by
  # two clock reads happening to land in the same minute — and the response
  # the router assembles carries both readings of that one instant.
  test "current's reported time and its envelope come from the same instant", %{token: token} do
    pinned = ~U[2026-07-09 11:20:00Z] |> DateTime.shift_zone!("Europe/Berlin")

    assert {:ok, %{now: reported}} = Tools.dispatch("current", %{}, pinned)
    assert reported == DateTime.to_iso8601(pinned)

    conn =
      post(
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

  test "tool errors set isError and carry the message alongside an envelope", %{token: token} do
    conn = failing_create(token, "session-d", 4)

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
  test "a failed first call is not repeated as a first call", %{token: token} do
    failing_create(token, "session-e", 5)

    conn =
      post(
        token,
        %{jsonrpc: "2.0", id: 6, method: "tools/call", params: %{name: "reload", arguments: %{}}},
        [{"mcp-session-id", "session-e"}]
      )

    payload = Jason.decode!(hd(Jason.decode!(conn.resp_body)["result"]["content"])["text"])
    assert Map.has_key?(payload, "_t")
    refute Map.has_key?(payload, "_")
  end

  defp failing_create(token, session_id, id) do
    post(
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
            skill_key: Vigil.SkillKey.current(Vigil.SkillKey.config())
          }
        }
      },
      [{"mcp-session-id", session_id}]
    )
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
      key = Vigil.SkillKey.current(Vigil.SkillKey.config())

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
        Vigil.SkillKey.current(Vigil.SkillKey.config(), System.system_time(:second) - 7200)

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
      key = Vigil.SkillKey.current(Vigil.SkillKey.config())

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
      read_token = seed_token(oauth, OAuth.read_scope())

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
      read_token = seed_token(oauth, OAuth.read_scope())

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
      read_token = seed_token(oauth, OAuth.read_scope())

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
    # A small explicit budget (rather than the default 60) keeps this an
    # integration test of the wiring — Server.init/1 resolving the budget
    # and handle_mcp/1 enforcing it — without needing dozens of requests;
    # Vigil.RateLimitTest covers the limiter's own behavior directly.
    defp post_with_budget(token, body, budget, headers) do
      conn =
        conn(:post, "/mcp", Jason.encode!(body))
        |> put_req_header("content-type", "application/json")
        |> put_req_header("authorization", "Bearer #{token}")

      conn = Enum.reduce(headers, conn, fn {k, v}, c -> put_req_header(c, k, v) end)
      Server.call(conn, Server.init(rate_limit_budget: budget))
    end

    test "the (budget+1)th tools/call within a minute is rejected with 429", %{token: token} do
      for n <- 1..3 do
        conn =
          post_with_budget(
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

  # The call `dispatch/2` builds is the one frame nothing else looks at:
  # validation runs before it, and the write path's own defenses (Facts,
  # Decision, Plan) all sit after it. Now that it comes from `@tools` rather
  # than from a clause per tool, driving every declared tool once through the
  # MCP surface is what proves each row's `call:` and parameter names are the
  # ones its Store operation actually accepts.
  #
  # The list is checked against `Tools.definitions/0` first, so a tool added to
  # `@tools` without an entry here fails the suite instead of quietly going
  # unexercised.
  describe "dispatch coverage" do
    test "every declared tool is dispatched end to end", %{token: token, vault: vault} do
      key = Vigil.SkillKey.current(Vigil.SkillKey.config())
      calls = dispatch_calls()

      assert MapSet.new(calls, fn {name, _args, _verify} -> name end) ==
               MapSet.new(Tools.definitions(), & &1.name)

      for {{name, args, verify}, index} <- Enum.with_index(calls) do
        args = if Tools.write_tool?(name), do: Map.put(args, :skill_key, key), else: args

        conn =
          post(
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
