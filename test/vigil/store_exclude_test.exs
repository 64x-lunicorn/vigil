defmodule Vigil.StoreExcludeTest do
  use ExUnit.Case, async: false

  alias Vigil.Store

  setup do
    vault = Vigil.FixtureVault.build()
    on_exit(fn -> Vigil.FixtureVault.cleanup(vault) end)
    start_supervised!({Store, vault_path: vault, exclude: ["work"], git_remote: "origin"})
    %{vault: vault}
  end

  test "VIGIL_EXCLUDE hides the folder from search, ETS, read, and create even though it exists on disk",
       %{
         vault: vault
       } do
    assert File.exists?(Path.join(vault, "work/secret.md"))

    assert Store.search(%{query: "excludedsearchword"}) == []
    assert Store.search(%{query: "excludedsearchword", domain: "work"}) == []

    assert {:error, _} = Store.read("work/secret.md", false)
    assert {:error, _} = Store.create(%{path: "work/y.md", type: "reference", content: "# Y\nx"})
  end
end
