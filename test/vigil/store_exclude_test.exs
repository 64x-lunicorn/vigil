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

  # Regression: before Vigil.Vault.Policy only create/2 and move_note/1
  # applied the writable-path rules. append, rewrite_note, update_frontmatter
  # and delete_note checked traversal only, so each of them could write into
  # an excluded domain — and the write was then indexed, making the note
  # searchable in violation of docs/design.md ("VIGIL_EXCLUDE is the hard
  # boundary … not filtered — not read").
  describe "every write path honours the exclude boundary" do
    test "append cannot write into an excluded domain", %{vault: vault} do
      assert {:error, "Invalid path"} =
               Store.append(%{path: "work/secret.md", content: "INJECTED"})

      refute File.read!(Path.join(vault, "work/secret.md")) =~ "INJECTED"
    end

    test "rewrite_note cannot overwrite a note in an excluded domain", %{vault: vault} do
      before = File.read!(Path.join(vault, "work/secret.md"))

      assert {:error, "Invalid path"} =
               Store.rewrite_note(%{path: "work/secret.md", content: "# Pwned\n\nbody\n"})

      assert File.read!(Path.join(vault, "work/secret.md")) == before
    end

    test "update_frontmatter cannot touch an excluded domain" do
      assert {:error, "Invalid path"} =
               Store.update_frontmatter(%{path: "work/secret.md", type: "decision"})
    end

    test "delete_note cannot delete from an excluded domain", %{vault: vault} do
      assert {:error, "Invalid path"} =
               Store.delete_note(%{path: "work/secret.md", confirm: true})

      assert File.exists?(Path.join(vault, "work/secret.md"))
    end

    test "an excluded note never becomes searchable through a write" do
      Store.append(%{path: "work/secret.md", content: "INJECTEDWORD"})
      assert Store.search(%{query: "INJECTEDWORD"}) == []
      assert Store.search(%{query: "INJECTEDWORD", domain: "work"}) == []
    end
  end
end
