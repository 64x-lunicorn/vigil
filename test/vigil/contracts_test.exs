defmodule Vigil.ContractsTest do
  @moduledoc """
  The documents vigil publishes to software it does not control.

  `Vigil.MCP.ToolsTest` checks that `definitions/0` is derived correctly from
  the declaration table — that the generator works. This file checks something
  the generator cannot: that the answer did not change. The two are different
  questions, and a correct generator fed an edited table produces a correct
  answer to a contract nobody agreed to.

  See `Vigil.ContractSnapshot` for how a change is recorded.
  """
  use ExUnit.Case, async: true

  import Vigil.ContractSnapshot

  alias Vigil.MCP.Tools
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
end
