defmodule Vigil.ContractsTest do
  @moduledoc """
  The documents vigil publishes to software it does not control.

  `Vigil.MCP.ToolsTest` checks that `definitions/0` is derived correctly from
  the declaration table — that the generator works. This file checks something
  the generator cannot: that the answer did not change. The two are different
  questions, and a correct generator fed an edited table produces a correct
  answer to a contract nobody agreed to.

  See `Vigil.ContractSnapshot` for how a change is recorded, and
  docs/compatibility.md for what a change to one of these files means for the
  version number. CI refuses a pull request that changes a file under
  `test/fixtures/contracts/` without an entry in CHANGELOG.md
  (`scripts/check_changelog.sh`).
  """
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test
  import Vigil.ContractSnapshot

  alias Vigil.MCP.{Server, Tools}
  alias Vigil.OAuth

  describe "the MCP tool list" do
    test "is what the recorded contract describes" do
      assert_unchanged("mcp_tools_list", Tools.definitions())
    end
  end

  describe "the documentation of the tool list" do
    # docs/guide.md is what a person reads to learn what vigil can do, and the
    # skills in the vault point at it. A tool added to the table and not to the
    # guide is a tool only the machine knows about; one removed from the table
    # and left in the guide is an instruction to call something that is not
    # there. Neither is caught by the snapshot above, which only knows what the
    # server serves.
    @guide Path.expand("../../docs/guide.md", __DIR__)

    # Backticked, not bare. `read`, `create`, `search`, `append` and `current`
    # are ordinary English and appear dozens of times in the guide's prose, so
    # a bare substring test is satisfied by a sentence that has nothing to do
    # with the tool — it would stay green with the tool's documentation deleted.
    test "every tool the server offers is documented in docs/guide.md" do
      guide = File.read!(@guide)

      for %{name: name} <- Tools.definitions() do
        assert String.contains?(guide, "`#{name}`"),
               "#{name} is in the tool table, and docs/guide.md never names it as `#{name}`"
      end
    end
  end

  describe "the OAuth metadata documents" do
    setup do
      Vigil.OAuthCase.setup!()
    end

    # Both documents take the authorization server they describe as a value,
    # which is what lets this file run in parallel: the issuer and resource in
    # the recorded files are the fixed test values `config/runtime.exs` pins
    # for the whole run, handed in rather than set around each test. What is
    # guarded here is the shape and every value that is not the host's: the
    # scopes on offer, the grant and response types, the PKCE method, the
    # endpoint paths.
    test "RFC 9728 protected-resource metadata is unchanged", %{settings: settings} do
      assert_unchanged("oauth_protected_resource", OAuth.protected_resource_metadata(settings))
    end

    test "RFC 8414 authorization-server metadata is unchanged", %{settings: settings} do
      assert_unchanged(
        "oauth_authorization_server",
        OAuth.authorization_server_metadata(settings)
      )
    end
  end

  # What a connected client is handed, driven through `/mcp` as a client drives
  # it: against the fixture vault, under a stated deployment (owner, language,
  # SkillKey secret) rather than whatever the shell exports, one session per
  # message so every envelope is a session's first.
  describe "what /mcp answers" do
    @store __MODULE__.Writer
    @sessions __MODULE__.Sessions

    setup do
      vault = Vigil.FixtureVault.build()
      on_exit(fn -> Vigil.FixtureVault.cleanup(vault) end)

      start_supervised!(
        {Vigil.Store,
         vault_path: vault,
         exclude: [],
         git_remote: "origin",
         git: Vigil.Git.CommitLog.new(vault),
         name: @store}
      )

      start_supervised!({Vigil.MCP.Envelope, name: @sessions})

      settings = Vigil.OAuthCase.stated_settings()
      persistence = OAuth.Persistence.Memory.new()

      opts =
        Server.init(
          store: @store,
          sessions: @sessions,
          oauth:
            OAuth.Endpoint.init(
              persistence: persistence,
              limiter: Vigil.RateLimit.Counter.new(),
              settings: settings
            )
        )

      token =
        OAuth.Token.issue_out_of_band(
          persistence,
          settings.resource,
          OAuth.scope(),
          3600,
          System.system_time(:second)
        )

      %{opts: opts, token: token, skill_key: Vigil.SkillKey.current(Vigil.SkillKey.key(settings))}
    end

    # The version is the release's own and changes with every one; the
    # contract is that it is there, as a string. Everything else is recorded
    # as served.
    test "the initialize result, instructions included, is unchanged", ctx do
      {conn, body} = initialize(ctx)

      assert conn.status == 200
      assert [_session_id] = get_resp_header(conn, "mcp-session-id")

      result = body["result"]
      assert result["serverInfo"]["version"] == to_string(Application.spec(:vigil, :vsn))

      assert_unchanged(
        "mcp_initialize",
        put_in(result, ["serverInfo", "version"], "<the release version>")
      )
    end

    # A shape rather than a value: every string is "string", every number
    # "integer" or "number", and a list is the merged shape of its items. The
    # values are the fixture's and move with it; the keys, the nesting and the
    # types are what a client parses, and those are the contract.
    test "the shape of every tool's result is unchanged", ctx do
      key = ctx.skill_key
      note = "bike/contract-note.md"

      reads = [
        {"search", %{"query" => "gravel", "limit" => 5}},
        {"list", %{"domain" => "bike"}},
        {"read", %{"id" => "bike/terra-speed.md"}},
        {"read#chunk", %{"id" => "bike/terra-speed.md#dimensions"}},
        {"links", %{"id" => "bike/terra-speed.md", "depth" => 2}},
        {"lint", %{}},
        {"current", %{}},
        {"status", %{}},
        {"skill_list", %{}},
        {"skill_read", %{"name" => "tdd"}},
        {"reload", %{}},
        {"read#error", %{"id" => "bike/no-such-note.md"}}
      ]

      writes = [
        {"create",
         %{
           "path" => note,
           "type" => "reference",
           "content" => "# Contract Note\n\nWhat the contract test writes.\n\n## Part\n\nText.\n",
           "skill_key" => key
         }},
        {"append",
         %{"path" => note, "heading" => "Log", "content" => "More.", "skill_key" => key}},
        {"replace_section",
         %{"id" => note <> "#part", "content" => "New text.", "skill_key" => key}},
        {"update_frontmatter", %{"path" => note, "type" => "decision", "skill_key" => key}},
        {"delete_section", %{"id" => note <> "#log", "skill_key" => key}},
        {"rewrite_note",
         %{
           "path" => note,
           "content" => "# Contract Note\n\nRewritten.\n\n## Part\n\nText.\n",
           "confirm" => true,
           "skill_key" => key
         }},
        {"create#linking",
         %{
           "path" => "bike/wheel-log.md",
           "type" => "reference",
           "content" => "# Wheel Log\n\nSee [[contract-note]].\n",
           "force" => true,
           "skill_key" => key
         }},
        {"history", %{"path" => note}}
      ]

      moves = [
        {"move_note",
         %{
           "from" => note,
           "to" => "bike/contract-moved.md",
           "update_links" => true,
           "confirm" => true,
           "skill_key" => key
         }},
        {"delete_note",
         %{"path" => "bike/contract-moved.md", "confirm" => true, "skill_key" => key}},
        {"skill_write",
         %{
           "name" => "contract-skill",
           "content" =>
             "---\nname: contract-skill\ndescription: What the contract test writes\n---\n# Contract skill\n\nBody.\n",
           "skill_key" => key
         }}
      ]

      shapes =
        Map.new(reads ++ writes, fn {label, arguments} ->
          {label, shape(call(ctx, tool_name(label), arguments))}
        end)

      # An event a week ahead, so `current` has one to describe: its lists are
      # empty on the fixture alone, and an empty list records no item shape.
      starts = DateTime.utc_now() |> DateTime.add(7 * 86_400) |> DateTime.truncate(:second)

      event = %{
        "path" => "bike/contract-ride.md",
        "type" => "event",
        "starts" => DateTime.to_iso8601(starts),
        "ends" => starts |> DateTime.add(3600) |> DateTime.to_iso8601(),
        "content" => "# Contract Ride\n\nA ride a week ahead.\n",
        "force" => true,
        "skill_key" => key
      }

      shapes =
        shapes
        |> Map.put("create#event", shape(call(ctx, "create", event)))
        |> Map.put("current#upcoming", shape(call(ctx, "current", %{})))

      # A note as it was at a commit its history names.
      %{"content" => [%{"text" => %{"result" => %{"commits" => [%{"commit" => commit} | _]}}}]} =
        call(ctx, "history", %{"path" => note})

      at = shape(call(ctx, "read", %{"id" => note, "at" => commit}))

      shapes =
        Map.merge(
          Map.put(shapes, "read#at", at),
          Map.new(moves, fn {label, arguments} ->
            {label, shape(call(ctx, tool_name(label), arguments))}
          end)
        )

      # Every tool the server offers has a recorded result.
      assert shapes |> Map.keys() |> Enum.map(&tool_name/1) |> Enum.uniq() |> Enum.sort() ==
               Tools.definitions() |> Enum.map(& &1.name) |> Enum.sort()

      assert_unchanged("mcp_tool_results", shapes)
    end
  end

  defp tool_name(label), do: label |> String.split("#") |> hd()

  defp post(ctx, body, headers) do
    conn =
      conn(:post, "/mcp", Jason.encode!(body))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer #{ctx.token}")

    conn = Enum.reduce(headers, conn, fn {k, v}, c -> put_req_header(c, k, v) end)
    conn = Server.call(conn, ctx.opts)
    {conn, Jason.decode!(conn.resp_body)}
  end

  defp initialize(ctx) do
    post(
      ctx,
      %{
        jsonrpc: "2.0",
        id: 1,
        method: "initialize",
        params: %{
          protocolVersion: "2025-11-25",
          capabilities: %{},
          clientInfo: %{name: "contract-test", version: "0"}
        }
      },
      []
    )
  end

  # The whole `tools/call` result, with the text content decoded: the payload
  # (`result` or `error`, `stale` when set, and the envelope) is what a
  # client reads, and it arrives as JSON inside a string.
  defp call(ctx, name, arguments) do
    {init, _body} = initialize(ctx)
    [session_id] = get_resp_header(init, "mcp-session-id")

    {conn, body} =
      post(
        ctx,
        %{
          jsonrpc: "2.0",
          id: 2,
          method: "tools/call",
          params: %{name: name, arguments: arguments}
        },
        [{"mcp-session-id", session_id}]
      )

    assert conn.status == 200

    update_in(body["result"]["content"], fn content ->
      Enum.map(content, fn %{"type" => "text", "text" => text} = item ->
        Map.put(item, "text", Jason.decode!(text))
      end)
    end)
    |> Map.fetch!("result")
  end

  defp shape(map) when is_map(map), do: Map.new(map, fn {k, v} -> {k, shape(v)} end)
  defp shape([]), do: []
  defp shape(list) when is_list(list), do: [list |> Enum.map(&shape/1) |> Enum.reduce(&merge/2)]
  defp shape(value) when is_binary(value), do: "string"
  defp shape(value) when is_boolean(value), do: "boolean"
  defp shape(value) when is_integer(value), do: "integer"
  defp shape(value) when is_float(value), do: "number"
  defp shape(nil), do: "null"

  # Two items of one list, as one shape: a key either has is kept, and a
  # value that differs in type is both, e.g. "null|string".
  defp merge(same, same), do: same

  defp merge(a, b) when is_map(a) and is_map(b),
    do: Map.merge(a, b, fn _k, x, y -> merge(x, y) end)

  defp merge([a], [b]), do: [merge(a, b)]
  defp merge([], other), do: other
  defp merge(other, []), do: other

  defp merge(a, b) when is_binary(a) and is_binary(b) do
    (String.split(a, "|") ++ String.split(b, "|")) |> Enum.uniq() |> Enum.sort() |> Enum.join("|")
  end

  defp merge(a, b), do: "#{inspect(a)}|#{inspect(b)}"
end
