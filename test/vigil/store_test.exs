defmodule Vigil.StoreTest do
  use ExUnit.Case, async: false

  alias Vigil.Store

  setup do
    {vault, remote} = Vigil.FixtureVault.build(remote: true)
    on_exit(fn -> Vigil.FixtureVault.cleanup(vault) end)
    start_supervised!({Store, vault_path: vault, exclude: [], git_remote: "origin"})
    %{vault: vault, remote: remote}
  end

  describe "search" do
    test "a term in domain bike returns ranked hits with previews, no bodies" do
      results = Store.search(%{query: "tires", domain: "bike"})
      assert results != []
      refute Map.has_key?(hd(results), :body)
      assert Enum.all?(results, &(String.length(&1.preview) <= 121))
    end

    test "domain filter is applied" do
      results = Store.search(%{query: "raised bed", domain: "training"})
      assert results == []
      results2 = Store.search(%{query: "raised bed", domain: "garden"})
      assert length(results2) == 1
    end

    test "prefer hint boosts type" do
      results = Store.search(%{query: "vigil", prefer: :decision})
      assert Enum.at(results, 0).type == :decision
    end

    test "empty result is an empty list, not an error" do
      assert Store.search(%{query: "nowhereatall"}) == []
    end

    test "journal is hidden unless domain explicitly requested" do
      assert Store.search(%{query: "terra speed"})
             |> Enum.all?(&(not String.starts_with?(&1.id, "journal/")))

      results = Store.search(%{query: "terra speed", domain: "journal"})
      assert Enum.any?(results, &String.starts_with?(&1.id, "journal/"))
    end

    test "dynamic domain: garden is discovered without code changes" do
      results = Store.search(%{query: "raised bed"})
      assert Enum.any?(results, &(&1.id == "garden/raised-bed.md"))
    end
  end

  describe "read" do
    test "reading a fragment returns exactly that chunk" do
      {:ok, result} = Store.read("bike/via-carolina.md#fueling", false)
      assert result.heading == "Fueling"
      assert result.body =~ "baseline"
      refute Map.has_key?(result, :backlinks)
    end

    test "reading without a fragment returns TOC without body" do
      {:ok, result} = Store.read("bike/via-carolina.md", false)
      assert result.title == "Via Carolina"
      refute Map.has_key?(result, :body)
      headings = Enum.map(result.toc, & &1.heading)
      assert headings == ["Fueling", "Second Half", "Gear"]
    end

    test "backlinks is opt-in" do
      {:ok, result} = Store.read("bike/terra-speed.md", true)
      assert "bike/via-carolina.md" in result.backlinks
    end

    test "unknown id returns isError-style tuple" do
      assert {:error, _} = Store.read("bike/nope.md", false)
    end
  end

  describe "create" do
    test "creates file, commits as vigil, pushes, and updates ETS", %{vault: vault} do
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

  describe "append" do
    test "appends under an existing heading, at the end of that section, not at EOF", %{
      vault: vault
    } do
      assert {:ok, _} =
               Store.append(%{
                 path: "bike/via-carolina.md",
                 heading: "Gear",
                 content: "Extra: repair kit."
               })

      raw = File.read!(Path.join(vault, "bike/via-carolina.md"))
      assert raw =~ "Frame bag, no saddle bag.\nExtra: repair kit."
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

  describe "replace_section" do
    test "replaces only the target chunk's body; rest of file is byte-identical", %{vault: vault} do
      before_content = File.read!(Path.join(vault, "bike/via-carolina.md"))

      assert {:ok, _} =
               Store.replace_section("bike/via-carolina.md#fueling", "New fueling strategy.")

      after_content = File.read!(Path.join(vault, "bike/via-carolina.md"))

      assert after_content =~ "New fueling strategy."
      assert after_content =~ "### Second Half"
      assert after_content =~ "525mg caffeine, concentrated."
      assert after_content =~ "## Gear"

      before_lines = String.split(before_content, "\n")
      after_lines = String.split(after_content, "\n")
      assert Enum.take(before_lines, 5) == Enum.take(after_lines, 5)
    end

    test "content with a heading of any covered rank is rejected" do
      assert {:error, _} = Store.replace_section("bike/via-carolina.md#fueling", "## New\ntext")
    end

    test "id without a fragment is rejected" do
      assert {:error, _} = Store.replace_section("bike/via-carolina.md", "text")
    end
  end

  describe "current" do
    test "classifies active/upcoming/recently_past relative to an injected now" do
      before_event = ~U[2026-07-09 00:00:00Z] |> DateTime.shift_zone!("Europe/Berlin")
      during_event = ~U[2026-07-11 00:00:00Z] |> DateTime.shift_zone!("Europe/Berlin")
      after_event = ~U[2026-07-13 12:00:00Z] |> DateTime.shift_zone!("Europe/Berlin")

      r1 = Store.current(before_event)
      assert Enum.any?(r1.upcoming, &(&1.id == "bike/via-carolina.md"))

      r2 = Store.current(during_event)
      assert Enum.any?(r2.active, &(&1.id == "bike/via-carolina.md"))

      r3 = Store.current(after_event)
      assert Enum.any?(r3.recently_past, &(&1.id == "bike/via-carolina.md"))
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

    test "read finds a note via a non-canonical path (lenient lookup)" do
      {:ok, canonical} = Store.read("bike/via-carolina.md", false)
      {:ok, lenient} = Store.read("bike/Via Carolina!!.md", false)
      assert lenient.title == canonical.title
    end

    test "read finds a chunk via a non-canonical path with a fragment" do
      assert {:ok, result} = Store.read("bike/Via Carolina!!.md#fueling", false)
      assert result.heading == "Fueling"
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

  describe "delete_section" do
    test "removes heading and body; rest of the file stays intact", %{vault: vault} do
      assert {:ok, _} = Store.delete_section("bike/via-carolina.md#gear")

      raw = File.read!(Path.join(vault, "bike/via-carolina.md"))
      refute raw =~ "## Gear"
      refute raw =~ "Frame bag"
      assert raw =~ "## Fueling"

      assert {:error, _} = Store.read("bike/via-carolina.md#gear", false)
    end

    test "id without a fragment is rejected" do
      assert {:error, _} = Store.delete_section("bike/via-carolina.md")
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

    test "flags decision notes as stale relative to an injected now" do
      long_after = DateTime.add(~U[2026-01-01 10:00:00Z], 200 * 86_400, :second)
      report = Store.lint(long_after)

      assert Enum.any?(report.stale_decisions, &(&1.path == "projects/vigil/vigil-ranking.md"))
    end
  end

  describe "skills isolation" do
    test "skills never appear in search, have no ETS chunk, no backlinks" do
      assert Store.search(%{query: "TDD"}) == []
      assert Store.search(%{query: "Failing Test"}) == []
    end

    test "skill_list, skill_read with/without .md, and error case" do
      [skill] = Store.skill_list()
      assert skill.name == "tdd"
      assert skill.description =~ "test coverage"

      {:ok, %{content: c1}} = Store.skill_read("tdd")
      {:ok, %{content: c2}} = Store.skill_read("tdd.md")
      assert c1 == c2

      assert {:error, msg} = Store.skill_read("does-not-exist")
      assert msg =~ "tdd"
    end

    test "skill_read's error case reveals the current SkillKey (AP9a §9.2 bootstrap fix)" do
      assert {:error, msg} = Store.skill_read("does-not-exist")
      assert msg =~ "SkillKey:"

      [_, token] = Regex.run(~r/SkillKey: ([0-9a-f]+)/, msg)
      assert token == Vigil.SkillKey.current(Vigil.SkillKey.secret())
    end

    test "skill_write requires name and description in frontmatter, commits but does not reparse" do
      assert {:error, _} = Store.skill_write("broken", "---\nname: broken\n---\n# x")

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
  end

  describe "links" do
    test "resolves a same-folder basename link" do
      {:ok, result} = Store.links("bike/via-carolina.md", :out, 1)

      assert Enum.any?(
               result.outgoing,
               &(&1.target == "bike/terra-speed.md" and &1.status == "ok")
             )
    end

    test "resolves a cross-domain basename link via vault-wide fallback" do
      {:ok, result} = Store.links("training/note-without-anything.md", :out, 1)

      assert [%{target: "bike/via-carolina.md", status: "ok"}] =
               Enum.map(result.outgoing, &Map.take(&1, [:target, :status]))
    end

    test "a link to an existing note with a nonexistent fragment names the fragment, not just the note" do
      assert {:ok, _} =
               Store.create(%{
                 path: "bike/references-missing-section.md",
                 type: "reference",
                 content: "# References Missing Section\nSee [[via-carolina#does-not-exist]]."
               })

      {:ok, result} = Store.links("bike/references-missing-section.md", :out, 1)

      assert [%{target: "via-carolina#does-not-exist", status: "broken"}] =
               Enum.map(result.outgoing, &Map.take(&1, [:target, :status]))

      # Otherwise the lint finding would read as "note via-carolina is
      # missing" when only the section is missing.
      assert "via-carolina#does-not-exist" in Store.lint().orphaned_links
    end

    test "a link to a nonexistent note is broken" do
      assert {:ok, _} =
               Store.create(%{
                 path: "bike/points-nowhere.md",
                 type: "reference",
                 content: "# Points Nowhere\nSee [[does-not-exist]]."
               })

      {:ok, result} = Store.links("bike/points-nowhere.md", :out, 1)

      assert [%{target: "does-not-exist", status: "broken"}] =
               Enum.map(result.outgoing, &Map.take(&1, [:target, :status]))
    end

    test "same basename in two folders is ambiguous outside either folder" do
      assert {:ok, _} =
               Store.create(%{
                 path: "bike/doppelganger.md",
                 type: "reference",
                 content: "# Doppelganger\nA."
               })

      assert {:ok, _} =
               Store.create(%{
                 path: "training/doppelganger.md",
                 type: "reference",
                 content: "# Doppelganger\nB.",
                 force: true
               })

      assert {:ok, _} =
               Store.create(%{
                 path: "garden/verweist-mehrdeutig.md",
                 type: "reference",
                 content: "# References Ambiguously\nSee [[doppelganger]]."
               })

      {:ok, result} = Store.links("garden/verweist-mehrdeutig.md", :out, 1)

      assert [%{status: "ambiguous", candidates: candidates}] =
               Enum.map(result.outgoing, &Map.take(&1, [:status, :candidates]))

      assert Enum.sort(candidates) == ["bike/doppelganger.md", "training/doppelganger.md"]
    end

    test "an explicit path link resolves independent of ambiguity" do
      assert {:ok, _} =
               Store.create(%{
                 path: "bike/doppelganger.md",
                 type: "reference",
                 content: "# Doppelganger\nA."
               })

      assert {:ok, _} =
               Store.create(%{
                 path: "garden/references-by-path.md",
                 type: "reference",
                 content: "# References By Path\nSee [Doppelganger](bike/doppelganger.md)."
               })

      {:ok, result} = Store.links("garden/references-by-path.md", :out, 1)

      assert [%{target: "bike/doppelganger.md", status: "ok"}] =
               Enum.map(result.outgoing, &Map.take(&1, [:target, :status]))
    end

    test "a fragment link resolves to the specific chunk" do
      assert {:ok, _} =
               Store.create(%{
                 path: "garden/references-a-section.md",
                 type: "reference",
                 content: "# References A Section\nSee [[via-carolina#fueling]]."
               })

      {:ok, result} = Store.links("garden/references-a-section.md", :out, 1)

      assert [%{target: "bike/via-carolina.md#fueling", status: "ok"}] =
               Enum.map(result.outgoing, &Map.take(&1, [:target, :status]))
    end

    test "incoming direction finds a link from another folder" do
      {:ok, result} = Store.links("bike/via-carolina.md", :in, 1)
      assert Enum.any?(result.incoming, &(&1.source == "training/note-without-anything.md"))
    end

    test "depth 2 includes neighbors, depth 3 is an error" do
      {:ok, result} = Store.links("bike/via-carolina.md", :both, 2)
      assert Map.has_key?(result.neighbors, "bike/terra-speed.md")

      assert {:error, msg} = Store.links("bike/via-carolina.md", :both, 3)
      assert msg =~ "depth"
    end

    test "links tool works via a lenient (non-canonical) path" do
      {:ok, result} = Store.links("bike/Via Carolina!!.md", :out, 1)
      assert result.id == "bike/via-carolina.md"
    end

    test "read on a note carries links out/in/broken counts" do
      {:ok, result} = Store.read("bike/via-carolina.md", false)
      assert result.links.out == 1
      assert result.links.in == 1
      assert result.links.broken == 0
    end

    test "search attaches hub when the hit note has exactly one incoming link" do
      results = Store.search(%{query: "tubeless", domain: "bike"})
      assert Enum.any?(results, &(&1.id =~ "terra-speed" and &1.hub == "bike/via-carolina.md"))
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

    test "[[Painpoints]], [[painpoints]] and [[PAINPOINTS]] all resolve to the same note" do
      assert {:ok, _} =
               Store.create(%{
                 path: "bike/painpoints.md",
                 type: "reference",
                 content: "# Painpoints\ntext"
               })

      for {target, n} <- Enum.with_index(["Painpoints", "painpoints", "PAINPOINTS"]) do
        path = "garden/verweist-#{n}.md"

        assert {:ok, _} =
                 Store.create(%{
                   path: path,
                   type: "reference",
                   content: "# References #{n}\nSee [[#{target}]].",
                   force: true
                 })

        {:ok, result} = Store.links(path, :out, 1)

        assert [%{target: "bike/painpoints.md", status: "ok"}] =
                 Enum.map(result.outgoing, &Map.take(&1, [:target, :status]))
      end
    end

    test "same-folder match wins even when an ambiguous sibling exists elsewhere" do
      assert {:ok, _} =
               Store.create(%{
                 path: "bike/doppelganger.md",
                 type: "reference",
                 content: "# Doppelganger\nA."
               })

      assert {:ok, _} =
               Store.create(%{
                 path: "training/doppelganger.md",
                 type: "reference",
                 content: "# Doppelganger\nB.",
                 force: true
               })

      assert {:ok, _} =
               Store.create(%{
                 path: "bike/references-same-folder.md",
                 type: "reference",
                 content: "# References Same Folder\nSee [[doppelganger]]."
               })

      {:ok, result} = Store.links("bike/references-same-folder.md", :out, 1)

      assert [%{target: "bike/doppelganger.md", status: "ok"}] =
               Enum.map(result.outgoing, &Map.take(&1, [:target, :status]))
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

    test "search omits hub when a note has zero or more than one incoming link" do
      assert {:ok, _} =
               Store.create(%{
                 path: "bike/unlinked.md",
                 type: "reference",
                 content: "# Unlinked Tubeless\ntext"
               })

      results = Store.search(%{query: "unlinked tubeless"})
      hit = Enum.find(results, &(&1.id =~ "unlinked"))
      refute Map.has_key?(hit, :hub)

      # more than one incoming note → no hub either
      assert {:ok, _} =
               Store.create(%{
                 path: "garden/verweist-auch.md",
                 type: "reference",
                 content: "# Also References\nSee [[terra-speed]]."
               })

      results2 = Store.search(%{query: "tubeless", domain: "bike"})
      hit2 = Enum.find(results2, &(&1.id =~ "terra-speed"))
      refute Map.has_key?(hit2, :hub)
    end
  end
end
