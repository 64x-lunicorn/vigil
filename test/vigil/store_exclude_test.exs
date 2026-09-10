defmodule Vigil.StoreExcludeTest do
  use ExUnit.Case, async: true

  alias Vigil.Store

  # One writer for this file, under a name of its own — see Vigil.StoreTest.
  @store __MODULE__

  # Vigil.MCP.Tools declares limit (1..25, default 10) and supplies it on
  # every real call, so `Store.call(@store, :search, ...)` requires one rather than defaulting.
  defp search(params), do: Store.call(@store, :search, Map.put_new(params, :limit, 10))

  setup do
    vault = Vigil.FixtureVault.build()
    on_exit(fn -> Vigil.FixtureVault.cleanup(vault) end)

    start_supervised!(
      {Store,
       vault_path: vault,
       exclude: ["work"],
       git_remote: "origin",
       git: Vigil.Git.CommitLog.new(vault),
       name: @store}
    )

    %{vault: vault}
  end

  test "VIGIL_EXCLUDE hides the folder from search, the index, read, and create even though it exists on disk",
       %{
         vault: vault
       } do
    assert File.exists?(Path.join(vault, "work/secret.md"))

    assert search(%{query: "excludedsearchword"}) == []
    assert search(%{query: "excludedsearchword", domain: "work"}) == []

    assert {:error, _} = Store.call(@store, :read, %{id: "work/secret.md", backlinks: false})

    assert {:error, _} =
             Store.call(@store, :create, %{
               path: "work/y.md",
               type: "reference",
               content: "# Y\nx"
             })
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
               Store.call(@store, :append, %{path: "work/secret.md", content: "INJECTED"})

      refute File.read!(Path.join(vault, "work/secret.md")) =~ "INJECTED"
    end

    test "rewrite_note cannot overwrite a note in an excluded domain", %{vault: vault} do
      before = File.read!(Path.join(vault, "work/secret.md"))

      assert {:error, "Invalid path"} =
               Store.call(@store, :rewrite_note, %{
                 path: "work/secret.md",
                 content: "# Pwned\n\nbody\n"
               })

      assert File.read!(Path.join(vault, "work/secret.md")) == before
    end

    test "update_frontmatter cannot touch an excluded domain" do
      assert {:error, "Invalid path"} =
               Store.call(@store, :update_frontmatter, %{path: "work/secret.md", type: "decision"})
    end

    test "delete_note cannot delete from an excluded domain", %{vault: vault} do
      assert {:error, "Invalid path"} =
               Store.call(@store, :delete_note, %{path: "work/secret.md", confirm: true})

      assert File.exists?(Path.join(vault, "work/secret.md"))
    end

    # The section ops answer on the id's own path part, before the id is
    # looked up at all: an excluded domain is "Invalid path", never the
    # "Not found" a missing section gets.
    test "the section ops reject an excluded domain as a path, not as a missing section" do
      assert {:error, "Invalid path"} =
               Store.call(@store, :replace_section, %{
                 id: "work/secret.md#secret",
                 content: "INJECTED"
               })

      assert {:error, "Invalid path"} =
               Store.call(@store, :delete_section, %{id: "work/secret.md#secret"})
    end

    test "an excluded note never becomes searchable through a write" do
      Store.call(@store, :append, %{path: "work/secret.md", content: "INJECTEDWORD"})
      assert search(%{query: "INJECTEDWORD"}) == []
      assert search(%{query: "INJECTEDWORD", domain: "work"}) == []
    end
  end
end
