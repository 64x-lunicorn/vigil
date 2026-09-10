defmodule Vigil.StoreTest do
  use ExUnit.Case, async: false

  alias Vigil.Store

  # Vigil.MCP.Tools declares limit (1..25, default 10) and supplies it on
  # every real call, so `Store.call(:search, ...)` requires one rather than defaulting.
  defp search(params), do: Store.call(:search, Map.put_new(params, :limit, 10))

  setup do
    {vault, remote} = Vigil.FixtureVault.build(remote: true)
    on_exit(fn -> Vigil.FixtureVault.cleanup(vault) end)
    start_supervised!({Store, vault_path: vault, exclude: [], git_remote: "origin"})
    %{vault: vault, remote: remote}
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
  # table is what declares the contract — `limit` 1..25, `depth` 1..2, an id
  # for every operation that names one — and `Store.call/2`'s heads match it,
  # so the mistake raises where it was made and the single writer keeps
  # answering everyone else. An operation the Store does not have is refused
  # in the same frame: there is no catch-all head to absorb it.
  #
  # The calls go through a variable on purpose. Written as literals the
  # compiler's type checker warns about every one of them — it can see they
  # match no head, which is the point of the test.
  describe "a broken contract fails in the caller's process" do
    test "a missing limit, an undeclared depth, a missing id, an operation that does not exist" do
      writer = Process.whereis(Store)

      broken = [
        {:search, %{query: "tires"}},
        {:links, %{id: "bike/via-carolina.md", direction: :out, depth: 3}},
        {:read, %{backlinks: false}},
        {:nonsense, %{}}
      ]

      for {op, params} <- broken do
        assert_raise FunctionClauseError, fn -> Store.call(op, params) end
      end

      assert Process.whereis(Store) == writer
      assert search(%{query: "tires", domain: "bike"}) != []
    end
  end

  # The chunk/note shapes, backlinks opt-in, lenient path resolution, and
  # invalid/not-found handling are Vigil.Index's job now and are covered
  # there (index_test.exs) without git. This is the wiring smoke test.
  describe "read" do
    test "reading a fragment returns exactly that chunk" do
      {:ok, result} = Store.call(:read, %{id: "bike/via-carolina.md#fueling", backlinks: false})
      assert result.heading == "Fueling"
      assert result.body =~ "baseline"
      refute Map.has_key?(result, :backlinks)
    end
  end

  describe "create" do
    test "creates file, commits as vigil, pushes, and updates the index", %{vault: vault} do
      assert {:ok, %{path: "bike/new.md", pushed: true}} =
               Store.call(:create, %{
                 path: "bike/new.md",
                 type: "reference",
                 content: "# New\n\nSome test content.\n"
               })

      assert File.exists?(Path.join(vault, "bike/new.md"))
      {:ok, result} = Store.call(:read, %{id: "bike/new.md", backlinks: false})
      assert result.title == "New"

      {out, 0} = System.cmd("git", ["log", "-1", "--format=%an"], cd: vault)
      assert String.trim(out) == "vigil"
    end

    # File-exists, H1, frontmatter and event starts/ends rules are pure
    # refusals asserted against Vigil.Vault.Policy directly (policy_test.exs,
    # "existence rules" and "content and type rules on :create") — they touch
    # neither the filesystem nor git, so the store test no longer restates
    # them.
    test "duplicate detection blocks similarly-titled note in same domain, force bypasses it" do
      assert {:error, msg} =
               Store.call(:create, %{
                 path: "bike/terra-speed-tubeless.md",
                 type: "reference",
                 content: "# Terra Speed Tubeless\ntext"
               })

      assert msg =~ "duplicates"
      assert msg =~ "append"

      assert {:ok, _} =
               Store.call(:create, %{
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
               Store.call(:create, %{
                 path: "bike/via.md",
                 type: "reference",
                 content: "# Via\ntext"
               })

      assert msg =~ "duplicates"
      assert msg =~ "bike/via-carolina.md"

      assert {:ok, _} =
               Store.call(:create, %{
                 path: "bike/kvv.md",
                 type: "reference",
                 content: "# KVV\ntext"
               })
    end

    test "duplicate detection does not fire within the same project folder" do
      assert {:ok, _} =
               Store.call(:create, %{
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
               Store.call(:create, %{
                 path: "projects/new/x.md",
                 type: "reference",
                 content: "# X\nx",
                 create_dirs: true
               })

      assert {:ok, _} = Store.call(:read, %{id: "projects/new/x.md", backlinks: false})
    end

    test "create_dirs never creates directories outside projects/", %{vault: vault} do
      assert {:error, _} =
               Store.call(:create, %{
                 path: "gear/sub/x.md",
                 type: "reference",
                 content: "# X\nx",
                 create_dirs: true
               })

      refute File.dir?(Path.join(vault, "gear/sub"))

      assert {:error, _} =
               Store.call(:create, %{
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
      {:ok, result} = Store.call(:read, %{id: "projects/vigil/vigil.md", backlinks: true})
      assert result.title == "vigil"

      {:ok, links} =
        Store.call(:links, %{id: "projects/vigil/vigil.md", direction: :out, depth: 1})

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
               Store.call(:append, %{
                 path: "bike/via-carolina.md",
                 heading: "Gear",
                 content: "Extra: repair kit."
               })

      {:ok, result} = Store.call(:read, %{id: "bike/via-carolina.md#gear", backlinks: false})
      assert result.body =~ "Extra: repair kit."
    end

    test "appends a new section when the heading does not exist yet" do
      assert {:ok, _} =
               Store.call(:append, %{
                 path: "bike/via-carolina.md",
                 heading: "Weather",
                 content: "Dry conditions expected."
               })

      {:ok, result} = Store.call(:read, %{id: "bike/via-carolina.md#weather", backlinks: false})
      assert result.body =~ "Dry conditions expected."
    end

    test "appends to EOF without a heading" do
      assert {:ok, _} =
               Store.call(:append, %{path: "bike/terra-speed.md", content: "Final sentence."})

      {:ok, result} =
        Store.call(:read, %{id: "bike/terra-speed.md#gravel-experience", backlinks: false})

      assert result.body =~ "Final sentence."
    end

    # A heading spliced into the middle of a section splits it on the next
    # parse, into two chunks one of which nobody asked for.
    test "a heading in content appended to an existing section is rejected", %{vault: vault} do
      assert {:error, msg} =
               Store.call(:append, %{
                 path: "bike/via-carolina.md",
                 heading: "Gear",
                 content: "## Sneaky\nSplit."
               })

      assert msg =~ "split the section in two"
      refute File.read!(Path.join(vault, "bike/via-carolina.md")) =~ "Sneaky"
    end

    test "the same content is accepted at the end of the file and as a new section" do
      content = "## Sneaky\nNot sneaky here."

      assert {:ok, _} = Store.call(:append, %{path: "bike/terra-speed.md", content: content})

      assert {:ok, _} =
               Store.call(:append, %{
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
               Store.call(:replace_section, %{
                 id: "bike/via-carolina.md#fueling",
                 content: "New fueling strategy."
               })

      {:ok, result} = Store.call(:read, %{id: "bike/via-carolina.md#fueling", backlinks: false})
      assert result.body =~ "New fueling strategy."
    end

    # The id is resolved once, by the policy, through the same lenient lookup
    # `read` uses — so the two accept the same ids, and the write lands on the
    # path the lookup resolved rather than on one re-derived from the id.
    test "an id that read accepts is accepted here too, and writes the resolved path" do
      messy = "bike/Via Carolina!!.md#fueling"

      assert {:ok, _} = Store.call(:read, %{id: messy, backlinks: false})

      assert {:ok, %{path: "bike/via-carolina.md"}} =
               Store.call(:replace_section, %{id: messy, content: "Resolved."})

      {:ok, result} = Store.call(:read, %{id: "bike/via-carolina.md#fueling", backlinks: false})
      assert result.body =~ "Resolved."
    end

    # The writable-path check runs on the normalized path part, not the raw
    # one: a messy domain segment or extension resolves for `read`, so it has
    # to resolve here too.
    test "leniency covers the whole path part, not just the basename" do
      for messy <- ["Bike/via-carolina.md#fueling", "bike/via-carolina.MD#fueling"] do
        assert {:ok, _} = Store.call(:read, %{id: messy, backlinks: false})

        assert {:ok, %{path: "bike/via-carolina.md"}} =
                 Store.call(:replace_section, %{id: messy, content: "Resolved via #{messy}."})
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

      result = Store.call(:current, %{now: during_event})

      assert Enum.any?(result.active, &(&1.id == "bike/via-carolina.md"))
    end

    test "invalid event (ends < starts) never appears in current" do
      {:ok, _} =
        Store.call(:create, %{
          path: "bike/kaputt.md",
          type: "event",
          content: "# Kaputt\nx",
          starts: "2026-07-10T10:00:00+02:00",
          ends: "2026-07-09T10:00:00+02:00"
        })

      now = ~U[2026-07-10 08:00:00Z] |> DateTime.shift_zone!("Europe/Berlin")
      result = Store.call(:current, %{now: now})

      refute Enum.any?(
               result.active ++ result.upcoming ++ result.recently_past,
               &(&1.id == "bike/kaputt.md")
             )
    end
  end

  describe "snapshot" do
    test "returns the window Vigil.Events computes from the indexed event files" do
      during_event = ~U[2026-07-11 00:00:00Z] |> DateTime.shift_zone!("Europe/Berlin")

      snapshot = Store.snapshot(during_event)

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
      start_supervised!({Store, vault_path: vault, exclude: ["bike"], git_remote: "origin"})

      now = ~U[2026-07-11 00:00:00Z] |> DateTime.shift_zone!("Europe/Berlin")
      snapshot = Store.snapshot(now)

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
               Store.call(:create, %{
                 path: "bike/Café Overview!!.md",
                 type: "reference",
                 content: "# Café Overview\ntext"
               })

      assert File.exists?(Path.join(vault, "bike/cafe-overview.md"))
      refute File.exists?(Path.join(vault, "bike/Café Overview!!.md"))
    end

    test "an already-canonical path has no path_normalized_from key" do
      assert {:ok, result} =
               Store.call(:create, %{
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
               Store.call(:create, %{
                 path: "journal/2026-02-02.md",
                 type: "reference",
                 content: "# Journal Entry Test Day\ntext",
                 force: true
               })
    end

    test "a domain without a naming block is unaffected" do
      assert {:ok, _} =
               Store.call(:create, %{
                 path: "bike/any-name.md",
                 type: "reference",
                 content: "# X\nx"
               })
    end

    test "move_note normalizes and naming-checks the destination too" do
      assert {:error, msg} =
               Store.call(:move_note, %{
                 from: "bike/terra-speed.md",
                 to: "journal/not-a-date.md",
                 confirm: true
               })

      assert msg =~ "does not match the schema"

      assert {:ok, %{to: "journal/2026-03-03.md"}} =
               Store.call(:move_note, %{
                 from: "bike/terra-speed.md",
                 to: "journal/2026-03-03.md",
                 confirm: true
               })
    end
  end

  describe "rewrite_note" do
    test "replaces the body but keeps the frontmatter; requires confirm", %{vault: vault} do
      assert {:error, msg} =
               Store.call(:rewrite_note, %{
                 path: "bike/terra-speed.md",
                 content: "# New\nCompletely new."
               })

      assert msg =~ "confirm: true"

      assert {:ok, _} =
               Store.call(:rewrite_note, %{
                 path: "bike/terra-speed.md",
                 content: "# New\nCompletely new.",
                 confirm: true
               })

      raw = File.read!(Path.join(vault, "bike/terra-speed.md"))
      assert raw =~ "type: reference"
      assert raw =~ "Completely new."
      refute raw =~ "Dimensions"

      {:ok, result} = Store.call(:read, %{id: "bike/terra-speed.md", backlinks: false})
      assert result.type == :reference
    end

    # The shrink gate's baseline is the note's own indexed heading count, asked
    # for by the policy rather than handed in. If that question never reaches
    # the policy the baseline reads as 0, nothing looks removed, and the gate
    # opens without a word.
    test "the shrink gate names the note's own heading count" do
      one_left = "# Via Carolina\n\n## Fueling\nbaseline."

      assert {:error, msg} =
               Store.call(:rewrite_note, %{path: "bike/via-carolina.md", content: one_left})

      assert msg =~ "removes 2 of 3 headings"
    end

    test "confirm not required when the shrink stays under the threshold" do
      # via-carolina.md has 3 headings (Fueling, Second Half, Gear); this
      # removes only 1 — under both half-of-3 and the 20-heading floor.
      new_content = "# Via Carolina\n\n## Fueling\nbaseline.\n\n## Gear\nFrame bag."

      assert {:ok, _} =
               Store.call(:rewrite_note, %{path: "bike/via-carolina.md", content: new_content})

      {:ok, result} = Store.call(:read, %{id: "bike/via-carolina.md", backlinks: false})
      assert Enum.map(result.toc, & &1.heading) == ["Fueling", "Gear"]
    end

    test "confirm required when more than 20 headings would be removed, even under half", %{
      vault: vault
    } do
      many =
        for n <- 1..30, do: "## Section #{n}\nContent #{n}."

      assert {:ok, _} =
               Store.call(:create, %{
                 path: "bike/many.md",
                 type: "reference",
                 content: "# Many Sections\n\n" <> Enum.join(many, "\n\n"),
                 force: true
               })

      few = for n <- 1..5, do: "## Section #{n}\nContent #{n}."
      few_content = "# Many Sections\n\n" <> Enum.join(few, "\n\n")

      assert {:error, msg} =
               Store.call(:rewrite_note, %{path: "bike/many.md", content: few_content})

      assert msg =~ "removes 25 of 30 headings"

      assert {:ok, _} =
               Store.call(:rewrite_note, %{
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
      assert {:ok, _} = Store.call(:delete_section, %{id: "bike/via-carolina.md#gear"})
      assert {:error, _} = Store.call(:read, %{id: "bike/via-carolina.md#gear", backlinks: false})
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
               Store.call(:create, %{
                 path: path,
                 type: "reference",
                 content: "# Shape\n\n## First\nFirst body.\n\n## Second\nSecond body.\n\n\n"
               })

      assert one_trailing_newline?(abs_path)

      assert {:ok, _} = Store.call(:append, %{path: path, heading: "First", content: "More.\n\n"})
      assert one_trailing_newline?(abs_path)

      assert {:ok, _} =
               Store.call(:replace_section, %{id: "#{path}#second", content: "Replaced.\n\n"})

      assert one_trailing_newline?(abs_path)

      assert {:ok, _} = Store.call(:delete_section, %{id: "#{path}#second"})
      assert one_trailing_newline?(abs_path)

      assert {:ok, _} = Store.call(:update_frontmatter, %{path: path, type: "decision"})
      assert one_trailing_newline?(abs_path)

      assert {:ok, _} =
               Store.call(:rewrite_note, %{path: path, content: "# Shape\n\n## Only\nBody.\n\n\n"})

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
               Store.call(:update_frontmatter, %{path: "bike/terra-speed.md", type: "decision"})

      {:ok, result} = Store.call(:read, %{id: "bike/terra-speed.md", backlinks: false})
      assert result.type == :decision
      assert search(%{query: "tubeless"}) |> Enum.any?(&(&1.id =~ "terra-speed"))
    end

    # "enforces the same starts/ends rules as create" moved to
    # policy_test.exs, "update_frontmatter enforces the same content rules
    # as create".
  end

  describe "delete" do
    test "removes the note from disk and the index; requires confirm", %{vault: vault} do
      assert {:error, msg} = Store.call(:delete_note, %{path: "bike/terra-speed.md"})
      assert msg =~ "confirm: true"

      assert {:ok, %{pushed: true}} =
               Store.call(:delete_note, %{path: "bike/terra-speed.md", confirm: true})

      refute File.exists?(Path.join(vault, "bike/terra-speed.md"))
      assert {:error, _} = Store.call(:read, %{id: "bike/terra-speed.md", backlinks: false})
      refute search(%{query: "tubeless"}) |> Enum.any?(&(&1.id =~ "terra-speed"))
    end

    test "reports broken backlinks in the same call when confirm is passed up front" do
      assert {:ok, %{broken_backlinks: broken_backlinks}} =
               Store.call(:delete_note, %{path: "bike/terra-speed.md", confirm: true})

      assert "bike/via-carolina.md" in broken_backlinks
    end
  end

  describe "move" do
    test "renames the note, updates the index; requires confirm", %{vault: vault} do
      assert {:error, msg} =
               Store.call(:move_note, %{from: "bike/terra-speed.md", to: "bike/terra-40c.md"})

      assert msg =~ "confirm: true"

      assert {:ok, %{pushed: true}} =
               Store.call(:move_note, %{
                 from: "bike/terra-speed.md",
                 to: "bike/terra-40c.md",
                 confirm: true
               })

      refute File.exists?(Path.join(vault, "bike/terra-speed.md"))
      assert File.exists?(Path.join(vault, "bike/terra-40c.md"))
      assert {:error, _} = Store.call(:read, %{id: "bike/terra-speed.md", backlinks: false})
      {:ok, result} = Store.call(:read, %{id: "bike/terra-40c.md", backlinks: false})
      assert result.title == "WTB Terra Speed 40C"
    end

    test "rejects a destination that already exists" do
      assert {:error, msg} =
               Store.call(:move_note, %{
                 from: "bike/terra-speed.md",
                 to: "bike/via-carolina.md",
                 confirm: true
               })

      assert msg =~ "already exists"
    end

    test "destination still runs through domain validation" do
      assert {:error, _} =
               Store.call(:move_note, %{
                 from: "bike/terra-speed.md",
                 to: "unbekannt/x.md",
                 confirm: true
               })
    end
  end

  # Each finding's rule (duplicate headings, sentence-like headings, orphaned
  # links, overlong notes, stale decisions) is Vigil.Index's job now and is
  # covered there (index_test.exs) without git. This is the wiring smoke
  # test: a write lands in the report a :lint call returns.
  describe "lint" do
    test "reports duplicate headings, sentence-like headings, and orphaned links" do
      {:ok, _} =
        Store.call(:create, %{
          path: "bike/messy.md",
          type: "reference",
          content:
            "# Messy\n\n## Duplicate\nOne.\n\n## Duplicate\nTwo.\n\n" <>
              "## This is a rather long heading with punctuation and a full stop.\nText.\n\n" <>
              "## Reference\nSee [[does-not-exist]].\n"
        })

      report = Store.call(:lint, %{})

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

    # Thin end-to-end wiring check: skill_list/skill_read/skill_write reach
    # Vigil.Skills through the GenServer and the write still serializes
    # through Store's single mailbox. Full behavioral coverage (name
    # validation, frontmatter validation, SkillKey token) lives in
    # test/vigil/skills_test.exs.
    test "skill_list, skill_read, and skill_write work end-to-end through the GenServer" do
      [skill] = Store.call(:skill_list, %{})
      assert skill.name == "tdd"

      {:ok, %{content: c1}} = Store.call(:skill_read, %{name: "tdd"})
      {:ok, %{content: c2}} = Store.call(:skill_read, %{name: "tdd.md"})
      assert c1 == c2
      assert c1 =~ "SkillKey:"

      assert {:error, msg} = Store.call(:skill_read, %{name: "does-not-exist"})
      assert msg =~ "tdd"

      assert {:ok, %{name: "new", pushed: true}} =
               Store.call(:skill_write, %{
                 name: "new",
                 content: "---\nname: new\ndescription: test skill\n---\n# New\n1. one"
               })

      {:ok, %{content: content}} = Store.call(:skill_read, %{name: "new"})
      assert content =~ "1. one"
      assert search(%{query: "one"}) == []
    end
  end

  # Creation date = first commit (docs/design.md, principle 3). A write is
  # never a note's first commit, and the index is what keeps that true —
  # Vigil.Index.put/2 would otherwise reset created_at to the write's own
  # commit time, on every write path at once.
  describe "created_at survives a write" do
    defp created_at(path) do
      {:ok, note} = Store.call(:read, %{id: path, backlinks: false})
      note.created_at
    end

    test "append, rewrite_note and move_note all leave it alone" do
      before = created_at("bike/via-carolina.md")
      assert is_binary(before)

      assert {:ok, _} =
               Store.call(:append, %{path: "bike/via-carolina.md", content: "One more line."})

      assert created_at("bike/via-carolina.md") == before

      assert {:ok, _} =
               Store.call(:rewrite_note, %{
                 path: "bike/via-carolina.md",
                 content: "# Via Carolina\n\n## Fueling\nbaseline.\n\n## Gear\nFrame bag.",
                 confirm: true
               })

      assert created_at("bike/via-carolina.md") == before

      assert {:ok, _} =
               Store.call(:move_note, %{
                 from: "bike/via-carolina.md",
                 to: "training/via-carolina.md",
                 confirm: true
               })

      assert created_at("training/via-carolina.md") == before
    end

    test "a note created now takes the creation date of its own commit" do
      assert {:ok, _} =
               Store.call(:create, %{
                 path: "bike/brand-new.md",
                 type: "reference",
                 content: "# New\n\nx"
               })

      assert is_binary(created_at("bike/brand-new.md"))
    end

    test "a full reload still reports the git creation date" do
      before = created_at("bike/via-carolina.md")

      assert {:ok, _} =
               Store.call(:append, %{path: "bike/via-carolina.md", content: "Another line."})

      assert %{reloaded: true} = Store.call(:reload, %{})

      assert created_at("bike/via-carolina.md") == before
    end
  end

  describe "reload" do
    test "reload re-reads the vault and reports success" do
      assert %{reloaded: true} = Store.call(:reload, %{})
      assert search(%{query: "tires"}) != []
    end

    test "reload with an unreachable remote reports pull_failed but still reparses", %{
      vault: vault
    } do
      :ok = stop_supervised(Store)
      start_supervised!({Store, vault_path: vault, exclude: [], git_remote: "nonexistent-remote"})

      assert %{reloaded: true, pull_failed: reason} = Store.call(:reload, %{})
      assert is_binary(reason)
      assert search(%{query: "tires"}) != []
    end
  end

  describe "write-path robustness" do
    test "push failure is returned as an error; read and search keep working", %{vault: vault} do
      :ok = stop_supervised(Store)
      start_supervised!({Store, vault_path: vault, exclude: [], git_remote: "nonexistent-remote"})

      assert {:error, msg} =
               Store.call(:create, %{
                 path: "bike/new.md",
                 type: "reference",
                 content: "# New\ntext"
               })

      assert msg =~ "push failed"
      assert File.exists?(Path.join(vault, "bike/new.md"))

      assert search(%{query: "tires"}) != []
      assert {:ok, _} = Store.call(:read, %{id: "bike/via-carolina.md", backlinks: false})
    end

    # The index is updated between commit and push for every write action
    # (docs/design.md, "The write path"), the git-level ones included: the note
    # is gone from the repository, so it must be gone from the index too, push
    # or no push.
    test "a delete whose push fails still leaves the index without the note", %{vault: vault} do
      :ok = stop_supervised(Store)
      start_supervised!({Store, vault_path: vault, exclude: [], git_remote: "nonexistent-remote"})

      assert {:error, msg} =
               Store.call(:delete_note, %{path: "bike/terra-speed.md", confirm: true})

      assert msg =~ "Deletion committed locally, but push failed"
      refute File.exists?(Path.join(vault, "bike/terra-speed.md"))
      assert {:error, _} = Store.call(:read, %{id: "bike/terra-speed.md", backlinks: false})
      refute search(%{query: "tubeless"}) |> Enum.any?(&(&1.id =~ "terra-speed"))
    end

    test "a move whose push fails still leaves the index at the new path", %{vault: vault} do
      :ok = stop_supervised(Store)
      start_supervised!({Store, vault_path: vault, exclude: [], git_remote: "nonexistent-remote"})

      assert {:error, msg} =
               Store.call(:move_note, %{
                 from: "bike/terra-speed.md",
                 to: "bike/terra-40c.md",
                 confirm: true
               })

      assert msg =~ "Move committed locally, but push failed"
      assert {:error, _} = Store.call(:read, %{id: "bike/terra-speed.md", backlinks: false})
      assert {:ok, _} = Store.call(:read, %{id: "bike/terra-40c.md", backlinks: false})
    end

    test "writing into a read-only domain directory returns a precise error, store stays alive",
         %{
           vault: vault
         } do
      dir = Path.join(vault, "home")
      File.chmod!(dir, 0o555)

      result =
        Store.call(:create, %{path: "home/new.md", type: "reference", content: "# New\ntext"})

      File.chmod!(dir, 0o755)

      assert {:error, msg} = result
      assert msg =~ "Could not write file"
      assert {:ok, _} = Store.call(:read, %{id: "home/diacritics-äöü-café.md", backlinks: false})
    end

    test "append against an unreadable file returns a clean error, store stays alive", %{
      vault: vault
    } do
      path = Path.join(vault, "bike/via-carolina.md")
      File.chmod!(path, 0o000)

      result = Store.call(:append, %{path: "bike/via-carolina.md", content: "Extra."})

      File.chmod!(path, 0o644)

      assert {:error, msg} = result
      assert msg =~ "Could not read file"
      assert search(%{query: "tires"}) != []
      assert {:ok, _} = Store.call(:read, %{id: "bike/via-carolina.md", backlinks: false})
    end

    test "replace_section against an unreadable file returns a clean error, store stays alive", %{
      vault: vault
    } do
      path = Path.join(vault, "bike/via-carolina.md")
      File.chmod!(path, 0o000)

      result =
        Store.call(:replace_section, %{
          id: "bike/via-carolina.md#fueling",
          content: "New strategy."
        })

      File.chmod!(path, 0o644)

      assert {:error, msg} = result
      assert msg =~ "Could not read file"
      assert search(%{query: "tires"}) != []
      assert {:ok, _} = Store.call(:read, %{id: "bike/via-carolina.md", backlinks: false})
    end

    test "delete_section against an unreadable file returns a clean error, store stays alive", %{
      vault: vault
    } do
      path = Path.join(vault, "bike/via-carolina.md")
      File.chmod!(path, 0o000)

      result = Store.call(:delete_section, %{id: "bike/via-carolina.md#gear"})

      File.chmod!(path, 0o644)

      assert {:error, msg} = result
      assert msg =~ "Could not read file"
      assert search(%{query: "tires"}) != []
      assert {:ok, _} = Store.call(:read, %{id: "bike/via-carolina.md", backlinks: false})
    end

    test "rewrite_note against an unreadable file returns a clean error, store stays alive", %{
      vault: vault
    } do
      path = Path.join(vault, "bike/terra-speed.md")
      File.chmod!(path, 0o000)

      result =
        Store.call(:rewrite_note, %{
          path: "bike/terra-speed.md",
          content: "# New\nCompletely new.",
          confirm: true
        })

      File.chmod!(path, 0o644)

      assert {:error, msg} = result
      assert msg =~ "Could not read file"
      assert search(%{query: "tires"}) != []
      assert {:ok, _} = Store.call(:read, %{id: "bike/terra-speed.md", backlinks: false})
    end

    test "update_frontmatter against an unreadable file returns a clean error, store stays alive",
         %{vault: vault} do
      path = Path.join(vault, "bike/terra-speed.md")
      File.chmod!(path, 0o000)

      result = Store.call(:update_frontmatter, %{path: "bike/terra-speed.md", type: "decision"})

      File.chmod!(path, 0o644)

      assert {:error, msg} = result
      assert msg =~ "Could not read file"
      assert search(%{query: "tires"}) != []
      assert {:ok, _} = Store.call(:read, %{id: "bike/terra-speed.md", backlinks: false})
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
        Store.call(:links, %{id: "bike/Via Carolina!!.md", direction: :out, depth: 1})

      assert result.id == "bike/via-carolina.md"
    end

    test "move_note reports broken_backlinks for a link that no longer resolves, keeps a still-resolving one out" do
      assert {:ok, _} =
               Store.call(:create, %{
                 path: "bike/references-explicitly.md",
                 type: "reference",
                 content: "# References Terra Speed\nSee [Terra Speed](bike/terra-speed.md)."
               })

      assert {:ok, result} =
               Store.call(:move_note, %{
                 from: "bike/terra-speed.md",
                 to: "training/terra-speed.md",
                 confirm: true
               })

      assert "bike/references-explicitly.md" in result.broken_backlinks
      refute "bike/via-carolina.md" in result.broken_backlinks
    end

    test "delete_note's confirm-required message lists current backlinks" do
      assert {:error, msg} = Store.call(:delete_note, %{path: "bike/terra-speed.md"})
      assert msg =~ "incoming references"
      assert msg =~ "bike/via-carolina.md"
    end

    test "removing a link from a note's content clears it from the target's incoming links (no ghost entry)" do
      assert {:ok, _} =
               Store.call(:create, %{
                 path: "bike/references-first.md",
                 type: "reference",
                 content: "# References First\nSee [[terra-speed]]."
               })

      {:ok, before} = Store.call(:links, %{id: "bike/terra-speed.md", direction: :in, depth: 1})
      assert Enum.any?(before.incoming, &(&1.source == "bike/references-first.md"))

      assert {:ok, _} =
               Store.call(:rewrite_note, %{
                 path: "bike/references-first.md",
                 content: "# References First\nNo reference any more.",
                 confirm: true
               })

      {:ok, after_} = Store.call(:links, %{id: "bike/terra-speed.md", direction: :in, depth: 1})
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
      Store.call(:append, %{path: "skills/tdd.md", content: "INJECTEDWORD"})
      assert search(%{query: "INJECTEDWORD"}) == []
    end
  end
end
