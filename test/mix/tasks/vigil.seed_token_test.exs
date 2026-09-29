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

  # A seeded token is a bearer credential nobody rotates: its lifetime is what
  # bounds it, and it used to be ten years.
  test "a token lives 90 days unless the options say otherwise" do
    assert SeedToken.ttl_seconds([]) == 90 * 86_400
    assert SeedToken.ttl_seconds(ttl_days: 1) == 86_400
    assert SeedToken.ttl_seconds(ttl_days: 1, ttl_seconds: 900) == 900
  end
end
