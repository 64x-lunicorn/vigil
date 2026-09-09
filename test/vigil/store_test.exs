defmodule Vigil.StoreTest do
  use ExUnit.Case, async: false

  alias Vigil.Store

  setup do
    {vault, remote} = Vigil.FixtureVault.build(remote: true)
    on_exit(fn -> Vigil.FixtureVault.cleanup(vault) end)
    start_supervised!({Store, vault_path: vault, exclude: [], git_remote: "origin"})
    %{vault: vault, remote: remote}
  end

  # Ranking, filtering, journal-hiding and hub-attachment are Vigil.Index's
  # job now and are covered there (index_test.exs) without git. This is the
  # wiring smoke test: Store.search/1 reaches the index and shapes the result.
  describe "search" do
    test "a term in domain bike returns ranked hits with previews, no bodies" do
      results = Store.search(%{query: "tires", domain: "bike"})
      assert results != []
      refute Map.has_key?(hd(results), :body)
      assert Enum.all?(results, &(String.length(&1.preview) <= 121))
    end
  end

  # The chunk/note shapes, backlinks opt-in, lenient path resolution, and
  # invalid/not-found handling are Vigil.Index's job now and are covered
  # there (index_test.exs) without git. This is the wiring smoke test.
  describe "read" do
    test "reading a fragment returns exactly that chunk" do
      {:ok, result} = Store.read("bike/via-carolina.md#fueling", false)
      assert result.heading == "Fueling"
      assert result.body =~ "baseline"
      refute Map.has_key?(result, :backlinks)
    end
  end

  describe "create" do
    test "creates file, commits as vigil, pushes, and updates the index", %{vault: vault} do
      assert {:ok, %{path: "bike/new.md", pushed: true}} =
               Store.create(%{
                 path: "bike/new.md",
                 type: "reference",
                 content: "# New\n\nSome test content.\n"
               })

      assert File.exists?(Path.join(vault, "bike/new.md"))
      {:ok, result} = Store.read("bike/new.md", false)
      assert result.title == "New"

      {out, 0} = System.cmd("git", ["log", "-1", "--format=%an"], cd: vault)
      assert String.trim(out) == "vigil"
    end

    test "fails if file already exists" do
      assert {:error, msg} =
               Store.create(%{
                 path: "bike/terra-speed.md",
                 type: "reference",
                 content: "# X\ntext"
               })

      assert msg =~ "already exists"
    end

    test "content without H1 is rejected" do
      assert {:error, _} =
               Store.create(%{path: "bike/no-h1.md", type: "reference", content: "no h1 here"})
    end

    test "content with its own frontmatter is rejected" do
      assert {:error, _} =
               Store.create(%{
                 path: "bike/own-frontmatter.md",
                 type: "reference",
                 content: "---\ntype: reference\n---\n# X\ntext"
               })
    end

    test "event requires starts/ends; other types forbid them" do
      assert {:error, _} = Store.create(%{path: "bike/ev.md", type: "event", content: "# E\nx"})

      assert {:error, _} =
               Store.create(%{
                 path: "bike/ref.md",
                 type: "reference",
                 content: "# R\nx",
                 starts: "2026-01-01T00:00:00+01:00"
               })
    end

    test "duplicate detection blocks similarly-titled note in same domain, force bypasses it" do
      assert {:error, msg} =
               Store.create(%{
                 path: "bike/terra-speed-tubeless.md",
                 type: "reference",
                 content: "# Terra Speed Tubeless\ntext"
               })

      assert msg =~ "duplicates"
      assert msg =~ "append"

      assert {:ok, _} =
               Store.create(%{
                 path: "bike/terra-speed-tubeless.md",
                 type: "reference",
                 content: "# Terra Speed Tubeless\ntext",
                 force: true
               })
    end

    test "duplicate detection does not fire within the same project folder" do
      assert {:ok, _} =
               Store.create(%{
                 path: "projects/vigil/vigil-notes.md",
                 type: "reference",
                 content: "# vigil Notes\nMore notes about vigil."
               })
    end

    test "duplicate detection still fires across different project folders" do
      assert {:error, msg} =
               Store.create(%{
                 path: "projects/other/vigil-copy.md",
                 type: "reference",
                 content: "# vigil Copy\nA different project note.",
                 create_dirs: true
               })

      assert msg =~ "duplicates"
    end

    test "create_dirs creates a missing project folder, absent flag rejects it" do
      assert {:error, msg} =
               Store.create(%{path: "projects/new/x.md", type: "reference", content: "# X\nx"})

      assert msg =~ "Project directory does not exist"

      assert {:ok, _} =
               Store.create(%{
                 path: "projects/new/x.md",
                 type: "reference",
                 content: "# X\nx",
                 create_dirs: true
               })

      assert {:ok, _} = Store.read("projects/new/x.md", false)
    end

    test "create_dirs never creates directories outside projects/", %{vault: vault} do
      assert {:error, _} =
               Store.create(%{
                 path: "gear/sub/x.md",
                 type: "reference",
                 content: "# X\nx",
                 create_dirs: true
               })

      refute File.dir?(Path.join(vault, "gear/sub"))

      assert {:error, _} =
               Store.create(%{
                 path: "unknown-domain/x.md",
                 type: "reference",
                 content: "# X\nx",
                 create_dirs: true
               })

      refute File.dir?(Path.join(vault, "unknown-domain"))
    end

    test "unknown domain is rejected with a domain list" do
      assert {:error, msg} =
               Store.create(%{path: "unknown-domain/x.md", type: "reference", content: "# X\nx"})

      assert msg =~ "bike"
    end

    test "projects allows exactly one extra level, other domains do not" do
      assert {:ok, _} =
               Store.create(%{path: "projects/vigil/x.md", type: "reference", content: "# X\nx"})

      assert {:error, _} =
               Store.create(%{path: "projects/new/x.md", type: "reference", content: "# X\nx"})

      assert {:error, _} =
               Store.create(%{
                 path: "projects/vigil/docs/x.md",
                 type: "reference",
                 content: "# X\nx"
               })

      assert {:error, _} =
               Store.create(%{path: "gear/sub/x.md", type: "reference", content: "# X\nx"})
    end

    test "[[vigil-ranking]] in vigil.md resolves to projects/vigil/vigil-ranking.md" do
      {:ok, result} = Store.read("projects/vigil/vigil.md", true)
      assert result.title == "vigil"

      {:ok, links} = Store.links("projects/vigil/vigil.md", :out, 1)

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
               Store.append(%{
                 path: "bike/via-carolina.md",
                 heading: "Gear",
                 content: "Extra: repair kit."
               })

      {:ok, result} = Store.read("bike/via-carolina.md#gear", false)
      assert result.body =~ "Extra: repair kit."
    end

    test "appends a new section when the heading does not exist yet" do
      assert {:ok, _} =
               Store.append(%{
                 path: "bike/via-carolina.md",
                 heading: "Weather",
                 content: "Dry conditions expected."
               })

      {:ok, result} = Store.read("bike/via-carolina.md#weather", false)
      assert result.body =~ "Dry conditions expected."
    end

    test "appends to EOF without a heading" do
      assert {:ok, _} = Store.append(%{path: "bike/terra-speed.md", content: "Final sentence."})
      {:ok, result} = Store.read("bike/terra-speed.md#gravel-experience", false)
      assert result.body =~ "Final sentence."
    end
  end

  # Which lines move, and content-shape validation, are Vigil.Vault.Edit's
  # and Vigil.Vault.Policy's jobs now and are covered there (edit_test.exs,
  # policy_test.exs) without git. This is the wiring smoke test.
  describe "replace_section" do
    test "replaces the target chunk's body and the index picks it up" do
      assert {:ok, _} =
               Store.replace_section("bike/via-carolina.md#fueling", "New fueling strategy.")

      {:ok, result} = Store.read("bike/via-carolina.md#fueling", false)
      assert result.body =~ "New fueling strategy."
    end
  end

  describe "current" do
    test "returns the window Vigil.Events computes from the indexed event files" do
      during_event = ~U[2026-07-11 00:00:00Z] |> DateTime.shift_zone!("Europe/Berlin")

      result = Store.current(during_event)

      assert Enum.any?(result.active, &(&1.id == "bike/via-carolina.md"))
    end

    test "invalid event (ends < starts) never appears in current" do
      {:ok, _} =
        Store.create(%{
          path: "bike/kaputt.md",
          type: "event",
          content: "# Kaputt\nx",
          starts: "2026-07-10T10:00:00+02:00",
          ends: "2026-07-09T10:00:00+02:00"
        })

      now = ~U[2026-07-10 08:00:00Z] |> DateTime.shift_zone!("Europe/Berlin")
      result = Store.current(now)

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

  describe "path security" do
    test "path traversal and absolute paths are rejected without touching disk" do
      for bad_path <- ["../../etc/passwd", "/etc/passwd", "bike/../../x.md"] do
        assert {:error, msg} =
                 Store.create(%{path: bad_path, type: "reference", content: "# X\nx"})

        assert msg == "Invalid path"
      end
    end

    test "writing into skills/ via create is rejected" do
      assert {:error, "Invalid path"} =
               Store.create(%{path: "skills/x.md", type: "reference", content: "# X\nx"})
    end

    test "dot-prefixed path segments are rejected everywhere, not just the first" do
      assert {:error, "Invalid path"} =
               Store.create(%{
                 path: "projects/.evil/x.md",
                 type: "reference",
                 content: "# X\nx",
                 create_dirs: true
               })
    end

    test "underscore-prefixed path segments are rejected the same way as dot-prefixed ones" do
      assert {:error, "Invalid path"} =
               Store.create(%{
                 path: "projects/_evil/x.md",
                 type: "reference",
                 content: "# X\nx",
                 create_dirs: true
               })
    end
  end

  describe "naming conventions and path normalization" do
    test "an unclean path is slugified; success carries path_normalized_from", %{vault: vault} do
      assert {:ok,
              %{path: "bike/cafe-overview.md", path_normalized_from: "bike/Café Overview!!.md"}} =
               Store.create(%{
                 path: "bike/Café Overview!!.md",
                 type: "reference",
                 content: "# Café Overview\ntext"
               })

      assert File.exists?(Path.join(vault, "bike/cafe-overview.md"))
      refute File.exists?(Path.join(vault, "bike/Café Overview!!.md"))
    end

    test "an already-canonical path has no path_normalized_from key" do
      assert {:ok, result} =
               Store.create(%{
                 path: "bike/already-clean.md",
                 type: "reference",
                 content: "# X\nx"
               })

      refute Map.has_key?(result, :path_normalized_from)
    end

    test "journal's naming.pattern rejects a non-date filename and suggests today's date" do
      assert {:error, msg} =
               Store.create(%{
                 path: "journal/some-note.md",
                 type: "reference",
                 content: "# X\nx"
               })

      assert msg =~ "does not match the schema"
      assert msg =~ "YYYY-MM-DD"
      today = Date.utc_today() |> Date.to_iso8601()
      assert msg =~ "journal/#{today}.md"
    end

    test "journal's naming.pattern accepts a conforming date filename" do
      assert {:ok, _} =
               Store.create(%{
                 path: "journal/2026-02-02.md",
                 type: "reference",
                 content: "# Journal Entry Test Day\ntext",
                 force: true
               })
    end

    test "a domain without a naming block is unaffected" do
      assert {:ok, _} =
               Store.create(%{
                 path: "bike/any-name.md",
                 type: "reference",
                 content: "# X\nx"
               })
    end

    test "move_note normalizes and naming-checks the destination too" do
      assert {:error, msg} =
               Store.move_note(%{
                 from: "bike/terra-speed.md",
                 to: "journal/not-a-date.md",
                 confirm: true
               })

      assert msg =~ "does not match the schema"

      assert {:ok, %{to: "journal/2026-03-03.md"}} =
               Store.move_note(%{
                 from: "bike/terra-speed.md",
                 to: "journal/2026-03-03.md",
                 confirm: true
               })
    end
  end

  describe "rewrite_note" do
    test "replaces the body but keeps the frontmatter; requires confirm", %{vault: vault} do
      assert {:error, msg} =
               Store.rewrite_note(%{
                 path: "bike/terra-speed.md",
                 content: "# New\nCompletely new."
               })

      assert msg =~ "confirm: true"

      assert {:ok, _} =
               Store.rewrite_note(%{
                 path: "bike/terra-speed.md",
                 content: "# New\nCompletely new.",
                 confirm: true
               })

      raw = File.read!(Path.join(vault, "bike/terra-speed.md"))
      assert raw =~ "type: reference"
      assert raw =~ "Completely new."
      refute raw =~ "Dimensions"

      {:ok, result} = Store.read("bike/terra-speed.md", false)
      assert result.type == :reference
    end

    test "confirm not required when the shrink stays under the threshold" do
      # via-carolina.md has 3 headings (Fueling, Second Half, Gear); this
      # removes only 1 — under both half-of-3 and the 20-heading floor.
      new_content = "# Via Carolina\n\n## Fueling\nbaseline.\n\n## Gear\nFrame bag."

      assert {:ok, _} = Store.rewrite_note(%{path: "bike/via-carolina.md", content: new_content})

      {:ok, result} = Store.read("bike/via-carolina.md", false)
      assert Enum.map(result.toc, & &1.heading) == ["Fueling", "Gear"]
    end

    test "confirm required when more than 20 headings would be removed, even under half", %{
      vault: vault
    } do
      many =
        for n <- 1..30, do: "## Section #{n}\nContent #{n}."

      assert {:ok, _} =
               Store.create(%{
                 path: "bike/many.md",
                 type: "reference",
                 content: "# Many Sections\n\n" <> Enum.join(many, "\n\n"),
                 force: true
               })

      few = for n <- 1..5, do: "## Section #{n}\nContent #{n}."
      few_content = "# Many Sections\n\n" <> Enum.join(few, "\n\n")

      assert {:error, msg} = Store.rewrite_note(%{path: "bike/many.md", content: few_content})
      assert msg =~ "removes 25 of 30 headings"

      assert {:ok, _} =
               Store.rewrite_note(%{path: "bike/many.md", content: few_content, confirm: true})

      raw = File.read!(Path.join(vault, "bike/many.md"))
      refute raw =~ "Section 6"
    end
  end

  # Which lines are dropped is Vigil.Vault.Edit's job now and is covered
  # there (edit_test.exs) without git. This is the wiring smoke test.
  describe "delete_section" do
    test "removes the section; the index no longer resolves it" do
      assert {:ok, _} = Store.delete_section("bike/via-carolina.md#gear")
      assert {:error, _} = Store.read("bike/via-carolina.md#gear", false)
    end
  end

  describe "update_frontmatter" do
    test "changes type without touching the body, no confirm needed" do
      assert {:ok, _} =
               Store.update_frontmatter(%{path: "bike/terra-speed.md", type: "decision"})

      {:ok, result} = Store.read("bike/terra-speed.md", false)
      assert result.type == :decision
      assert Store.search(%{query: "tubeless"}) |> Enum.any?(&(&1.id =~ "terra-speed"))
    end

    test "enforces the same starts/ends rules as create" do
      assert {:error, _} =
               Store.update_frontmatter(%{path: "bike/terra-speed.md", type: "event"})
    end
  end

  describe "delete" do
    test "removes the note from disk and the index; requires confirm", %{vault: vault} do
      assert {:error, msg} = Store.delete_note(%{path: "bike/terra-speed.md"})
      assert msg =~ "confirm: true"

      assert {:ok, %{pushed: true}} =
               Store.delete_note(%{path: "bike/terra-speed.md", confirm: true})

      refute File.exists?(Path.join(vault, "bike/terra-speed.md"))
      assert {:error, _} = Store.read("bike/terra-speed.md", false)
      refute Store.search(%{query: "tubeless"}) |> Enum.any?(&(&1.id =~ "terra-speed"))
    end

    test "reports broken backlinks in the same call when confirm is passed up front" do
      assert {:ok, %{broken_backlinks: broken_backlinks}} =
               Store.delete_note(%{path: "bike/terra-speed.md", confirm: true})

      assert "bike/via-carolina.md" in broken_backlinks
    end
  end

  describe "move" do
    test "renames the note, updates the index; requires confirm", %{vault: vault} do
      assert {:error, msg} =
               Store.move_note(%{from: "bike/terra-speed.md", to: "bike/terra-40c.md"})

      assert msg =~ "confirm: true"

      assert {:ok, %{pushed: true}} =
               Store.move_note(%{
                 from: "bike/terra-speed.md",
                 to: "bike/terra-40c.md",
                 confirm: true
               })

      refute File.exists?(Path.join(vault, "bike/terra-speed.md"))
      assert File.exists?(Path.join(vault, "bike/terra-40c.md"))
      assert {:error, _} = Store.read("bike/terra-speed.md", false)
      {:ok, result} = Store.read("bike/terra-40c.md", false)
      assert result.title == "WTB Terra Speed 40C"
    end

    test "rejects a destination that already exists" do
      assert {:error, msg} =
               Store.move_note(%{
                 from: "bike/terra-speed.md",
                 to: "bike/via-carolina.md",
                 confirm: true
               })

      assert msg =~ "already exists"
    end

    test "destination still runs through domain validation" do
      assert {:error, _} =
               Store.move_note(%{
                 from: "bike/terra-speed.md",
                 to: "unbekannt/x.md",
                 confirm: true
               })
    end
  end

  # Each finding's rule (duplicate headings, sentence-like headings, orphaned
  # links, overlong notes, stale decisions) is Vigil.Index's job now and is
  # covered there (index_test.exs) without git. This is the wiring smoke
  # test: a write lands in the report Store.lint/1 returns.
  describe "lint" do
    test "reports duplicate headings, sentence-like headings, and orphaned links" do
      {:ok, _} =
        Store.create(%{
          path: "bike/messy.md",
          type: "reference",
          content:
            "# Messy\n\n## Duplicate\nOne.\n\n## Duplicate\nTwo.\n\n" <>
              "## This is a rather long heading with punctuation and a full stop.\nText.\n\n" <>
              "## Reference\nSee [[does-not-exist]].\n"
        })

      report = Store.lint()

      assert Enum.any?(report.duplicate_headings, &(&1.path == "bike/messy.md"))
      assert Enum.any?(report.sentence_headings, &String.starts_with?(&1.id, "bike/messy.md"))
      assert "does-not-exist" in report.orphaned_links
    end
  end

  describe "skills isolation" do
    test "skills never appear in search, have no index chunk, no backlinks" do
      assert Store.search(%{query: "TDD"}) == []
      assert Store.search(%{query: "Failing Test"}) == []
    end

    # Thin end-to-end wiring check: skill_list/skill_read/skill_write reach
    # Vigil.Skills through the GenServer and the write still serializes
    # through Store's single mailbox. Full behavioral coverage (name
    # validation, frontmatter validation, SkillKey token) lives in
    # test/vigil/skills_test.exs.
    test "skill_list, skill_read, and skill_write work end-to-end through the GenServer" do
      [skill] = Store.skill_list()
      assert skill.name == "tdd"

      {:ok, %{content: c1}} = Store.skill_read("tdd")
      {:ok, %{content: c2}} = Store.skill_read("tdd.md")
      assert c1 == c2
      assert c1 =~ "SkillKey:"

      assert {:error, msg} = Store.skill_read("does-not-exist")
      assert msg =~ "tdd"

      assert {:ok, %{name: "new", pushed: true}} =
               Store.skill_write(
                 "new",
                 "---\nname: new\ndescription: test skill\n---\n# New\n1. one"
               )

      {:ok, %{content: content}} = Store.skill_read("new")
      assert content =~ "1. one"
      assert Store.search(%{query: "one"}) == []
    end
  end

  describe "reload" do
    test "reload re-reads the vault and reports success" do
      assert %{reloaded: true} = Store.reload()
      assert Store.search(%{query: "tires"}) != []
    end

    test "reload with an unreachable remote reports pull_failed but still reparses", %{
      vault: vault
    } do
      :ok = stop_supervised(Store)
      start_supervised!({Store, vault_path: vault, exclude: [], git_remote: "nonexistent-remote"})

      assert %{reloaded: true, pull_failed: reason} = Store.reload()
      assert is_binary(reason)
      assert Store.search(%{query: "tires"}) != []
    end
  end

  describe "write-path robustness" do
    test "push failure is returned as an error; read and search keep working", %{vault: vault} do
      :ok = stop_supervised(Store)
      start_supervised!({Store, vault_path: vault, exclude: [], git_remote: "nonexistent-remote"})

      assert {:error, msg} =
               Store.create(%{path: "bike/new.md", type: "reference", content: "# New\ntext"})

      assert msg =~ "push failed"
      assert File.exists?(Path.join(vault, "bike/new.md"))

      assert Store.search(%{query: "tires"}) != []
      assert {:ok, _} = Store.read("bike/via-carolina.md", false)
    end

    test "writing into a read-only domain directory returns a precise error, store stays alive",
         %{
           vault: vault
         } do
      dir = Path.join(vault, "home")
      File.chmod!(dir, 0o555)

      result = Store.create(%{path: "home/new.md", type: "reference", content: "# New\ntext"})

      File.chmod!(dir, 0o755)

      assert {:error, msg} = result
      assert msg =~ "Could not write file"
      assert {:ok, _} = Store.read("home/diacritics-äöü-café.md", false)
    end

    test "append against an unreadable file returns a clean error, store stays alive", %{
      vault: vault
    } do
      path = Path.join(vault, "bike/via-carolina.md")
      File.chmod!(path, 0o000)

      result = Store.append(%{path: "bike/via-carolina.md", content: "Extra."})

      File.chmod!(path, 0o644)

      assert {:error, msg} = result
      assert msg =~ "Could not read file"
      assert Store.search(%{query: "tires"}) != []
      assert {:ok, _} = Store.read("bike/via-carolina.md", false)
    end

    test "replace_section against an unreadable file returns a clean error, store stays alive", %{
      vault: vault
    } do
      path = Path.join(vault, "bike/via-carolina.md")
      File.chmod!(path, 0o000)

      result = Store.replace_section("bike/via-carolina.md#fueling", "New strategy.")

      File.chmod!(path, 0o644)

      assert {:error, msg} = result
      assert msg =~ "Could not read file"
      assert Store.search(%{query: "tires"}) != []
      assert {:ok, _} = Store.read("bike/via-carolina.md", false)
    end

    test "delete_section against an unreadable file returns a clean error, store stays alive", %{
      vault: vault
    } do
      path = Path.join(vault, "bike/via-carolina.md")
      File.chmod!(path, 0o000)

      result = Store.delete_section("bike/via-carolina.md#gear")

      File.chmod!(path, 0o644)

      assert {:error, msg} = result
      assert msg =~ "Could not read file"
      assert Store.search(%{query: "tires"}) != []
      assert {:ok, _} = Store.read("bike/via-carolina.md", false)
    end

    test "rewrite_note against an unreadable file returns a clean error, store stays alive", %{
      vault: vault
    } do
      path = Path.join(vault, "bike/terra-speed.md")
      File.chmod!(path, 0o000)

      result =
        Store.rewrite_note(%{
          path: "bike/terra-speed.md",
          content: "# New\nCompletely new.",
          confirm: true
        })

      File.chmod!(path, 0o644)

      assert {:error, msg} = result
      assert msg =~ "Could not read file"
      assert Store.search(%{query: "tires"}) != []
      assert {:ok, _} = Store.read("bike/terra-speed.md", false)
    end

    test "update_frontmatter against an unreadable file returns a clean error, store stays alive",
         %{vault: vault} do
      path = Path.join(vault, "bike/terra-speed.md")
      File.chmod!(path, 0o000)

      result = Store.update_frontmatter(%{path: "bike/terra-speed.md", type: "decision"})

      File.chmod!(path, 0o644)

      assert {:error, msg} = result
      assert msg =~ "Could not read file"
      assert Store.search(%{query: "tires"}) != []
      assert {:ok, _} = Store.read("bike/terra-speed.md", false)
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
      {:ok, result} = Store.links("bike/Via Carolina!!.md", :out, 1)
      assert result.id == "bike/via-carolina.md"
    end

    test "move_note reports broken_backlinks for a link that no longer resolves, keeps a still-resolving one out" do
      assert {:ok, _} =
               Store.create(%{
                 path: "bike/references-explicitly.md",
                 type: "reference",
                 content: "# References Terra Speed\nSee [Terra Speed](bike/terra-speed.md)."
               })

      assert {:ok, result} =
               Store.move_note(%{
                 from: "bike/terra-speed.md",
                 to: "training/terra-speed.md",
                 confirm: true
               })

      assert "bike/references-explicitly.md" in result.broken_backlinks
      refute "bike/via-carolina.md" in result.broken_backlinks
    end

    test "delete_note's confirm-required message lists current backlinks" do
      assert {:error, msg} = Store.delete_note(%{path: "bike/terra-speed.md"})
      assert msg =~ "incoming references"
      assert msg =~ "bike/via-carolina.md"
    end

    test "removing a link from a note's content clears it from the target's incoming links (no ghost entry)" do
      assert {:ok, _} =
               Store.create(%{
                 path: "bike/references-first.md",
                 type: "reference",
                 content: "# References First\nSee [[terra-speed]]."
               })

      {:ok, before} = Store.links("bike/terra-speed.md", :in, 1)
      assert Enum.any?(before.incoming, &(&1.source == "bike/references-first.md"))

      assert {:ok, _} =
               Store.rewrite_note(%{
                 path: "bike/references-first.md",
                 content: "# References First\nNo reference any more.",
                 confirm: true
               })

      {:ok, after_} = Store.links("bike/terra-speed.md", :in, 1)
      refute Enum.any?(after_.incoming, &(&1.source == "bike/references-first.md"))
    end
  end

  # Regression: skills/ and notes are "one repository, two systems"
  # (docs/design.md). Before Vigil.Vault.Policy the four write paths below
  # applied no writable-path rule, so a caller could append to, rewrite,
  # retype or delete a skill through a note tool — and the skill was then
  # parsed and indexed as a searchable note.
  describe "skills/ is not reachable through the note write tools" do
    test "append cannot write into skills/", %{vault: vault} do
      assert {:error, "Invalid path"} =
               Store.append(%{path: "skills/tdd.md", content: "INJECTED"})

      refute File.read!(Path.join(vault, "skills/tdd.md")) =~ "INJECTED"
    end

    test "rewrite_note cannot overwrite a skill" do
      assert {:error, "Invalid path"} =
               Store.rewrite_note(%{path: "skills/tdd.md", content: "# Pwned\n\nbody\n"})
    end

    test "update_frontmatter cannot retype a skill" do
      assert {:error, "Invalid path"} =
               Store.update_frontmatter(%{path: "skills/tdd.md", type: "decision"})
    end

    test "delete_note cannot delete a skill", %{vault: vault} do
      assert {:error, "Invalid path"} =
               Store.delete_note(%{path: "skills/tdd.md", confirm: true})

      assert File.exists?(Path.join(vault, "skills/tdd.md"))
    end

    test "a skill never becomes searchable through a write" do
      Store.append(%{path: "skills/tdd.md", content: "INJECTEDWORD"})
      assert Store.search(%{query: "INJECTEDWORD"}) == []
    end
  end
end
