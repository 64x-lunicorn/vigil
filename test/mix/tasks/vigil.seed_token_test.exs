defmodule Mix.Tasks.Vigil.SeedTokenTest do
  @moduledoc """
  The task's refusal of a scope, which happens before it opens any state. The
  scopes are `Vigil.OAuth`'s: a scope the flow issues is one the task accepts,
  and the refusal names exactly those.
  """
  use ExUnit.Case, async: true

  alias Mix.Tasks.Vigil.SeedToken

  test "a scope Vigil.OAuth does not publish is refused, naming the ones it does" do
    allowed = Enum.join(Vigil.OAuth.scopes(), ", ")

    assert_raise Mix.Error, "Invalid --scope: vault:admin (allowed: #{allowed})", fn ->
      SeedToken.run([
        "--state-dir",
        "unused",
        "--resource",
        "https://vault.example.org/mcp",
        "--scope",
        "vault:admin"
      ])
    end
  end
end
