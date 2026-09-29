defmodule Vigil.StoreTest do
  # async: true, and what makes it possible is the writer registering under a
  # name this file supplies rather than under its own module (docs/design.md,
  # "The write path", "One writer per vault, under a name its caller
  # supplies"). Production registers under `Vigil.Store`, which is what the MCP
  # surface finds it by; the files that go through that surface are the ones
  # that stay serialized.
  use ExUnit.Case, async: true

  alias Vigil.Git.CommitLog
  alias Vigil.Store

  # One writer for this file. Tests inside a module run one after another, so
  # a name per file is all the isolation an async suite needs.
  @store __MODULE__

  # Vigil.MCP.Tools declares limit (1..25, default 10) and supplies it on
  # every real call, so `Store.call(@store, :search, ...)` requires one rather than defaulting.
  defp search(params), do: Store.call(@store, :search, Map.put_new(params, :limit, 10))

  # Every Store in this file reaches git through the commit log
  # (docs/design.md, "Git is reached through a value"). What these tests
  # assert is the write path's — what lands on disk, what the index says
  # afterwards, what a failure reads like — and git_test.exs is where git is
  # held to its contract. `git_remote: "nonexistent-remote"` is how a push
  # failure is provoked, exactly as it was against a repository.
  defp start_store(vault, opts \\ []) do
    start_supervised!(
      {Store,
       vault_path: vault,
       exclude: Keyword.get(opts, :exclude, []),
       git_remote: Keyword.get(opts, :git_remote, "origin"),
       git_branch: Keyword.get(opts, :git_branch, "main"),
       git: Keyword.get_lazy(opts, :git, fn -> CommitLog.new(vault) end),
       name: @store}
    )
  end

  setup do
    vault = Vigil.FixtureVault.build()
    on_exit(fn -> Vigil.FixtureVault.cleanup(vault) end)
    start_store(vault)
    %{vault: vault}
  end

  # Ranking, filtering, journal-hiding and hub-attachment are Vigil.Index's
  # job now and are covered there (index_test.exs) without git. This is the
  # wiring smoke test: a :search call reaches the index and shapes the result.
  describe "search" do
    test "a term in domain bike returns ranked hits with previews, no bodies" do
      results = search(%{query: "tires", domain: "bike"})
      assert results != []
      refute Map.has_key?(hd(results), :body)
      assert Enum.all?(results, &(String.length(&1.preview) <= 121))
    end
  end

  # docs/design.md, "The write path": a caller that breaks a declared contract
  # outright fails in its own process rather than in the writer's. The tool
  # table is what declares the contract — a `limit` for search, a `depth` and
  # a `direction` for links, an id for every operation that names one — and
  # `Store.call/2`'s heads match it, so the mistake raises where it was made
  # and the single writer keeps answering everyone else. An operation the
  # Store does not have is refused in the same frame: there is no catch-all
  # head to absorb it. What the heads do not restate is a *bound*: `depth` is
  # `1..2` in the tool table, which refuses 3 before the Store is reached —
  # pinned in Vigil.MCP.ToolsTest, "a depth outside 1..2 is refused before the
  # Store is reached".
  #
  # The calls go through a variable on purpose. Written as literals the
  # compiler's type checker warns about every one of them — it can see they
  # match no head, which is the point of the test.
  describe "a broken contract fails in the caller's process" do
    test "a missing limit, a missing depth, a missing id, an operation that does not exist" do
      writer = Process.whereis(@store)

      broken = [
        {:search, %{query: "tires"}},
        {:links, %{id: "bike/via-carolina.md", direction: :out}},
        {:read, %{backlinks: false}},
        {:nonsense, %{}}
      ]

      for {op, params} <- broken do
        assert_raise FunctionClauseError, fn -> Store.call(@store, op, params) end
      end

      assert Process.whereis(@store) == writer
      assert search(%{query: "tires", domain: "bike"}) != []
    end
  end

  # The chunk/note shapes, backlinks opt-in, lenient path resolution, and
  # invalid/not-found handling are Vigil.Index's job now and are covered
  # there (index_test.exs) without git. This is the wiring smoke test.
  describe "read" do
    test "reading a fragment returns exactly that chunk" do
      {:ok, result} =
        Store.call(@store, :read, %{id: "bike/via-carolina.md#fueling", backlinks: false})

      assert result.heading == "Fueling"
      assert result.body =~ "baseline"
      refute Map.has_key?(result, :backlinks)
    end
  end

  describe "create" do
    test "creates the file, pushes, and updates the index", %{vault: vault} do
      assert {:ok, %{path: "bike/new.md", pushed: true}} =
               Store.call(@store, :create, %{
                 path: "bike/new.md",
                 type: "reference",
                 content: "# New\n\nSome test content.\n"
               })

      assert File.exists?(Path.join(vault, "bike/new.md"))
      {:ok, result} = Store.call(@store, :read, %{id: "bike/new.md", backlinks: false})
      assert result.title == "New"
    end

    # File-exists, H1, frontmatter and event starts/ends rules are pure
    # refusals asserted against Vigil.Vault.Policy directly (policy_test.exs,
    # "existence rules" and "content and type rules on :create") — they touch
    # neither the filesystem nor git, so the store test no longer restates
    # them.
    test "duplicate detection blocks similarly-titled note in same domain, force bypasses it" do
      assert {:error, msg} =
               Store.call(@store, :create, %{
                 path: "bike/terra-speed-tubeless.md",
                 type: "reference",
                 content: "# Terra Speed Tubeless\ntext"
               })

      assert msg =~ "duplicates"
      assert msg =~ "append"

      assert {:ok, _} =
               Store.call(@store, :create, %{
                 path: "bike/terra-speed-tubeless.md",
                 type: "reference",
                 content: "# Terra Speed Tubeless\ntext",
                 force: true
               })
    end

    # The gate used to derive its search terms from the basename's segments
    # longer than three characters, so a short name produced no terms, asked
    # the index nothing, and passed. "bike/via.md" against a vault holding
    # "Via Carolina" is the shape that got through.
    test "a short name is checked too: a real duplicate is refused, a new note passes" do
      assert {:error, msg} =
               Store.call(@store, :create, %{
                 path: "bike/via.md",
                 type: "reference",
                 content: "# Via\ntext"
               })

      assert msg =~ "duplicates"
      assert msg =~ "bike/via-carolina.md"

      assert {:ok, _} =
               Store.call(@store, :create, %{
                 path: "bike/kvv.md",
                 type: "reference",
                 content: "# KVV\ntext"
               })
    end

    test "duplicate detection does not fire within the same project folder" do
      assert {:ok, _} =
               Store.call(@store, :create, %{
                 path: "projects/vigil/vigil-notes.md",
                 type: "reference",
                 content: "# vigil Notes\nMore notes about vigil."
               })
    end

    # "duplicate detection still fires across different project folders" moved
    # to policy_test.exs, "a strong match in a different project folder is
    # still a duplicate" — pure refusal, no filesystem or git touched.

    # The refusal half ("Project directory does not exist") is
    # policy_test.exs, "an unknown project directory is rejected without
    # create_dirs". What stays here is what only the real store can show:
    # create_dirs actually creates the directory on disk.
    test "create_dirs creates a missing project folder" do
      assert {:ok, _} =
               Store.call(@store, :create, %{
                 path: "projects/new/x.md",
                 type: "reference",
                 content: "# X\nx",
                 create_dirs: true
               })

      assert {:ok, _} = Store.call(@store, :read, %{id: "projects/new/x.md", backlinks: false})
    end

    test "create_dirs never creates directories outside projects/", %{vault: vault} do
      assert {:error, _} =
               Store.call(@store, :create, %{
                 path: "gear/sub/x.md",
                 type: "reference",
                 content: "# X\nx",
                 create_dirs: true
               })

      refute File.dir?(Path.join(vault, "gear/sub"))

      assert {:error, _} =
               Store.call(@store, :create, %{
                 path: "unknown-domain/x.md",
                 type: "reference",
                 content: "# X\nx",
                 create_dirs: true
               })

      refute File.dir?(Path.join(vault, "unknown-domain"))
    end

    # "unknown domain is rejected with a domain list" moved to
    # policy_test.exs, "an unknown domain names the ones that exist".
    #
    # "projects allows exactly one extra level, other domains do not" moved
    # to policy_test.exs, "notes nest one level deep, except under projects".

    test "[[vigil-ranking]] in vigil.md resolves to projects/vigil/vigil-ranking.md" do
      {:ok, result} = Store.call(@store, :read, %{id: "projects/vigil/vigil.md", backlinks: true})
      assert result.title == "vigil"

      {:ok, links} =
        Store.call(@store, :links, %{id: "projects/vigil/vigil.md", direction: :out, depth: 1})

      assert [%{target: "projects/vigil/vigil-ranking.md", status: "ok"}] =
               Enum.map(links.outgoing, &Map.take(&1, [:target, :status]))
    end
  end

  # The line arithmetic behind each target — mid-file, at EOF, under an
  # existing vs. a new heading — is Vigil.Vault.Edit's job now and is
  # covered there (edit_test.exs) without git. Store still owns picking the
  # target (append_target/3, via Index.chunk_by_heading), so one case per
  # target stays here as the wiring smoke test.
  describe "append" do
    test "appends under an existing heading, at the end of that section" do
      assert {:ok, _} =
               Store.call(@store, :append, %{
                 path: "bike/via-carolina.md",
                 heading: "Gear",
                 content: "Extra: repair kit."
               })

      {:ok, result} =
        Store.call(@store, :read, %{id: "bike/via-carolina.md#gear", backlinks: false})

      assert result.body =~ "Extra: repair kit."
    end

    test "appends a new section when the heading does not exist yet" do
      assert {:ok, _} =
               Store.call(@store, :append, %{
                 path: "bike/via-carolina.md",
                 heading: "Weather",
                 content: "Dry conditions expected."
               })

      {:ok, result} =
        Store.call(@store, :read, %{id: "bike/via-carolina.md#weather", backlinks: false})

      assert result.body =~ "Dry conditions expected."
    end

    test "appends to EOF without a heading" do
      assert {:ok, _} =
               Store.call(@store, :append, %{
                 path: "bike/terra-speed.md",
                 content: "Final sentence."
               })

      {:ok, result} =
        Store.call(@store, :read, %{id: "bike/terra-speed.md#gravel-experience", backlinks: false})

      assert result.body =~ "Final sentence."
    end

    # A heading spliced into the middle of a section splits it on the next
    # parse, into two chunks one of which nobody asked for.
    test "a heading in content appended to an existing section is rejected", %{vault: vault} do
      assert {:error, msg} =
               Store.call(@store, :append, %{
                 path: "bike/via-carolina.md",
                 heading: "Gear",
                 content: "## Sneaky\nSplit."
               })

      assert msg =~ "split the section in two"
      refute File.read!(Path.join(vault, "bike/via-carolina.md")) =~ "Sneaky"
    end

    test "the same content is accepted at the end of the file and as a new section" do
      content = "## Sneaky\nNot sneaky here."

      assert {:ok, _} =
               Store.call(@store, :append, %{path: "bike/terra-speed.md", content: content})

      assert {:ok, _} =
               Store.call(@store, :append, %{
                 path: "bike/via-carolina.md",
                 heading: "Weather",
                 content: content
               })
    end
  end

  # Which lines move, and content-shape validation, are Vigil.Vault.Edit's
  # and Vigil.Vault.Policy's jobs now and are covered there (edit_test.exs,
  # policy_test.exs) without git. This is the wiring smoke test.
  describe "replace_section" do
    test "replaces the target chunk's body and the index picks it up" do
      assert {:ok, _} =
               Store.call(@store, :replace_section, %{
                 id: "bike/via-carolina.md#fueling",
                 content: "New fueling strategy."
               })

      {:ok, result} =
        Store.call(@store, :read, %{id: "bike/via-carolina.md#fueling", backlinks: false})

      assert result.body =~ "New fueling strategy."
    end

    # The id is resolved once, by the policy, through the same lenient lookup
    # `read` uses — so the two accept the same ids, and the write lands on the
    # path the lookup resolved rather than on one re-derived from the id.
    test "an id that read accepts is accepted here too, and writes the resolved path" do
      messy = "bike/Via Carolina!!.md#fueling"

      assert {:ok, _} = Store.call(@store, :read, %{id: messy, backlinks: false})

      assert {:ok, %{path: "bike/via-carolina.md"}} =
               Store.call(@store, :replace_section, %{id: messy, content: "Resolved."})

      {:ok, result} =
        Store.call(@store, :read, %{id: "bike/via-carolina.md#fueling", backlinks: false})

      assert result.body =~ "Resolved."
    end

    # The writable-path check runs on the normalized path part, not the raw
    # one: a messy domain segment or extension resolves for `read`, so it has
    # to resolve here too.
    test "leniency covers the whole path part, not just the basename" do
      for messy <- ["Bike/via-carolina.md#fueling", "bike/via-carolina.MD#fueling"] do
        assert {:ok, _} = Store.call(@store, :read, %{id: messy, backlinks: false})

        assert {:ok, %{path: "bike/via-carolina.md"}} =
                 Store.call(@store, :replace_section, %{
                   id: messy,
                   content: "Resolved via #{messy}."
                 })
      end
    end

    # "a section id that normalizes into skills/ is still Invalid path" and
    # "an id naming skills/ is Invalid path, not Not found" moved to
    # policy_test.exs, "the writable-path rules still apply to a section
    # id" — extended to cover replace_section, both raw and normalized.
    #
    # "a missing section in a writable note is Not found" is already proven
    # there too, in "an unknown section is reported as unknown, not as bad
    # content".
  end

  describe "current" do
    test "returns the window Vigil.Events computes from the indexed event files" do
      during_event = ~U[2026-07-11 00:00:00Z] |> DateTime.shift_zone!("Europe/Berlin")

      result = Store.call(@store, :current, %{now: during_event})

      assert Enum.any?(result.active, &(&1.id == "bike/via-carolina.md"))
    end

    # An event whose ends precedes its starts cannot reach the index through
    # vigil at all: the write gate refuses it (Vigil.Vault.Frontmatter owns
    # the rule, Vigil.Parser applies the same one to what it reads). The note
    # that used to be written here and then quietly downgraded to `reference`
    # on the way into the index is the disagreement that owner closed.
    test "an event whose ends precedes its starts never reaches the index", %{vault: vault} do
      assert {:error, msg} =
               Store.call(@store, :create, %{
                 path: "bike/kaputt.md",
                 type: "event",
                 content: "# Kaputt\nx",
                 starts: "2026-07-10T10:00:00+02:00",
                 ends: "2026-07-09T10:00:00+02:00"
               })

      assert msg =~ "ends must not be before starts"
      refute File.exists?(Path.join(vault, "bike/kaputt.md"))

      now = ~U[2026-07-10 08:00:00Z] |> DateTime.shift_zone!("Europe/Berlin")
      result = Store.call(@store, :current, %{now: now})

      refute Enum.any?(
               result.active ++ result.upcoming ++ result.recently_past,
               &(&1.id == "bike/kaputt.md")
             )
    end
  end

  describe "snapshot" do
    test "returns the window Vigil.Events computes from the indexed event files" do
      during_event = ~U[2026-07-11 00:00:00Z] |> DateTime.shift_zone!("Europe/Berlin")

      snapshot = Store.snapshot(@store, during_event)

      assert MapSet.member?(snapshot.active_ids, "bike/via-carolina.md")
      assert Enum.any?(snapshot.near.active, &(&1.id == "bike/via-carolina.md"))
      assert snapshot.titles["bike/via-carolina.md"] == "Via Carolina"
    end

    # Exercises the exclude boundary, not just the empty-snapshot shape
    # (index_test.exs covers that directly): bike/via-carolina.md is the
    # vault's only event, and excluding its domain must keep it out of the
    # index entirely, not just out of this response.
    test "excluding the only event's domain leaves snapshot empty", %{
      vault: vault
    } do
      :ok = stop_supervised(Store)
      start_store(vault, exclude: ["bike"])

      now = ~U[2026-07-11 00:00:00Z] |> DateTime.shift_zone!("Europe/Berlin")
      snapshot = Store.snapshot(@store, now)

      assert snapshot == %{
               active_ids: MapSet.new(),
               near: %{active: [], upcoming: []},
               titles: %{}
             }
    end
  end

  # Traversal/absolute paths, skills/, and dot- or underscore-prefixed
  # segments are pure refusals with nothing to touch on disk or in git —
  # policy_test.exs, "path rules on :create", proves all four without a
  # vault. That includes the sharpest one: a test whose own name promised
  # "without touching disk" while building a git repository and a bare
  # remote to prove it.

  describe "naming conventions and path normalization" do
    test "an unclean path is slugified; success carries path_normalized_from", %{vault: vault} do
      assert {:ok,
              %{path: "bike/cafe-overview.md", path_normalized_from: "bike/Café Overview!!.md"}} =
               Store.call(@store, :create, %{
                 path: "bike/Café Overview!!.md",
                 type: "reference",
                 content: "# Café Overview\ntext"
               })

      assert File.exists?(Path.join(vault, "bike/cafe-overview.md"))
      refute File.exists?(Path.join(vault, "bike/Café Overview!!.md"))
    end

    test "an already-canonical path has no path_normalized_from key" do
      assert {:ok, result} =
               Store.call(@store, :create, %{
                 path: "bike/already-clean.md",
                 type: "reference",
                 content: "# X\nx"
               })

      refute Map.has_key?(result, :path_normalized_from)
    end

    # "journal's naming.pattern rejects a non-date filename and suggests
    # today's date" moved to policy_test.exs, "naming conventions", "a
    # filename that does not match the domain pattern is rejected with a
    # suggestion" — same rule, a mocked journal naming block in place of the
    # real one.

    test "journal's naming.pattern accepts a conforming date filename" do
      assert {:ok, _} =
               Store.call(@store, :create, %{
                 path: "journal/2026-02-02.md",
                 type: "reference",
                 content: "# Journal Entry Test Day\ntext",
                 force: true
               })
    end

    # The write resolves `today` from the same instant its response's
    # envelope was decided at (Vigil.MCP.Tools' `now:`), not a second clock
    # read of its own — pinned across a day boundary rather than by waiting
    # for midnight.
    test "the naming suggestion's date comes from the write's own `now`, not the wall clock" do
      now = ~U[2026-06-30 23:30:00Z] |> DateTime.shift_zone!("Europe/Berlin")

      assert {:error, msg} =
               Store.call(@store, :create, %{
                 path: "journal/not-a-date.md",
                 type: "reference",
                 content: "# X\nx",
                 now: now
               })

      assert msg =~ "journal/2026-07-01.md"
    end

    test "a domain without a naming block is unaffected" do
      assert {:ok, _} =
               Store.call(@store, :create, %{
                 path: "bike/any-name.md",
                 type: "reference",
                 content: "# X\nx"
               })
    end

    test "move_note normalizes and naming-checks the destination too" do
      assert {:error, msg} =
               Store.call(@store, :move_note, %{
                 from: "bike/terra-speed.md",
                 to: "journal/not-a-date.md",
                 confirm: true
               })

      assert msg =~ "does not match the schema"

      assert {:ok, %{to: "journal/2026-03-03.md"}} =
               Store.call(@store, :move_note, %{
                 from: "bike/terra-speed.md",
                 to: "journal/2026-03-03.md",
                 confirm: true
               })
    end
  end

  describe "rewrite_note" do
    test "replaces the body but keeps the frontmatter; requires confirm", %{vault: vault} do
      assert {:error, msg} =
               Store.call(@store, :rewrite_note, %{
                 path: "bike/terra-speed.md",
                 content: "# New\nCompletely new."
               })

      assert msg =~ "confirm: true"

      assert {:ok, _} =
               Store.call(@store, :rewrite_note, %{
                 path: "bike/terra-speed.md",
                 content: "# New\nCompletely new.",
                 confirm: true
               })

      raw = File.read!(Path.join(vault, "bike/terra-speed.md"))
      assert raw =~ "type: reference"
      assert raw =~ "Completely new."
      refute raw =~ "Dimensions"

      {:ok, result} = Store.call(@store, :read, %{id: "bike/terra-speed.md", backlinks: false})
      assert result.type == :reference
    end

    # The shrink gate's baseline is the note's own indexed heading count, asked
    # for by the policy rather than handed in. If that question never reaches
    # the policy the baseline reads as 0, nothing looks removed, and the gate
    # opens without a word.
    test "the shrink gate names the note's own heading count" do
      one_left = "# Via Carolina\n\n## Fueling\nbaseline."

      assert {:error, msg} =
               Store.call(@store, :rewrite_note, %{
                 path: "bike/via-carolina.md",
                 content: one_left
               })

      assert msg =~ "removes 2 of 3 headings"
    end

    test "confirm not required when the shrink stays under the threshold" do
      # via-carolina.md has 3 headings (Fueling, Second Half, Gear); this
      # removes only 1 — under both half-of-3 and the 20-heading floor.
      new_content = "# Via Carolina\n\n## Fueling\nbaseline.\n\n## Gear\nFrame bag."

      assert {:ok, _} =
               Store.call(@store, :rewrite_note, %{
                 path: "bike/via-carolina.md",
                 content: new_content
               })

      {:ok, result} = Store.call(@store, :read, %{id: "bike/via-carolina.md", backlinks: false})
      assert Enum.map(result.toc, & &1.heading) == ["Fueling", "Gear"]
    end

    test "confirm required when more than 20 headings would be removed, even under half", %{
      vault: vault
    } do
      many =
        for n <- 1..30, do: "## Section #{n}\nContent #{n}."

      assert {:ok, _} =
               Store.call(@store, :create, %{
                 path: "bike/many.md",
                 type: "reference",
                 content: "# Many Sections\n\n" <> Enum.join(many, "\n\n"),
                 force: true
               })

      few = for n <- 1..5, do: "## Section #{n}\nContent #{n}."
      few_content = "# Many Sections\n\n" <> Enum.join(few, "\n\n")

      assert {:error, msg} =
               Store.call(@store, :rewrite_note, %{path: "bike/many.md", content: few_content})

      assert msg =~ "removes 25 of 30 headings"

      assert {:ok, _} =
               Store.call(@store, :rewrite_note, %{
                 path: "bike/many.md",
                 content: few_content,
                 confirm: true
               })

      raw = File.read!(Path.join(vault, "bike/many.md"))
      refute raw =~ "Section 6"
    end
  end

  # Which lines are dropped is Vigil.Vault.Edit's job now and is covered
  # there (edit_test.exs) without git. This is the wiring smoke test.
  describe "delete_section" do
    test "removes the section; the index no longer resolves it" do
      assert {:ok, _} = Store.call(@store, :delete_section, %{id: "bike/via-carolina.md#gear"})

      assert {:error, _} =
               Store.call(@store, :read, %{id: "bike/via-carolina.md#gear", backlinks: false})
    end
  end

  # `Vigil.Markdown` states the trailing-newline rule once, for the whole-file
  # writes and the chunk-shaped ones alike (docs/design.md, "How a file is
  # written"). This is the wiring check that every path actually reaches it,
  # including with content that ends in blank lines.
  describe "how a written file ends" do
    test "every write path leaves exactly one trailing newline", %{vault: vault} do
      path = "bike/shape.md"
      abs_path = Path.join(vault, path)

      assert {:ok, _} =
               Store.call(@store, :create, %{
                 path: path,
                 type: "reference",
                 content: "# Shape\n\n## First\nFirst body.\n\n## Second\nSecond body.\n\n\n"
               })

      assert one_trailing_newline?(abs_path)

      assert {:ok, _} =
               Store.call(@store, :append, %{path: path, heading: "First", content: "More.\n\n"})

      assert one_trailing_newline?(abs_path)

      assert {:ok, _} =
               Store.call(@store, :replace_section, %{
                 id: "#{path}#second",
                 content: "Replaced.\n\n"
               })

      assert one_trailing_newline?(abs_path)

      assert {:ok, _} = Store.call(@store, :delete_section, %{id: "#{path}#second"})
      assert one_trailing_newline?(abs_path)

      assert {:ok, _} = Store.call(@store, :update_frontmatter, %{path: path, type: "decision"})
      assert one_trailing_newline?(abs_path)

      assert {:ok, _} =
               Store.call(@store, :rewrite_note, %{
                 path: path,
                 content: "# Shape\n\n## Only\nBody.\n\n\n"
               })

      assert one_trailing_newline?(abs_path)
    end
  end

  defp one_trailing_newline?(abs_path) do
    raw = File.read!(abs_path)
    String.ends_with?(raw, "\n") and not String.ends_with?(raw, "\n\n")
  end

  describe "update_frontmatter" do
    test "changes type without touching the body, no confirm needed" do
      assert {:ok, _} =
               Store.call(@store, :update_frontmatter, %{
                 path: "bike/terra-speed.md",
                 type: "decision"
               })

      {:ok, result} = Store.call(@store, :read, %{id: "bike/terra-speed.md", backlinks: false})
      assert result.type == :decision
      assert search(%{query: "tubeless"}) |> Enum.any?(&(&1.id =~ "terra-speed"))
    end

    # "enforces the same starts/ends rules as create" moved to
    # policy_test.exs, "update_frontmatter enforces the same content rules
    # as create".

    # A note without frontmatter is what adopting an existing vault turns up;
    # the parser indexes it as `reference` with a warning, and this is the
    # write that repairs it. The fixture vault carries one.
    test "gives a note without frontmatter the block it lacks, and it reindexes as that type", %{
      vault: vault
    } do
      path = "training/note-without-anything.md"
      body = File.read!(Path.join(vault, path))

      assert {:ok, _} = Store.call(@store, :update_frontmatter, %{path: path, type: "decision"})

      assert File.read!(Path.join(vault, path)) == "---\ntype: decision\n---\n" <> body

      {:ok, result} = Store.call(@store, :read, %{id: path, backlinks: false})
      assert result.type == :decision
    end

    test "refuses a note whose frontmatter block never closes, and says which case it is", %{
      vault: vault
    } do
      path = "bike/left-open.md"
      content = "---\ntype: decision\n# Left Open\n\n## Notes\nThe block never closes.\n"

      # Written by hand, outside vigil, and loaded the way such a note arrives.
      File.write!(Path.join(vault, path), content)
      assert %{reloaded: true} = Store.call(@store, :reload, %{})

      assert {:error, msg} =
               Store.call(@store, :update_frontmatter, %{path: path, type: "decision"})

      assert msg =~ "Unterminated frontmatter"
      assert File.read!(Path.join(vault, path)) == content
    end

    test "keeps the keys it does not own", %{vault: vault} do
      path = "bike/adopted.md"

      content =
        "---\naliases: [Adopted]\ntype: reference\ntags:\n  - bike\n---\n# Adopted\n\n## Notes\nBody.\n"

      File.write!(Path.join(vault, path), content)
      assert %{reloaded: true} = Store.call(@store, :reload, %{})

      assert {:ok, _} = Store.call(@store, :update_frontmatter, %{path: path, type: "decision"})

      assert File.read!(Path.join(vault, path)) ==
               String.replace(content, "type: reference", "type: decision")

      {:ok, result} = Store.call(@store, :read, %{id: path, backlinks: false})
      assert result.type == :decision
    end

    test "refuses frontmatter that does not parse, and writes nothing", %{vault: vault} do
      path = "bike/broken-yaml.md"
      content = "---\ntype: reference\ntags: [bike\n---\n# Broken\n\n## Notes\nBody.\n"

      File.write!(Path.join(vault, path), content)
      assert %{reloaded: true} = Store.call(@store, :reload, %{})

      assert {:error, msg} =
               Store.call(@store, :update_frontmatter, %{path: path, type: "decision"})

      assert msg =~ "does not parse"
      assert File.read!(Path.join(vault, path)) == content
    end
  end

  describe "rewrite_note on a note without frontmatter" do
    test "refuses, naming update_frontmatter as the way to give it one", %{vault: vault} do
      path = "training/note-without-anything.md"
      before = File.read!(Path.join(vault, path))

      assert {:error, msg} =
               Store.call(@store, :rewrite_note, %{path: path, content: "# Transfer\n\nNew."})

      assert msg =~ "update_frontmatter"
      assert File.read!(Path.join(vault, path)) == before
    end
  end

  describe "delete" do
    test "removes the note from disk and the index; requires confirm", %{vault: vault} do
      assert {:error, msg} = Store.call(@store, :delete_note, %{path: "bike/terra-speed.md"})
      assert msg =~ "confirm: true"

      assert {:ok, %{pushed: true}} =
               Store.call(@store, :delete_note, %{path: "bike/terra-speed.md", confirm: true})

      refute File.exists?(Path.join(vault, "bike/terra-speed.md"))

      assert {:error, _} =
               Store.call(@store, :read, %{id: "bike/terra-speed.md", backlinks: false})

      refute search(%{query: "tubeless"}) |> Enum.any?(&(&1.id =~ "terra-speed"))
    end

    test "reports broken backlinks in the same call when confirm is passed up front" do
      assert {:ok, %{broken_backlinks: broken_backlinks}} =
               Store.call(@store, :delete_note, %{path: "bike/terra-speed.md", confirm: true})

      assert "bike/via-carolina.md" in broken_backlinks
    end
  end

  describe "move" do
    test "renames the note, updates the index; requires confirm", %{vault: vault} do
      assert {:error, msg} =
               Store.call(@store, :move_note, %{
                 from: "bike/terra-speed.md",
                 to: "bike/terra-40c.md"
               })

      assert msg =~ "confirm: true"

      assert {:ok, %{pushed: true}} =
               Store.call(@store, :move_note, %{
                 from: "bike/terra-speed.md",
                 to: "bike/terra-40c.md",
                 confirm: true
               })

      refute File.exists?(Path.join(vault, "bike/terra-speed.md"))
      assert File.exists?(Path.join(vault, "bike/terra-40c.md"))

      assert {:error, _} =
               Store.call(@store, :read, %{id: "bike/terra-speed.md", backlinks: false})

      {:ok, result} = Store.call(@store, :read, %{id: "bike/terra-40c.md", backlinks: false})
      assert result.title == "WTB Terra Speed 40C"
    end

    test "rejects a destination that already exists" do
      assert {:error, msg} =
               Store.call(@store, :move_note, %{
                 from: "bike/terra-speed.md",
                 to: "bike/via-carolina.md",
                 confirm: true
               })

      assert msg =~ "already exists"
    end

    test "destination still runs through domain validation" do
      assert {:error, _} =
               Store.call(@store, :move_note, %{
                 from: "bike/terra-speed.md",
                 to: "unbekannt/x.md",
                 confirm: true
               })
    end
  end

  # docs/design.md, "No audit log": what a note went through is read back out
  # of the Git history, never kept a second time.
  describe "history" do
    defp history(path, limit \\ 20), do: Store.call(@store, :history, %{path: path, limit: limit})

    defp read_at(id, at), do: Store.call(@store, :read, %{id: id, at: at, backlinks: false})

    defp rename_terra_speed do
      {:ok, _} =
        Store.call(@store, :append, %{
          path: "bike/terra-speed.md",
          content: "Tubeless since June."
        })

      {:ok, _} =
        Store.call(@store, :move_note, %{
          from: "bike/terra-speed.md",
          to: "bike/terra-40c.md",
          confirm: true
        })
    end

    test "of a renamed note includes the commits from before the rename, newest first" do
      rename_terra_speed()

      assert {:ok, %{path: "bike/terra-40c.md", commits: commits}} = history("bike/terra-40c.md")

      assert [
               %{by: "vigil", author: "vigil", path: "bike/terra-40c.md", message: "move: " <> _},
               %{
                 by: "vigil",
                 author: "vigil",
                 path: "bike/terra-speed.md",
                 message: "append: " <> _
               },
               %{by: "human", author: "Daniel", path: "bike/terra-speed.md"}
             ] = commits

      assert Enum.all?(commits, &match?({:ok, _, _}, DateTime.from_iso8601(&1.date)))
    end

    test "answers at most limit commits, the newest" do
      rename_terra_speed()

      assert {:ok, %{commits: [%{message: "move: " <> _}]}} = history("bike/terra-40c.md", 1)
      assert {:ok, %{commits: [_, _]}} = history("bike/terra-40c.md", 2)
    end

    test "of a path with no history is not found, and an unsafe path is refused" do
      assert {:error, "Not found: bike/never-there.md"} = history("bike/never-there.md")
      assert {:error, "Invalid path"} = history("../outside.md")
    end

    test "read at a revision returns the text the note had then, under the name it had" do
      rename_terra_speed()
      {:ok, %{commits: [_move, append, initial]}} = history("bike/terra-40c.md")
      section = "bike/terra-speed.md#gravel-experience"

      assert {:ok, %{body: before, at: at}} = read_at(section, initial.commit)
      assert at == initial.commit
      assert before =~ "annoying"
      refute before =~ "Tubeless"

      assert {:ok, %{body: appended}} = read_at(section, append.commit)
      assert appended =~ "Tubeless since June."

      assert {:ok, %{path: "bike/terra-speed.md", title: "WTB Terra Speed 40C", toc: [_, _]}} =
               read_at("bike/terra-speed.md", initial.commit)
    end

    test "read at a revision returns a chunk as it was" do
      {:ok, %{commits: [initial]}} = history("bike/via-carolina.md")

      {:ok, _} =
        Store.call(@store, :replace_section, %{
          id: "bike/via-carolina.md#gear",
          content: "Only a frame bag now."
        })

      assert {:ok, %{heading: "Gear", body: body}} =
               read_at("bike/via-carolina.md#gear", initial.commit)

      assert body =~ "Frame bag, no saddle bag."

      assert {:ok, %{body: current}} =
               Store.call(@store, :read, %{id: "bike/via-carolina.md#gear", backlinks: false})

      assert current =~ "Only a frame bag now."
    end

    test "read at an unknown revision is an error" do
      assert {:error, "Unknown revision: no-such-revision"} =
               read_at("bike/via-carolina.md", "no-such-revision")

      assert {:error, "Unknown revision: --all"} = read_at("bike/via-carolina.md", "--all")
    end

    test "read at a revision the note did not exist in is not found" do
      {:ok, %{commits: [initial]}} = history("bike/via-carolina.md")

      assert {:error, "Not found: bike/never-there.md at " <> _} =
               read_at("bike/never-there.md", initial.commit)
    end
  end

  # Each finding's rule (duplicate headings, sentence-like headings, orphaned
  # links, overlong notes, stale decisions) is Vigil.Index's job now and is
  # covered there (index_test.exs) without git. This is the wiring smoke
  # test: a write lands in the report a :lint call returns.
  describe "lint" do
    test "reports duplicate headings, sentence-like headings, and orphaned links" do
      {:ok, _} =
        Store.call(@store, :create, %{
          path: "bike/messy.md",
          type: "reference",
          content:
            "# Messy\n\n## Duplicate\nOne.\n\n## Duplicate\nTwo.\n\n" <>
              "## This is a rather long heading with punctuation and a full stop.\nText.\n\n" <>
              "## Reference\nSee [[does-not-exist]].\n"
        })

      report = Store.call(@store, :lint, %{})

      assert Enum.any?(report.duplicate_headings, &(&1.path == "bike/messy.md"))
      assert Enum.any?(report.sentence_headings, &String.starts_with?(&1.id, "bike/messy.md"))
      assert "does-not-exist" in report.orphaned_links
    end
  end

  describe "skills isolation" do
    test "skills never appear in search, have no index chunk, no backlinks" do
      assert search(%{query: "TDD"}) == []
      assert search(%{query: "Failing Test"}) == []
    end

    # Thin end-to-end wiring check: a skill write reaches Vigil.Skills through
    # the GenServer — it commits and pushes in order with note writes
    # (docs/design.md, principle 2) — and what it wrote is not indexed as a
    # note. Full behavioral coverage (name validation, frontmatter validation,
    # SkillKey token) lives in test/vigil/skills_test.exs; the two skill reads
    # no longer go through this process at all and are covered in
    # test/vigil/mcp/tools_dispatch_test.exs.
    test "skill_write works end-to-end through the GenServer and is never indexed" do
      assert {:ok, %{name: "new", pushed: true}} =
               Store.call(@store, :skill_write, %{
                 name: "new",
                 content: "---\nname: new\ndescription: test skill\n---\n# New\n1. one"
               })

      assert File.read!(Path.join(Store.vault_path(@store), "skills/new.md")) =~ "1. one"
      assert search(%{query: "one"}) == []
    end

    # docs/design.md, "The write path": the vault path is published from
    # inside the writer, so a caller can ask where the vault is without
    # queueing behind whatever the writer is doing.
    test "the vault path is published, not asked for", %{vault: vault} do
      assert Store.vault_path(@store) == Path.expand(vault)
    end
  end

  # Creation date = first commit (docs/design.md, principle 3). A write is
  # never a note's first commit, and the index is what keeps that true —
  # Vigil.Index.put/2 would otherwise reset created_at to the write's own
  # commit time, on every write path at once.
  describe "created_at survives a write" do
    defp created_at(path) do
      {:ok, note} = Store.call(@store, :read, %{id: path, backlinks: false})
      note.created_at
    end

    test "append, rewrite_note and move_note all leave it alone" do
      before = created_at("bike/via-carolina.md")
      assert is_binary(before)

      assert {:ok, _} =
               Store.call(@store, :append, %{
                 path: "bike/via-carolina.md",
                 content: "One more line."
               })

      assert created_at("bike/via-carolina.md") == before

      assert {:ok, _} =
               Store.call(@store, :rewrite_note, %{
                 path: "bike/via-carolina.md",
                 content: "# Via Carolina\n\n## Fueling\nbaseline.\n\n## Gear\nFrame bag.",
                 confirm: true
               })

      assert created_at("bike/via-carolina.md") == before

      assert {:ok, _} =
               Store.call(@store, :move_note, %{
                 from: "bike/via-carolina.md",
                 to: "training/via-carolina.md",
                 confirm: true
               })

      assert created_at("training/via-carolina.md") == before
    end

    test "a note created now takes the creation date of its own commit" do
      assert {:ok, _} =
               Store.call(@store, :create, %{
                 path: "bike/brand-new.md",
                 type: "reference",
                 content: "# New\n\nx"
               })

      assert is_binary(created_at("bike/brand-new.md"))
    end

    test "a full reload still reports the git creation date" do
      before = created_at("bike/via-carolina.md")

      assert {:ok, _} =
               Store.call(@store, :append, %{
                 path: "bike/via-carolina.md",
                 content: "Another line."
               })

      assert %{reloaded: true} = Store.call(@store, :reload, %{})

      assert created_at("bike/via-carolina.md") == before
    end
  end

  describe "reload" do
    test "reload re-reads the vault and reports success" do
      assert %{reloaded: true} = Store.call(@store, :reload, %{})
      assert search(%{query: "tires"}) != []
    end

    test "reload with an unreachable remote reports pull_failed but still reparses", %{
      vault: vault
    } do
      :ok = stop_supervised(Store)
      start_store(vault, git_remote: "nonexistent-remote")

      assert %{reloaded: true, pull_failed: reason} = Store.call(@store, :reload, %{})
      assert is_binary(reason)
      assert search(%{query: "tires"}) != []
    end
  end

  # The branch is a setting: a vault on `master` is pulled and pushed as
  # `master`, and nothing on the way falls back to `main`.
  describe "a vault on another branch" do
    test "pulls, and pushes a write, on the branch it was handed", %{vault: vault} do
      :ok = stop_supervised(Store)
      {git, log} = CommitLog.recording(vault, remote: "github", branch: "master")
      start_store(vault, git: git, git_remote: "github", git_branch: "master")

      assert %{reloaded: true} = Store.call(@store, :reload, %{})

      assert {:ok, %{pushed: true}} =
               Store.call(@store, :create, %{
                 path: "bike/on-master.md",
                 type: "reference",
                 content: "# On master\ntext"
               })

      assert {:ok, %{pushed: true}} =
               Store.call(@store, :skill_write, %{
                 name: "on-master",
                 content: "---\nname: on-master\ndescription: x\n---\n# Skill\n"
               })

      calls = CommitLog.calls(log)
      # Boot, the reload, and one update before each of the two writes.
      assert Enum.count(calls, &(&1 == {:fetch, "github", "master"})) == 4
      assert Enum.count(calls, &(&1 == {:push, "github", "master"})) == 2
    end
  end

  # docs/design.md, "The server stays in step with the remote": a commit a
  # human pushed is adopted before the next write, without a `reload`, as long
  # as vigil holds no unpushed commit of its own — and `status` says where the
  # vault stands.
  describe "staying in step with the remote" do
    @human_note "---\ntype: reference\n---\n# From the human\nPushed from a clone.\n"

    defp recording_store(vault, opts \\ []) do
      :ok = stop_supervised(Store)
      {git, log} = CommitLog.recording(vault, remote: "origin")

      git =
        case Keyword.get(opts, :wrap, & &1) do
          wrap when is_function(wrap, 2) -> wrap.(git, log)
          wrap -> wrap.(git)
        end

      start_store(vault, git: git)
      log
    end

    # A push that fails the first `n` times it is asked, as a remote briefly
    # out of reach does, and then reaches the commit log's remote.
    defp failing_first_pushes(git, n) do
      asked = :counters.new(1, [])

      %{
        git
        | push: fn vault, remote, branch ->
            :counters.add(asked, 1, 1)

            if :counters.get(asked, 1) <= n,
              do: {:error, "unreachable"},
              else: git.push.(vault, remote, branch)
          end
      }
    end

    # A human who pushes between vigil's update and vigil's push, the first
    # `n` times vigil pushes: each of those pushes is refused as not a
    # fast-forward, as git refuses it.
    defp racing_pushes(git, log, n) do
      asked = :counters.new(1, [])

      %{
        git
        | push: fn vault, remote, branch ->
            :counters.add(asked, 1, 1)
            round = :counters.get(asked, 1)

            if n == :infinity or round <= n,
              do: CommitLog.push_from_elsewhere(log, "bike/raced-#{round}.md", @human_note)

            git.push.(vault, remote, branch)
          end
      }
    end

    # `force:` because what is created here is beside the point, and a note
    # adopted from the remote would otherwise count as its possible duplicate.
    defp create_note(path) do
      Store.call(@store, :create, %{
        path: path,
        type: "reference",
        content: "# Note\ntext",
        force: true
      })
    end

    test "a human pushes; the next write lands on top without a reload, and its push succeeds",
         %{vault: vault} do
      log = recording_store(vault)
      CommitLog.push_from_elsewhere(log, "bike/from-human.md", @human_note)

      assert {:ok, %{pushed: true}} = create_note("bike/after-human.md")

      assert File.read!(Path.join(vault, "bike/from-human.md")) == @human_note

      assert {:ok, %{title: "From the human"}} =
               Store.call(@store, :read, %{id: "bike/from-human.md", backlinks: false})

      assert [
               {:fetch, "origin", "main"},
               {:fetch, "origin", "main"},
               {:fast_forward, "origin", "main"},
               {:add, ["bike/after-human.md"]},
               {:commit, ["bike/after-human.md"], _message},
               {:push, "origin", "main"}
             ] = CommitLog.calls(log)
    end

    test "a skill write is brought up to date the same way", %{vault: vault} do
      log = recording_store(vault)
      CommitLog.push_from_elsewhere(log, "bike/from-human.md", @human_note)

      assert {:ok, %{pushed: true}} =
               Store.call(@store, :skill_write, %{
                 name: "in-step",
                 content: "---\nname: in-step\ndescription: x\n---\n# Skill\n"
               })

      assert File.exists?(Path.join(vault, "bike/from-human.md"))
    end

    test "with nothing pushed elsewhere, the write fetches and adopts nothing", %{vault: vault} do
      log = recording_store(vault)

      assert {:ok, %{pushed: true}} = create_note("bike/alone.md")

      calls = CommitLog.calls(log)
      assert {:fetch, "origin", "main"} in calls
      refute Enum.any?(calls, &match?({:fast_forward, _, _}, &1))
    end

    # docs/design.md, principle 2: vigil's own unpushed commits are rebased
    # onto what the human pushed, never merged, and the next push takes them
    # out together with the write's own.
    @tag :capture_log
    test "with an unpushed commit, the write rebases it onto what a human pushed, and its push takes both out",
         %{vault: vault} do
      log = recording_store(vault, wrap: &failing_first_pushes(&1, 1))

      assert {:ok, %{pushed: false}} = create_note("bike/first.md")
      before = length(CommitLog.calls(log))
      CommitLog.push_from_elsewhere(log, "bike/from-human.md", @human_note)

      assert {:ok, %{pushed: true} = result} = create_note("bike/second.md")
      refute Map.has_key?(result, :push_error)

      assert File.read!(Path.join(vault, "bike/from-human.md")) == @human_note
      assert File.exists?(Path.join(vault, "bike/first.md"))

      assert {:ok, %{title: "From the human"}} =
               Store.call(@store, :read, %{id: "bike/from-human.md", backlinks: false})

      assert [
               {:fetch, "origin", "main"},
               {:rebase, "origin", "main"},
               {:add, ["bike/second.md"]},
               {:commit, ["bike/second.md"], _message},
               {:push, "origin", "main"}
             ] = log |> CommitLog.calls() |> Enum.drop(before)

      assert %{ahead: 0, behind: 0} = Store.status(@store)
    end

    test "a push refused because the remote moved in the meantime is rebased and pushed again",
         %{vault: vault} do
      log = recording_store(vault, wrap: &racing_pushes(&1, &2, 1))

      assert {:ok, %{pushed: true} = result} = create_note("bike/raced.md")
      refute Map.has_key?(result, :push_error)

      calls = CommitLog.calls(log)
      assert Enum.count(calls, &match?({:push, _, _}, &1)) == 2
      assert {:rebase, "origin", "main"} in calls

      # What the rebase brought in is in the index, not only on disk.
      assert {:ok, %{title: "From the human"}} =
               Store.call(@store, :read, %{id: "bike/raced-1.md", backlinks: false})

      assert %{ahead: 0, behind: 0, last_push: %{pushed: true}} = Store.status(@store)
    end

    @tag :capture_log
    test "a push the remote keeps refusing is retried a bounded number of times, and says so",
         %{vault: vault} do
      log = recording_store(vault, wrap: &racing_pushes(&1, &2, :infinity))

      assert {:ok, %{pushed: false, push_error: msg}} = create_note("bike/raced.md")
      assert msg =~ "Change saved and committed locally, but push failed"
      assert msg =~ "pushed again 3 times"

      calls = CommitLog.calls(log)
      assert Enum.count(calls, &match?({:push, _, _}, &1)) == 4
      assert %{last_push: %{pushed: false, error: ^msg}} = Store.status(@store)
    end

    # A real conflict is a human's to resolve: the rebase is aborted, vigil's
    # commit stays local, and what the human pushed stays on the remote,
    # untouched — the response says which path is in the way.
    @tag :capture_log
    test "a rebase that conflicts is aborted, keeps the local commit and names the path",
         %{vault: vault} do
      log = recording_store(vault, wrap: &failing_first_pushes(&1, 1))
      path = "bike/via-carolina.md"

      assert {:ok, %{pushed: false}} =
               Store.call(@store, :replace_section, %{id: "#{path}#gear", content: "Ours."})

      ours = File.read!(Path.join(vault, path))
      CommitLog.push_from_elsewhere(log, path, @human_note)

      assert {:ok, %{pushed: false, push_error: msg}} = create_note("bike/other.md")
      assert msg =~ "conflicts in #{path}"
      assert msg =~ "a human has to resolve"

      assert File.read!(Path.join(vault, path)) == ours
      assert Enum.count(CommitLog.calls(log), &(&1 == :abort_rebase)) == 2

      assert %{ahead: 2, behind: 1, last_push: %{pushed: false, error: ^msg}} =
               Store.status(@store)
    end

    test "an edit whose section the update took away is refused and asks for a fresh read",
         %{vault: vault} do
      log = recording_store(vault)
      path = "bike/via-carolina.md"
      theirs = "---\ntype: reference\n---\n# Via Carolina\n\n## Wheels\nRenamed.\n"
      CommitLog.push_from_elsewhere(log, path, theirs)

      assert {:error, msg} =
               Store.call(@store, :replace_section, %{id: "#{path}#gear", content: "x"})

      assert msg =~ "#{path}#gear no longer resolves"
      assert msg =~ "Read it again"
      assert File.read!(Path.join(vault, path)) == theirs
    end

    # docs/design.md, Security model item 3: the load adopts what was pushed
    # elsewhere the way a write does, and vigil's unpushed commits survive it.
    @tag :capture_log
    test "reload with an unpushed commit and a moved remote ends with both histories",
         %{vault: vault} do
      log = recording_store(vault, wrap: &failing_first_pushes(&1, 1))
      {:ok, %{pushed: false}} = create_note("bike/unpushed.md")
      CommitLog.push_from_elsewhere(log, "bike/from-human.md", @human_note)

      assert %{reloaded: true} = result = Store.call(@store, :reload, %{})
      refute Map.has_key?(result, :pull_failed)

      assert File.exists?(Path.join(vault, "bike/unpushed.md"))

      assert {:ok, %{title: "From the human"}} =
               Store.call(@store, :read, %{id: "bike/from-human.md", backlinks: false})

      assert %{ahead: 1, behind: 0} = Store.status(@store)
    end

    @tag :capture_log
    test "boot with an unpushed commit and a moved remote ends with both histories",
         %{vault: vault} do
      :ok = stop_supervised(Store)
      {git, log} = CommitLog.recording(vault, remote: "origin")
      start_store(vault, git: failing_first_pushes(git, 1))
      {:ok, %{pushed: false}} = create_note("bike/unpushed.md")
      :ok = stop_supervised(Store)
      CommitLog.push_from_elsewhere(log, "bike/from-human.md", @human_note)

      start_store(vault, git: git)

      assert {:ok, %{title: "Note"}} =
               Store.call(@store, :read, %{id: "bike/unpushed.md", backlinks: false})

      assert {:ok, %{title: "From the human"}} =
               Store.call(@store, :read, %{id: "bike/from-human.md", backlinks: false})

      assert %{ahead: 1, behind: 0} = Store.status(@store)
    end

    @tag :capture_log
    test "reload with a conflicting unpushed commit reports the path and keeps the commit",
         %{vault: vault} do
      log = recording_store(vault, wrap: &failing_first_pushes(&1, 1))
      path = "bike/via-carolina.md"
      {:ok, _} = Store.call(@store, :replace_section, %{id: "#{path}#gear", content: "Ours."})
      ours = File.read!(Path.join(vault, path))
      CommitLog.push_from_elsewhere(log, path, @human_note)

      assert %{reloaded: true, pull_failed: reason} = Store.call(@store, :reload, %{})
      assert reason =~ "conflicts in #{path}"
      assert File.read!(Path.join(vault, path)) == ours
    end

    @tag :capture_log
    test "a fetch that fails leaves the write to go ahead on the vault as it was",
         %{vault: vault} do
      recording_store(vault,
        wrap: fn git -> %{git | fetch: fn _, _, _ -> {:error, "timed out"} end} end
      )

      assert {:ok, %{pushed: true}} = create_note("bike/despite.md")
    end

    test "status: a fresh writer is healthy, in step, and has not pushed yet", %{vault: vault} do
      recording_store(vault)

      assert %{
               healthy: true,
               index_loaded: true,
               writer_answers: true,
               ahead: 0,
               behind: 0,
               last_push: nil
             } = Store.status(@store)
    end

    test "status: the last push and its time, and what a human pushed once it is fetched",
         %{vault: vault} do
      log = recording_store(vault)

      {:ok, _} = create_note("bike/pushed.md")
      assert %{last_push: %{pushed: true, at: %DateTime{}}, ahead: 0} = Store.status(@store)

      # Seen as behind only once a fetch has brought it into view.
      CommitLog.push_from_elsewhere(log, "bike/from-human.md", @human_note)
      assert %{behind: 0} = Store.status(@store)
    end

    @tag :capture_log
    test "status: a failed push, with git's reason, and the commit it left ahead",
         %{vault: vault} do
      recording_store(vault,
        wrap: fn git -> %{git | push: fn _, _, _ -> {:error, "unreachable"} end} end
      )

      {:ok, _} = create_note("bike/stuck.md")

      assert %{ahead: 1, behind: 0, last_push: %{pushed: false, at: %DateTime{}, error: error}} =
               Store.status(@store)

      assert error =~ "unreachable"
    end

    test "status: a writer that does not answer is reported, not waited on", %{vault: vault} do
      recording_store(vault)
      writer = Process.whereis(@store)
      :ok = :sys.suspend(writer)

      try do
        assert %{healthy: false, writer_answers: false, index_loaded: true, ahead: nil} =
                 Store.status(@store, 50)
      after
        :sys.resume(writer)
      end
    end

    test "status: no writer at all is neither loaded nor answering" do
      assert %{healthy: false, writer_answers: false, index_loaded: false} =
               Store.status(:"#{__MODULE__}.NoSuchWriter", 50)
    end

    @tag :capture_log
    test "a failed push emits a telemetry event", %{vault: vault} do
      recording_store(vault,
        wrap: fn git -> %{git | push: fn _, _, _ -> {:error, "unreachable"} end} end
      )

      test_process = self()
      handler = "push-failed-#{inspect(self())}"

      :telemetry.attach(
        handler,
        [:vigil, :push, :failed],
        fn event, measurements, metadata, _config ->
          if metadata.vault_path == vault,
            do: send(test_process, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      {:ok, %{pushed: false}} = create_note("bike/unpushed.md")

      assert_received {:telemetry, [:vigil, :push, :failed], %{count: 1},
                       %{remote: "origin", branch: "main", reason: "unreachable"}}
    end
  end

  # docs/design.md, "Reads see what another clone pushed": a read brings the
  # vault up to date first, the way a write does, but at most once per
  # interval, with a fetch bounded by a timeout of its own. Time is the
  # writer's `clock_ms`, advanced by hand, so "within one interval" is stated
  # rather than slept through.
  describe "reads see what another clone pushed" do
    @elsewhere "---\ntype: reference\n---\n# Pushed elsewhere\nA zanzibar quokka.\n"

    defp freshening_store(vault, opts \\ []) do
      :ok = stop_supervised(Store)
      {git, log} = CommitLog.recording(vault, remote: "origin")
      git = Keyword.get(opts, :wrap, & &1).(git)
      clock = :counters.new(1, [])

      start_supervised!(
        {Store,
         vault_path: vault,
         git: git,
         name: @store,
         read_fetch_interval: Keyword.get(opts, :interval, 60),
         read_fetch_timeout: Keyword.get(opts, :timeout, 5_000),
         clock_ms: fn -> :counters.get(clock, 1) end}
      )

      {log, clock}
    end

    defp advance(clock, seconds), do: :counters.add(clock, 1, seconds * 1_000)

    defp fetches(log), do: Enum.count(CommitLog.calls(log), &match?({:fetch, _, _}, &1))

    defp quokkas, do: search(%{query: "zanzibar quokka"})

    # A fetch that answers `answer` from its `n`-th call on; the ones before
    # it — the load at boot — reach the commit log's remote as usual.
    defp fetch_from(git, n, answer) do
      asked = :counters.new(1, [])

      %{
        git
        | fetch: fn vault, remote, branch ->
            :counters.add(asked, 1, 1)

            if :counters.get(asked, 1) >= n,
              do: answer.(),
              else: git.fetch.(vault, remote, branch)
          end
      }
    end

    test "a commit pushed from another clone shows up in search within one interval, with no reload",
         %{vault: vault} do
      {log, clock} = freshening_store(vault)
      CommitLog.push_from_elsewhere(log, "bike/elsewhere.md", @elsewhere)

      # The load at boot fetched a moment ago: the read does not fetch again.
      assert quokkas() == []

      advance(clock, 60)

      assert [%{id: "bike/elsewhere.md" <> _} | _] = quokkas()
    end

    test "a commit pushed from another clone shows up in history within one interval",
         %{vault: vault} do
      {log, clock} = freshening_store(vault)
      CommitLog.push_from_elsewhere(log, "bike/elsewhere.md", @elsewhere)

      assert {:error, "Not found: " <> _} =
               Store.call(@store, :history, %{path: "bike/elsewhere.md", limit: 20})

      advance(clock, 60)

      assert {:ok, %{commits: [%{by: "human", author: "Daniel"}]}} =
               Store.call(@store, :history, %{path: "bike/elsewhere.md", limit: 20})
    end

    test "within one interval no second fetch happens, whichever read asks", %{vault: vault} do
      {log, clock} = freshening_store(vault)
      assert fetches(log) == 1

      advance(clock, 60)
      quokkas()
      assert fetches(log) == 2

      quokkas()
      Store.call(@store, :read, %{id: "bike/via-carolina.md", backlinks: false})
      Store.call(@store, :links, %{id: "bike/via-carolina.md", direction: :both, depth: 1})
      Store.call(@store, :lint, %{})
      Store.call(@store, :current, %{})
      advance(clock, 59)
      quokkas()
      assert fetches(log) == 2

      advance(clock, 1)

      for op <- [:lint, :current] do
        Store.call(@store, op, %{})
        advance(clock, 60)
      end

      assert fetches(log) == 4
    end

    test "a write's fetch counts: a read right after it does not fetch again", %{vault: vault} do
      {log, clock} = freshening_store(vault)
      advance(clock, 60)

      {:ok, _} =
        Store.call(@store, :create, %{
          path: "bike/written.md",
          type: "reference",
          content: "# Written\ntext",
          force: true
        })

      assert fetches(log) == 2
      quokkas()
      assert fetches(log) == 2
    end

    test "an interval of 0 turns it off", %{vault: vault} do
      {log, clock} = freshening_store(vault, interval: 0)
      CommitLog.push_from_elsewhere(log, "bike/elsewhere.md", @elsewhere)
      advance(clock, 3_600)

      assert quokkas() == []
      assert fetches(log) == 1
    end

    test "the index is rebuilt only when the remote moved", %{vault: vault} do
      loads = :counters.new(1, [])

      counting = fn git ->
        %{
          git
          | log_metadata: fn vault ->
              :counters.add(loads, 1, 1)
              git.log_metadata.(vault)
            end
        }
      end

      {log, clock} = freshening_store(vault, wrap: counting)
      assert :counters.get(loads, 1) == 1

      advance(clock, 60)
      quokkas()
      assert :counters.get(loads, 1) == 1

      CommitLog.push_from_elsewhere(log, "bike/elsewhere.md", @elsewhere)
      advance(clock, 60)
      quokkas()
      assert :counters.get(loads, 1) == 2
    end

    @tag :capture_log
    test "an unreachable remote: the read succeeds from the current index, flagged, and status says so",
         %{vault: vault} do
      {_log, clock} =
        freshening_store(vault,
          wrap: &fetch_from(&1, 2, fn -> {:error, "fatal: unable to access remote"} end)
        )

      assert %{stale: nil} = Store.status(@store)
      advance(clock, 60)

      assert {:stale, [_ | _] = hits} = search(%{query: "tires"})
      assert Enum.all?(hits, &Map.has_key?(&1, :preview))

      assert %{healthy: true, stale: %{at: %DateTime{}, error: error}} = Store.status(@store)
      assert error =~ "unable to access remote"

      # Flagged for as long as the vault stays behind: the next read in the
      # interval does not fetch, and is still answered from the old index.
      assert {:stale, {:ok, _note}} =
               Store.call(@store, :read, %{id: "bike/via-carolina.md", backlinks: false})
    end

    @tag :capture_log
    test "the flag is lifted by the next update that succeeds", %{vault: vault} do
      reachable = :atomics.new(1, [])

      flaky = fn git ->
        %{
          git
          | fetch: fn vault, remote, branch ->
              if :atomics.get(reachable, 1) == 1,
                do: git.fetch.(vault, remote, branch),
                else: {:error, "unreachable"}
            end
        }
      end

      :atomics.put(reachable, 1, 1)
      {_log, clock} = freshening_store(vault, wrap: flaky)

      :atomics.put(reachable, 1, 0)
      advance(clock, 60)
      assert {:stale, _} = quokkas()

      :atomics.put(reachable, 1, 1)
      advance(clock, 60)
      assert quokkas() == []
      assert %{stale: nil} = Store.status(@store)
    end

    @tag :capture_log
    test "a fetch that does not answer delays the read by its timeout, once per interval",
         %{vault: vault} do
      {_log, clock} =
        freshening_store(vault,
          timeout: 50,
          wrap:
            &fetch_from(&1, 2, fn ->
              Process.sleep(2_000)
              :ok
            end)
        )

      advance(clock, 60)

      {micros, answer} = :timer.tc(fn -> search(%{query: "tires"}) end)
      assert {:stale, [_ | _]} = answer
      assert micros < 1_000_000

      assert %{stale: %{error: error}} = Store.status(@store)
      assert error =~ "did not answer within 50 ms"

      # The next read in the interval does not ask again.
      {micros, _answer} = :timer.tc(fn -> search(%{query: "tires"}) end)
      assert micros < 50_000
    end
  end

  # docs/design.md, "The write path": perform the action, commit, reparse into
  # the index, then push. Until git became a value this was the one part of the
  # write path no test could fail on, because exercising it meant building a
  # repository. An adapter that records its calls can be asked what order they
  # came in.
  #
  # One clause in Vigil.Store executes all three plan actions, and all three are
  # driven through it here: what the adapter was asked to do, in what order, and
  # where the index stood by the time the last of those calls came in.
  describe "the order a plan is executed in" do
    # The fetches are the update before the write and the one after its failed
    # push (docs/design.md, "The server stays in step with the remote").
    test "perform, commit, reparse, push", %{vault: vault} do
      :ok = stop_supervised(Store)
      test_process = self()
      {git, log} = CommitLog.recording(vault, remote: "origin")

      # The commit is asked for after the file is written, so what the adapter
      # finds on disk when it is called answers "was the action performed
      # first?".
      git = %{
        git
        | add: fn vault_path, [path] = paths ->
            send(test_process, {:on_disk, File.read(Path.join(vault_path, path))})
            git.add.(vault_path, paths)
          end
      }

      start_store(vault, git: git, git_remote: "nonexistent-remote")

      assert {:ok, %{pushed: false, push_error: msg}} =
               Store.call(@store, :create, %{
                 path: "bike/ordered.md",
                 type: "reference",
                 content: "# Ordered\ntext"
               })

      assert msg =~ "Change saved and committed locally, but push failed"

      assert_received {:on_disk, {:ok, content}}
      assert content =~ "Ordered"

      assert [
               {:fetch, "nonexistent-remote", "main"},
               {:fetch, "nonexistent-remote", "main"},
               {:add, ["bike/ordered.md"]},
               {:commit, ["bike/ordered.md"], "create: bike/ordered.md — # Ordered"},
               {:push, "nonexistent-remote", "main"},
               {:fetch, "nonexistent-remote", "main"}
             ] = CommitLog.calls(log)

      # The push failed and the note is in the index regardless, which it can
      # only be if the reparse ran before the push rather than after it.
      assert {:ok, %{title: "Ordered"}} =
               Store.call(@store, :read, %{id: "bike/ordered.md", backlinks: false})
    end

    # A delete and a move are one call each — `git rm` and `git mv` perform the
    # action and commit it in the same breath — so what these two pin is the
    # rest of the order: the effect, then the index, then the push.
    #
    # The index is read at push time, through the event notes the writer
    # publishes: that is the one reading of it available from outside the
    # mailbox, and a call into the writer from in here would deadlock behind
    # the write in progress. Both act on the fixture's one event note, so what
    # the publication says is the whole answer.
    defp start_push_probing_store(vault, test_process) do
      {git, log} = CommitLog.recording(vault, remote: "origin")

      probing = %{
        git
        | push: fn vault_path, remote, branch ->
            send(test_process, {:events_at_push, :ets.lookup_element(@store, :events, 2)})
            git.push.(vault_path, remote, branch)
          end
      }

      start_store(vault, git: probing, git_remote: "nonexistent-remote")
      log
    end

    test "a delete: remove and commit, index, push", %{vault: vault} do
      :ok = stop_supervised(Store)
      log = start_push_probing_store(vault, self())

      assert {:ok, %{pushed: false, push_error: msg}} =
               Store.call(@store, :delete_note, %{path: "bike/via-carolina.md", confirm: true})

      assert msg =~ "Deletion committed locally, but push failed"

      assert [
               {:fetch, "nonexistent-remote", "main"},
               {:fetch, "nonexistent-remote", "main"},
               {:remove, ["bike/via-carolina.md"]},
               {:commit, ["bike/via-carolina.md"], "delete: bike/via-carolina.md"},
               {:push, "nonexistent-remote", "main"},
               {:fetch, "nonexistent-remote", "main"}
             ] = CommitLog.calls(log)

      assert_received {:events_at_push, []}
    end

    test "a move: rename and commit, index, push", %{vault: vault} do
      :ok = stop_supervised(Store)
      log = start_push_probing_store(vault, self())

      assert {:ok, %{pushed: false, push_error: msg}} =
               Store.call(@store, :move_note, %{
                 from: "bike/via-carolina.md",
                 to: "bike/via-carolina-2026.md",
                 confirm: true
               })

      assert msg =~ "Move committed locally, but push failed"

      assert [
               {:fetch, "nonexistent-remote", "main"},
               {:fetch, "nonexistent-remote", "main"},
               {:move, "bike/via-carolina.md", "bike/via-carolina-2026.md"},
               {:commit, ["bike/via-carolina.md", "bike/via-carolina-2026.md"],
                "move: bike/via-carolina.md -> bike/via-carolina-2026.md"},
               {:push, "nonexistent-remote", "main"},
               {:fetch, "nonexistent-remote", "main"}
             ] = CommitLog.calls(log)

      assert_received {:events_at_push, [%{path: "bike/via-carolina-2026.md"}]}
    end
  end

  describe "write-path robustness" do
    test "a write whose commit fails leaves the file as it was", %{vault: vault} do
      :ok = stop_supervised(Store)
      git = %{CommitLog.new(vault) | commit: fn _, _, _ -> {:error, "boom"} end}
      start_store(vault, git: git)

      path = Path.join(vault, "bike/terra-speed.md")
      before = File.read!(path)

      assert {:error, "git commit failed: boom"} =
               Store.call(@store, :append, %{path: "bike/terra-speed.md", content: "More"})

      assert File.read!(path) == before

      assert {:error, "git commit failed: boom"} =
               Store.call(@store, :create, %{
                 path: "bike/brand-new.md",
                 type: "reference",
                 content: "# Brand new\ntext"
               })

      refute File.exists?(Path.join(vault, "bike/brand-new.md"))
    end

    test "a delete or a move whose commit fails leaves the note where it was", %{vault: vault} do
      :ok = stop_supervised(Store)
      git = %{CommitLog.new(vault) | commit: fn _, _, _ -> {:error, "boom"} end}
      start_store(vault, git: git)

      path = Path.join(vault, "bike/via-carolina.md")
      before = File.read!(path)

      assert {:error, "git rm/commit failed: boom"} =
               Store.call(@store, :delete_note, %{path: "bike/via-carolina.md", confirm: true})

      assert File.read!(path) == before

      assert {:error, "git mv/commit failed: boom"} =
               Store.call(@store, :move_note, %{
                 from: "bike/via-carolina.md",
                 to: "bike/via-carolina-2026.md",
                 confirm: true
               })

      assert File.read!(path) == before
      refute File.exists?(Path.join(vault, "bike/via-carolina-2026.md"))

      assert {:ok, %{path: "bike/via-carolina.md"}} =
               Store.call(@store, :read, %{id: "bike/via-carolina.md", backlinks: false})
    end

    test "push failure is a success that says it was not pushed; read and search keep working", %{
      vault: vault
    } do
      :ok = stop_supervised(Store)
      start_store(vault, git_remote: "nonexistent-remote")

      assert {:ok, %{pushed: false, push_error: msg}} =
               Store.call(@store, :create, %{
                 path: "bike/new.md",
                 type: "reference",
                 content: "# New\ntext"
               })

      assert msg =~ "push failed"
      assert File.exists?(Path.join(vault, "bike/new.md"))

      assert search(%{query: "tires"}) != []
      assert {:ok, _} = Store.call(@store, :read, %{id: "bike/via-carolina.md", backlinks: false})
    end

    # The index is updated between commit and push for every write action
    # (docs/design.md, "The write path"), the git-level ones included: the note
    # is gone from the repository, so it must be gone from the index too, push
    # or no push.
    test "a delete whose push fails still leaves the index without the note", %{vault: vault} do
      :ok = stop_supervised(Store)
      start_store(vault, git_remote: "nonexistent-remote")

      assert {:ok, %{pushed: false, push_error: msg}} =
               Store.call(@store, :delete_note, %{path: "bike/terra-speed.md", confirm: true})

      assert msg =~ "Deletion committed locally, but push failed"
      refute File.exists?(Path.join(vault, "bike/terra-speed.md"))

      assert {:error, _} =
               Store.call(@store, :read, %{id: "bike/terra-speed.md", backlinks: false})

      refute search(%{query: "tubeless"}) |> Enum.any?(&(&1.id =~ "terra-speed"))
    end

    test "a move whose push fails still leaves the index at the new path", %{vault: vault} do
      :ok = stop_supervised(Store)
      start_store(vault, git_remote: "nonexistent-remote")

      assert {:ok, %{pushed: false, push_error: msg}} =
               Store.call(@store, :move_note, %{
                 from: "bike/terra-speed.md",
                 to: "bike/terra-40c.md",
                 confirm: true
               })

      assert msg =~ "Move committed locally, but push failed"

      assert {:error, _} =
               Store.call(@store, :read, %{id: "bike/terra-speed.md", backlinks: false})

      assert {:ok, _} = Store.call(@store, :read, %{id: "bike/terra-40c.md", backlinks: false})
    end

    test "writing into a read-only domain directory returns a precise error, store stays alive",
         %{
           vault: vault
         } do
      dir = Path.join(vault, "home")
      File.chmod!(dir, 0o555)

      result =
        Store.call(@store, :create, %{
          path: "home/new.md",
          type: "reference",
          content: "# New\ntext"
        })

      File.chmod!(dir, 0o755)

      assert {:error, msg} = result
      assert msg =~ "Could not write file"

      assert {:ok, _} =
               Store.call(@store, :read, %{id: "home/diacritics-äöü-café.md", backlinks: false})
    end

    test "append against an unreadable file returns a clean error, store stays alive", %{
      vault: vault
    } do
      path = Path.join(vault, "bike/via-carolina.md")
      File.chmod!(path, 0o000)

      result = Store.call(@store, :append, %{path: "bike/via-carolina.md", content: "Extra."})

      File.chmod!(path, 0o644)

      assert {:error, msg} = result
      assert msg =~ "Could not read file"
      assert search(%{query: "tires"}) != []
      assert {:ok, _} = Store.call(@store, :read, %{id: "bike/via-carolina.md", backlinks: false})
    end

    test "replace_section against an unreadable file returns a clean error, store stays alive", %{
      vault: vault
    } do
      path = Path.join(vault, "bike/via-carolina.md")
      File.chmod!(path, 0o000)

      result =
        Store.call(@store, :replace_section, %{
          id: "bike/via-carolina.md#fueling",
          content: "New strategy."
        })

      File.chmod!(path, 0o644)

      assert {:error, msg} = result
      assert msg =~ "Could not read file"
      assert search(%{query: "tires"}) != []
      assert {:ok, _} = Store.call(@store, :read, %{id: "bike/via-carolina.md", backlinks: false})
    end

    test "delete_section against an unreadable file returns a clean error, store stays alive", %{
      vault: vault
    } do
      path = Path.join(vault, "bike/via-carolina.md")
      File.chmod!(path, 0o000)

      result = Store.call(@store, :delete_section, %{id: "bike/via-carolina.md#gear"})

      File.chmod!(path, 0o644)

      assert {:error, msg} = result
      assert msg =~ "Could not read file"
      assert search(%{query: "tires"}) != []
      assert {:ok, _} = Store.call(@store, :read, %{id: "bike/via-carolina.md", backlinks: false})
    end

    test "rewrite_note against an unreadable file returns a clean error, store stays alive", %{
      vault: vault
    } do
      path = Path.join(vault, "bike/terra-speed.md")
      File.chmod!(path, 0o000)

      result =
        Store.call(@store, :rewrite_note, %{
          path: "bike/terra-speed.md",
          content: "# New\nCompletely new.",
          confirm: true
        })

      File.chmod!(path, 0o644)

      assert {:error, msg} = result
      assert msg =~ "Could not read file"
      assert search(%{query: "tires"}) != []
      assert {:ok, _} = Store.call(@store, :read, %{id: "bike/terra-speed.md", backlinks: false})
    end

    test "update_frontmatter against an unreadable file returns a clean error, store stays alive",
         %{vault: vault} do
      path = Path.join(vault, "bike/terra-speed.md")
      File.chmod!(path, 0o000)

      result =
        Store.call(@store, :update_frontmatter, %{path: "bike/terra-speed.md", type: "decision"})

      File.chmod!(path, 0o644)

      assert {:error, msg} = result
      assert msg =~ "Could not read file"
      assert search(%{query: "tires"}) != []
      assert {:ok, _} = Store.call(@store, :read, %{id: "bike/terra-speed.md", backlinks: false})
    end
  end

  # The out/in cascade, ambiguous/broken statuses, depth-2 neighbors, hub
  # attachment and read's link counters are Vigil.Index's job now and are
  # covered there (index_test.exs) without git. "links tool works via a
  # lenient path" below is the wiring smoke test; the rest here exercise a
  # write's effect on the index's link picture (move, delete, rewrite), not
  # link resolution itself.
  describe "links" do
    test "links tool works via a lenient (non-canonical) path" do
      {:ok, result} =
        Store.call(@store, :links, %{id: "bike/Via Carolina!!.md", direction: :out, depth: 1})

      assert result.id == "bike/via-carolina.md"
    end

    test "move_note reports broken_backlinks for a link that no longer resolves, keeps a still-resolving one out" do
      assert {:ok, _} =
               Store.call(@store, :create, %{
                 path: "bike/references-explicitly.md",
                 type: "reference",
                 content: "# References Terra Speed\nSee [Terra Speed](bike/terra-speed.md)."
               })

      assert {:ok, result} =
               Store.call(@store, :move_note, %{
                 from: "bike/terra-speed.md",
                 to: "training/terra-speed.md",
                 confirm: true
               })

      assert "bike/references-explicitly.md" in result.broken_backlinks
      refute "bike/via-carolina.md" in result.broken_backlinks
    end

    test "move_note with update_links rewrites every linking note in the move's commit", %{
      vault: vault
    } do
      :ok = stop_supervised(Store)
      {git, log} = CommitLog.recording(vault)
      start_store(vault, git: git)

      explicit = "# Explicit\nSee [the dims](bike/terra-speed.md#dimensions).\n"
      File.write!(Path.join(vault, "bike/explicit.md"), "---\ntype: reference\n---\n" <> explicit)
      assert %{reloaded: true} = Store.call(@store, :reload, %{})

      assert {:ok, result} =
               Store.call(@store, :move_note, %{
                 from: "bike/terra-speed.md",
                 to: "training/terra-40c.md",
                 confirm: true,
                 update_links: true
               })

      assert result.broken_backlinks == []
      assert Enum.sort(result.updated_links) == ["bike/explicit.md", "bike/via-carolina.md"]

      assert File.read!(Path.join(vault, "bike/via-carolina.md")) =~
               "Tires: [[terra-40c|Terra Speed]]."

      assert File.read!(Path.join(vault, "bike/explicit.md")) =~
               "See [the dims](training/terra-40c.md#dimensions)."

      assert [{:commit, committed, "move: bike/terra-speed.md -> training/terra-40c.md"}] =
               Enum.filter(CommitLog.calls(log), &match?({:commit, _, _}, &1))

      assert Enum.sort(committed) ==
               [
                 "bike/explicit.md",
                 "bike/terra-speed.md",
                 "bike/via-carolina.md",
                 "training/terra-40c.md"
               ]

      # The index agrees with the vault: both notes link to the note at its new path.
      assert {:ok, incoming} =
               Store.call(@store, :links, %{id: "training/terra-40c.md", direction: :in, depth: 1})

      sources = Enum.map(incoming.incoming, & &1.source) |> Enum.uniq() |> Enum.sort()
      assert sources == ["bike/explicit.md", "bike/via-carolina.md"]

      assert {:ok, out} =
               Store.call(@store, :links, %{id: "bike/explicit.md", direction: :out, depth: 1})

      assert [%{status: "ok", target: "training/terra-40c.md#dimensions"}] = out.outgoing
    end

    test "move_note without update_links leaves the linking notes as they were", %{vault: vault} do
      before = File.read!(Path.join(vault, "bike/via-carolina.md"))

      assert {:ok, result} =
               Store.call(@store, :move_note, %{
                 from: "bike/terra-speed.md",
                 to: "training/terra-40c.md",
                 confirm: true
               })

      assert result.broken_backlinks == ["bike/via-carolina.md"]
      refute Map.has_key?(result, :updated_links)
      assert File.read!(Path.join(vault, "bike/via-carolina.md")) == before
    end

    test "move_note with update_links whose commit fails leaves every file as it was", %{
      vault: vault
    } do
      :ok = stop_supervised(Store)
      git = %{CommitLog.new(vault) | commit: fn _, _, _ -> {:error, "boom"} end}
      start_store(vault, git: git)

      paths = ["bike/terra-speed.md", "bike/via-carolina.md"]
      before = Map.new(paths, &{&1, File.read!(Path.join(vault, &1))})

      assert {:error, "git mv/commit failed: boom"} =
               Store.call(@store, :move_note, %{
                 from: "bike/terra-speed.md",
                 to: "training/terra-40c.md",
                 confirm: true,
                 update_links: true
               })

      assert Map.new(paths, &{&1, File.read!(Path.join(vault, &1))}) == before
      refute File.exists?(Path.join(vault, "training/terra-40c.md"))

      assert {:ok, links} =
               Store.call(@store, :links, %{id: "bike/terra-speed.md", direction: :in, depth: 1})

      assert Enum.any?(links.incoming, &(&1.source == "bike/via-carolina.md"))
    end

    test "rewrite_note lists the inbound chunk links it broke" do
      assert {:ok, _} =
               Store.call(@store, :create, %{
                 path: "bike/deep-links.md",
                 type: "reference",
                 content:
                   "# Deep Links\nSee [[terra-speed#dimensions]], [[terra-speed#gravel-experience]] and [[terra-speed]]."
               })

      assert {:ok, result} =
               Store.call(@store, :rewrite_note, %{
                 path: "bike/terra-speed.md",
                 content:
                   "# WTB Terra Speed 40C\n\n## Gravel Experience\nStill quiet.\n\n## Size\n40mm.",
                 confirm: true
               })

      assert result.broken_chunk_links == [
               %{from: "bike/deep-links.md", to: "bike/terra-speed.md#dimensions"}
             ]

      assert {:ok, %{broken_chunk_links: []}} =
               Store.call(@store, :rewrite_note, %{
                 path: "bike/terra-speed.md",
                 content: "# WTB Terra Speed 40C\n\n## Gravel Experience\nQuieter."
               })
    end

    test "delete_note's confirm-required message lists current backlinks" do
      assert {:error, msg} = Store.call(@store, :delete_note, %{path: "bike/terra-speed.md"})
      assert msg =~ "incoming references"
      assert msg =~ "bike/via-carolina.md"
    end

    test "removing a link from a note's content clears it from the target's incoming links (no ghost entry)" do
      assert {:ok, _} =
               Store.call(@store, :create, %{
                 path: "bike/references-first.md",
                 type: "reference",
                 content: "# References First\nSee [[terra-speed]]."
               })

      {:ok, before} =
        Store.call(@store, :links, %{id: "bike/terra-speed.md", direction: :in, depth: 1})

      assert Enum.any?(before.incoming, &(&1.source == "bike/references-first.md"))

      assert {:ok, _} =
               Store.call(@store, :rewrite_note, %{
                 path: "bike/references-first.md",
                 content: "# References First\nNo reference any more.",
                 confirm: true
               })

      {:ok, after_} =
        Store.call(@store, :links, %{id: "bike/terra-speed.md", direction: :in, depth: 1})

      refute Enum.any?(after_.incoming, &(&1.source == "bike/references-first.md"))
    end
  end

  # Regression: skills/ and notes are "one repository, two systems"
  # (docs/design.md). Before Vigil.Vault.Policy the four write paths below
  # applied no writable-path rule, so a caller could append to, rewrite,
  # retype or delete a skill through a note tool — and the skill was then
  # parsed and indexed as a searchable note.
  describe "skills/ is not reachable through the note write tools" do
    # append/rewrite_note/update_frontmatter/delete_note into skills/, both
    # confirm-gated delete_note and move_note answering "Invalid path" rather
    # than a confirmation prompt, and move_note laundering in either
    # direction — all pure refusals, none touching disk or git — are proven
    # against Vigil.Vault.Policy directly in policy_test.exs: "the
    # writable-path rules apply to every write, not just create", "a path
    # the policy refuses is refused, not offered for confirmation", "a move
    # to or from a path the policy refuses is refused, not offered", and
    # "move_note cannot launder a note across the boundary". What stays here
    # is the one thing only the real store and a real index can show: even
    # attempted, a skill never leaks into search.
    test "a skill never becomes searchable through a write" do
      Store.call(@store, :append, %{path: "skills/tdd.md", content: "INJECTEDWORD"})
      assert search(%{query: "INJECTEDWORD"}) == []
    end
  end

  # docs/design.md, "A retried write is applied once". A write can outlive the
  # client's call timeout and still complete; the client retries. Three
  # guards, one per way the retry can go wrong.
  describe "a retried write" do
    defp commits(log), do: Enum.filter(CommitLog.calls(log), &match?({:commit, _, _}, &1))

    defp recorded_store(vault) do
      :ok = stop_supervised(Store)
      {git, log} = CommitLog.recording(vault)
      start_store(vault, git: git)
      log
    end

    test "with the same request_id is committed once, and the retry says so", %{vault: vault} do
      log = recorded_store(vault)
      request = %{path: "bike/terra-speed.md", content: "Retried once.", request_id: "r-1"}

      assert {:ok, first} = Store.call(@store, :append, request)
      refute Map.has_key?(first, :already_applied)

      # A retry resolves its own instant: the envelope of the second response
      # is not the first one's, and that must not make it a different write.
      retry = Map.put(request, :now, DateTime.add(DateTime.utc_now(), 90))
      assert {:ok, second} = Store.call(@store, :append, retry)

      assert second == Map.put(first, :already_applied, true)
      assert length(commits(log)) == 1

      content = File.read!(Path.join(vault, "bike/terra-speed.md"))
      assert length(String.split(content, "Retried once.")) == 2
    end

    test "the same request_id for a different write is refused, not answered", %{vault: vault} do
      log = recorded_store(vault)

      assert {:ok, _} =
               Store.call(@store, :append, %{
                 path: "bike/terra-speed.md",
                 content: "First.",
                 request_id: "r-2"
               })

      assert {:error, msg} =
               Store.call(@store, :append, %{
                 path: "bike/terra-speed.md",
                 content: "Second.",
                 request_id: "r-2"
               })

      assert msg =~ "r-2"
      assert length(commits(log)) == 1
      refute File.read!(Path.join(vault, "bike/terra-speed.md")) =~ "Second."
    end

    test "a refused write is not remembered: the corrected retry is applied" do
      request = %{path: "bike/terra-speed.md", content: "## Split\ntext", request_id: "r-3"}

      assert {:error, _} =
               Store.call(@store, :append, Map.put(request, :heading, "Dimensions"))

      assert {:ok, result} = Store.call(@store, :append, request)
      refute Map.has_key?(result, :already_applied)
    end

    test "without a request_id every call is a write of its own", %{vault: vault} do
      log = recorded_store(vault)
      request = %{path: "bike/terra-speed.md", content: "Twice."}

      assert {:ok, _} = Store.call(@store, :append, request)
      assert {:ok, _} = Store.call(@store, :append, request)
      assert length(commits(log)) == 2
    end

    test "skill_write takes a request_id too", %{vault: vault} do
      log = recorded_store(vault)

      request = %{
        name: "retried",
        content: "---\nname: retried\ndescription: A skill.\n---\n# Retried\n",
        request_id: "r-4"
      }

      assert {:ok, first} = Store.call(@store, :skill_write, request)
      assert {:ok, second} = Store.call(@store, :skill_write, request)
      assert second == Map.put(first, :already_applied, true)
      assert length(commits(log)) == 1
    end

    # The retry of a confirmed replace finds the skill it wrote, which exists
    # now; it is answered from the first write rather than gated again.
    test "a retried skill replace with confirm is applied once", %{vault: vault} do
      log = recorded_store(vault)

      request = %{
        name: "tdd",
        content: "---\nname: tdd\ndescription: Replaced.\n---\n# Replaced\n",
        confirm: true,
        request_id: "r-5"
      }

      assert {:ok, first} = Store.call(@store, :skill_write, request)
      assert {:ok, second} = Store.call(@store, :skill_write, request)
      assert second == Map.put(first, :already_applied, true)
      assert length(commits(log)) == 1
    end

    # A refusal is not remembered, so the same request_id can carry the
    # confirmed call the refusal asked for.
    test "a skill replace refused for want of confirm can be retried with it", %{vault: vault} do
      log = recorded_store(vault)
      request = %{name: "tdd", content: "---\nname: tdd\ndescription: R.\n---\n# R\n"}

      assert {:error, "Destructive operation: " <> _} =
               Store.call(@store, :skill_write, Map.put(request, :request_id, "r-6"))

      assert {:ok, %{name: "tdd"}} =
               Store.call(
                 @store,
                 :skill_write,
                 Map.merge(request, %{request_id: "r-6", confirm: true})
               )

      assert length(commits(log)) == 1
    end

    test "delete_section with the if_match of a section since renumbered is refused", %{
      vault: vault
    } do
      assert {:ok, _} =
               Store.call(@store, :create, %{
                 path: "bike/setups.md",
                 type: "reference",
                 content: "# Setups\n\n## Setup\nRoad setup.\n\n## Setup\nGravel setup.\n",
                 force: true
               })

      {:ok, read} = Store.call(@store, :read, %{id: "bike/setups.md#setup", backlinks: false})
      delete = %{id: "bike/setups.md#setup", if_match: read.hash}

      assert {:ok, _} = Store.call(@store, :delete_section, delete)

      # The second ## Setup is bike/setups.md#setup now. The retry names the
      # content that was deleted, and is refused rather than taking it.
      assert {:error, msg} = Store.call(@store, :delete_section, delete)
      assert msg =~ "if_match"
      assert File.read!(Path.join(vault, "bike/setups.md")) =~ "Gravel setup."
    end

    test "a heading line that no longer matches the index is refused", %{vault: vault} do
      log = recorded_store(vault)
      path = Path.join(vault, "bike/via-carolina.md")

      # Changed behind the index's back: every heading moved down one line.
      drifted =
        String.replace(File.read!(path), "# Via Carolina\n", "# Via Carolina\nInserted.\n")

      File.write!(path, drifted)

      assert {:error, msg} =
               Store.call(@store, :replace_section, %{
                 id: "bike/via-carolina.md#gear",
                 content: "x"
               })

      assert msg =~ "reload"
      assert File.read!(path) == drifted
      assert commits(log) == []

      # After the reload the index matches the file again, and the edit lands.
      Store.call(@store, :reload, %{})

      assert {:ok, _} =
               Store.call(@store, :replace_section, %{
                 id: "bike/via-carolina.md#gear",
                 content: "x"
               })
    end
  end
end
