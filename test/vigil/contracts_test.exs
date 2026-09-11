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
  # The OAuth metadata reads issuer/resource from application env, which
  # `Vigil.OAuthCase` sets process-globally.
  use ExUnit.Case, async: false

  import Vigil.ContractSnapshot

  alias Vigil.MCP.Tools
  alias Vigil.OAuth

  describe "the MCP tool list" do
    test "is what the recorded contract describes" do
      assert_unchanged("mcp_tools_list", Tools.definitions())
    end
  end

  describe "the OAuth metadata documents" do
    setup do
      Vigil.OAuthCase.setup!()
      :ok
    end

    # The issuer and resource in these files are the fixed test values
    # `Vigil.OAuthCase` pins, not a deployment's. What is guarded here is the
    # shape and every value that is not the host's: the scopes on offer, the
    # grant and response types, the PKCE method, the endpoint paths.
    test "RFC 9728 protected-resource metadata is unchanged" do
      assert_unchanged("oauth_protected_resource", OAuth.protected_resource_metadata())
    end

    test "RFC 8414 authorization-server metadata is unchanged" do
      assert_unchanged("oauth_authorization_server", OAuth.authorization_server_metadata())
    end
  end
end
