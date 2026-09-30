defmodule Vigil.StoreExcludeTest do
  use ExUnit.Case, async: true

  alias Vigil.Store

  # One writer for this file, under a name of its own — see Vigil.StoreTest.
  @store __MODULE__

  # Vigil.MCP.Tools declares limit (1..25, default 10) and supplies it on
  # every real call, so `Store.call(@store, :search, ...)` requires one rather than defaulting.
  defp search(params) do
    {:ok, %{results: results}} = Store.call(@store, :search, Map.put_new(params, :limit, 10))
    results
  end

  setup do
    vault = Vigil.FixtureVault.build()
    on_exit(fn -> Vigil.FixtureVault.cleanup(vault) end)

    # A project directory carrying an excluded name, one level below the
    # domains VIGIL_EXCLUDE was first written against. Its note links to a
    # note that is not excluded, so a backlink is something it could leave.
    # `verborgen` is excluded too and is not there at all.
    File.mkdir_p!(Path.join(vault, "projects/geheim"))

    File.write!(Path.join(vault, "projects/geheim/plan.md"), """
    ---
    type: reference
    ---
    # Plan

    ## Detail

    Contains the unique search word nestedsearchword. See [[vigil]].
    """)

    # Committed, and no note: a file at the vault root, one that is not
    # Markdown, and one in a `_`-prefixed directory, all of which the Git
    # history holds.
    File.write!(Path.join(vault, "README.md"), "# Readme\n\nreadmesearchword\n")
    File.write!(Path.join(vault, "bike/notes.txt"), "not markdown\n")
    File.mkdir_p!(Path.join(vault, "_templates"))
    File.write!(Path.join(vault, "_templates/meeting.md"), "# Meeting\n\ntemplateword\n")

    git = Vigil.Git.CommitLog.new(vault)

    start_supervised!(
      {Store,
       vault_path: vault,
       exclude: ["work", "geheim", "verborgen"],
       git_remote: "origin",
       git: git,
       name: @store}
    )

    %{vault: vault, git: git}
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

  # VIGIL_EXCLUDE names directories, and `projects/` holds directories one
  # level below the domains. The boundary used to compare a path's first
  # segment only, so a project directory carrying an excluded name was
  # parsed, indexed, searchable and writable.
  describe "an excluded project directory" do
    @nested "projects/geheim/plan.md"

    test "is not in the index: no note, no chunk, no backlink", %{vault: vault} do
      assert File.exists?(Path.join(vault, @nested))

      assert search(%{query: "nestedsearchword"}) == []
      assert search(%{query: "nestedsearchword", domain: "projects"}) == []

      for id <- [@nested, @nested <> "#detail"] do
        assert Store.call(@store, :read, %{id: id, backlinks: false}) ==
                 {:error, "Not found: #{id}"}

        assert Store.call(@store, :links, %{id: id, direction: :both, depth: 1}) ==
                 {:error, "Not found: #{id}"}
      end

      {:ok, links} =
        Store.call(@store, :links, %{id: "projects/vigil/vigil.md", direction: :in, depth: 1})

      refute inspect(links) =~ "geheim"

      {:ok, note} = Store.call(@store, :read, %{id: "projects/vigil/vigil.md", backlinks: true})
      refute inspect(note) =~ "geheim"
    end

    # The wording an excluded domain earns, whichever write it is and whether
    # the note — or the directory — is there at all.
    test "every write path refuses it as a path", %{vault: vault} do
      before = File.read!(Path.join(vault, @nested))

      writes = [
        {:create, %{path: "projects/geheim/new.md", type: "reference", content: "# N\nx"}},
        {:create,
         %{
           path: "projects/geheim/new.md",
           type: "reference",
           content: "# N\nx",
           create_dirs: true
         }},
        {:create,
         %{
           path: "projects/geheim/plan.md",
           type: "reference",
           content: "# N\nx",
           create_dirs: true
         }},
        {:append, %{path: @nested, content: "INJECTED"}},
        {:rewrite_note, %{path: @nested, content: "# Pwned\n\nbody\n"}},
        {:update_frontmatter, %{path: @nested, type: "decision"}},
        {:delete_note, %{path: @nested, confirm: true}},
        {:replace_section, %{id: @nested <> "#detail", content: "INJECTED"}},
        {:delete_section, %{id: @nested <> "#detail"}},
        {:move_note, %{from: @nested, to: "projects/vigil/plan.md", confirm: true}},
        {:move_note,
         %{from: "projects/vigil/vigil.md", to: "projects/geheim/vigil.md", confirm: true}},
        # A directory that is not there is refused in the same words as one
        # that is, and is not created.
        {:create,
         %{path: "projects/verborgen/x.md", type: "reference", content: "# X", create_dirs: true}},
        {:append, %{path: "projects/verborgen/x.md", content: "x"}}
      ]

      for {op, params} <- writes do
        assert Store.call(@store, op, params) == {:error, "Invalid path"}, inspect({op, params})
      end

      refute File.exists?(Path.join(vault, "projects/verborgen"))
      assert File.read!(Path.join(vault, @nested)) == before
      assert File.exists?(Path.join(vault, "projects/vigil/vigil.md"))
    end
  end

  # The two reads that answer out of the Git history rather than the index
  # (Vigil.History) see what the index sees and nothing more: the history
  # holds every file ever committed, excluded or not, note or not, and
  # neither read may become the way around the boundary the index keeps.
  describe "history and read at a revision" do
    defp history(path), do: Store.call(@store, :history, %{path: path, limit: 20})

    defp read_at(id, at), do: Store.call(@store, :read, %{id: id, at: at, backlinks: false})

    defp initial_commit do
      {:ok, %{commits: [initial]}} = history("bike/via-carolina.md")
      initial.commit
    end

    @hidden [
      "work/secret.md",
      "projects/geheim/plan.md",
      "skills/tdd.md",
      "README.md",
      "bike/notes.txt"
    ]

    test "answer a path that is no note, or is excluded, as one with no history" do
      for path <- @hidden do
        assert history(path) == {:error, "Not found: #{path}"}, path
      end
    end

    test "read at a revision answers it as not there at that revision" do
      at = initial_commit()

      for path <- @hidden do
        assert read_at(path, at) == {:error, "Not found: #{path} at #{at}"}, path
      end

      assert read_at("work/secret.md#secret", at) ==
               {:error, "Not found: work/secret.md#secret at #{at}"}
    end

    # A `_`-prefixed directory fails the safety check, as it does for `read`.
    test "an unsafe path is still refused as a path" do
      at = initial_commit()

      for path <- ["../outside.md", "_templates/meeting.md", "_domains.yml"] do
        assert history(path) == {:error, "Invalid path"}, path
        assert read_at(path, at) == {:error, "Invalid path"}, path
      end
    end

    # A note that was moved out of an excluded directory keeps the commits
    # it had there, under the excluded name: those are dropped, and the name
    # it had then cannot be read at them.
    test "leave out the commits a note had under an excluded name", %{vault: vault, git: git} do
      at = initial_commit()
      :ok = git.move.(vault, "work/secret.md", "bike/secret.md")

      {:ok, _} =
        git.commit.(vault, "main", ["work/secret.md", "bike/secret.md"], "move out of work")

      assert {:ok, %{path: "bike/secret.md", commits: [moved]}} = history("bike/secret.md")
      assert %{path: "bike/secret.md", message: "move out of work"} = moved

      assert read_at("work/secret.md", at) == {:error, "Not found: work/secret.md at #{at}"}
      assert {:ok, %{path: "bike/secret.md"}} = read_at("bike/secret.md", moved.commit)
    end
  end
end
