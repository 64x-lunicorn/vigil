defmodule Vigil.IndexTest do
  use ExUnit.Case, async: true

  alias Vigil.{Index, Parser, VaultDiscovery}

  @fixtures Path.expand("../fixtures/vault", __DIR__)
  @git_meta %{
    created_at: ~U[2026-01-01 10:00:00Z],
    updated_at: ~U[2026-01-01 10:00:00Z],
    last_author: "Daniel"
  }

  defp parse(rel_path) do
    content = File.read!(Path.join(@fixtures, rel_path))
    {:ok, file} = Parser.parse(rel_path, content, @git_meta)
    file
  end

  defp parsed_fixture_files do
    @fixtures
    |> VaultDiscovery.discover_files()
    |> Enum.map(&parse/1)
  end

  setup do
    %{index: Index.build(parsed_fixture_files())}
  end

  describe "read/3 — chunk by id" do
    test "returns exactly that chunk, without backlinks by default", %{index: index} do
      {:ok, result} = Index.read(index, "bike/via-carolina.md#fueling", false)

      assert result.heading == "Fueling"
      assert result.body =~ "baseline"
      refute Map.has_key?(result, :backlinks)
    end

    test "backlinks is opt-in (note-level, even for a chunk read)", %{index: index} do
      {:ok, with_backlinks} = Index.read(index, "bike/terra-speed.md#dimensions", true)
      assert with_backlinks.backlinks == ["bike/via-carolina.md"]

      {:ok, without_backlinks} = Index.read(index, "bike/terra-speed.md#dimensions", false)
      refute Map.has_key?(without_backlinks, :backlinks)
    end
  end

  describe "read/3 — note by path" do
    test "returns a table of contents and links out/in/broken counters", %{index: index} do
      {:ok, result} = Index.read(index, "bike/via-carolina.md", false)

      assert result.title == "Via Carolina"
      refute Map.has_key?(result, :body)
      assert Enum.map(result.toc, & &1.heading) == ["Fueling", "Second Half", "Gear"]

      # via-carolina.md links out to terra-speed.md, and is itself linked to
      # from training/note-without-anything.md — see fixture vault.
      assert result.links == %{out: 1, in: 1, broken: 0}
    end

    test "backlinks is opt-in", %{index: index} do
      {:ok, result} = Index.read(index, "bike/terra-speed.md", true)
      assert "bike/via-carolina.md" in result.backlinks
    end
  end

  describe "read/3 — lenient path" do
    test "an id that misses exactly is retried once through path normalization", %{index: index} do
      {:ok, result} = Index.read(index, "Bike/Via-Carolina.md", false)
      assert result.path == "bike/via-carolina.md"
    end
  end

  describe "read/3 — invalid and missing" do
    test "a path that fails the safety check answers Invalid path", %{index: index} do
      assert Index.read(index, "../etc/passwd", false) == {:error, "Invalid path"}
    end

    test "anything else answers Not found", %{index: index} do
      assert {:error, "Not found: bike/nope.md"} = Index.read(index, "bike/nope.md", false)
    end
  end

  describe "put/2 and remove/2" do
    test "put makes a new note (and its links) show up in read", %{index: index} do
      {:ok, file} = Parser.parse("bike/new.md", "# New\n\nSee [[via-carolina]].\n", @git_meta)

      updated = Index.put(index, file)

      assert {:ok, result} = Index.read(updated, "bike/new.md", false)
      assert result.title == "New"

      {:ok, via_carolina} = Index.read(updated, "bike/via-carolina.md", false)
      assert via_carolina.links == %{out: 1, in: 2, broken: 0}
    end

    test "remove makes read answer Not found again, and drops its links", %{index: index} do
      {:ok, file} = Parser.parse("bike/new.md", "# New\n\nSee [[via-carolina]].\n", @git_meta)
      with_new = Index.put(index, file)

      removed = Index.remove(with_new, "bike/new.md")

      assert Index.read(removed, "bike/new.md", false) == {:error, "Not found: bike/new.md"}

      {:ok, via_carolina} = Index.read(removed, "bike/via-carolina.md", false)
      assert via_carolina.links == %{out: 1, in: 1, broken: 0}
    end
  end

  describe "search/2" do
    test "domain filter is applied", %{index: index} do
      assert Index.search(index, %{query: "raised bed", domain: "training"}) == []

      assert [%{id: "garden/raised-bed.md"}] =
               Index.search(index, %{query: "raised bed", domain: "garden"})
    end

    test "type filter is applied", %{index: index} do
      results = Index.search(index, %{query: "vigil", type: :decision})
      assert Enum.all?(results, &(&1.type == :decision))
      refute Enum.any?(results, &(&1.id == "projects/vigil/vigil.md"))
    end

    test "journal is hidden unless asked for by name", %{index: index} do
      refute Index.search(index, %{query: "terra speed"})
             |> Enum.any?(&String.starts_with?(&1.id, "journal/"))

      assert Index.search(index, %{query: "terra speed", domain: "journal"})
             |> Enum.any?(&String.starts_with?(&1.id, "journal/"))
    end

    test "prefer boost ranks the preferred type first", %{index: index} do
      results = Index.search(index, %{query: "vigil", prefer: :decision})
      assert Enum.at(results, 0).type == :decision
    end

    test "empty result is an empty list, not an error", %{index: index} do
      assert Index.search(index, %{query: "nowhereatall"}) == []
    end

    test "hub is present when exactly one other note links to the hit's note", %{index: index} do
      results = Index.search(index, %{query: "tubeless", domain: "bike"})
      hit = Enum.find(results, &(&1.id =~ "terra-speed"))
      assert hit.hub == "bike/via-carolina.md"
    end

    test "hub is absent when zero notes link to the hit's note", %{index: index} do
      {:ok, file} = Parser.parse("bike/unlinked.md", "# Unlinked Tubeless\ntext", @git_meta)
      updated = Index.put(index, file)

      results = Index.search(updated, %{query: "unlinked tubeless"})
      hit = Enum.find(results, &(&1.id =~ "unlinked"))
      refute Map.has_key?(hit, :hub)
    end

    test "hub is absent when several notes link to the hit's note", %{index: index} do
      {:ok, second_linker} =
        Parser.parse(
          "garden/verweist-auch.md",
          "# Also References\nSee [[terra-speed]].",
          @git_meta
        )

      updated = Index.put(index, second_linker)

      results = Index.search(updated, %{query: "tubeless", domain: "bike"})
      hit = Enum.find(results, &(&1.id =~ "terra-speed"))
      refute Map.has_key?(hit, :hub)
    end
  end

  describe "links/4" do
    test "outgoing to a broken note", %{index: index} do
      {:ok, file} =
        Parser.parse(
          "bike/points-nowhere.md",
          "# Points Nowhere\nSee [[does-not-exist]].",
          @git_meta
        )

      updated = Index.put(index, file)

      {:ok, result} = Index.links(updated, "bike/points-nowhere.md", :out, 1)

      assert [%{target: "does-not-exist", status: "broken"}] =
               Enum.map(result.outgoing, &Map.take(&1, [:target, :status]))
    end

    test "outgoing to an existing note but a nonexistent fragment names the fragment", %{
      index: index
    } do
      {:ok, file} =
        Parser.parse(
          "bike/references-missing-section.md",
          "# References Missing Section\nSee [[via-carolina#does-not-exist]].",
          @git_meta
        )

      updated = Index.put(index, file)

      {:ok, result} = Index.links(updated, "bike/references-missing-section.md", :out, 1)

      assert [%{target: "via-carolina#does-not-exist", status: "broken"}] =
               Enum.map(result.outgoing, &Map.take(&1, [:target, :status]))
    end

    test "outgoing ambiguous link lists its candidates", %{index: index} do
      {:ok, doppel1} =
        Parser.parse("bike/doppelganger.md", "# Doppelganger\nA.", @git_meta)

      {:ok, doppel2} =
        Parser.parse("training/doppelganger.md", "# Doppelganger\nB.", @git_meta)

      {:ok, referencer} =
        Parser.parse(
          "garden/verweist-mehrdeutig.md",
          "# References Ambiguously\nSee [[doppelganger]].",
          @git_meta
        )

      updated = index |> Index.put(doppel1) |> Index.put(doppel2) |> Index.put(referencer)

      {:ok, result} = Index.links(updated, "garden/verweist-mehrdeutig.md", :out, 1)

      assert [%{status: "ambiguous", candidates: candidates}] =
               Enum.map(result.outgoing, &Map.take(&1, [:status, :candidates]))

      assert Enum.sort(candidates) == ["bike/doppelganger.md", "training/doppelganger.md"]
    end

    test "incoming finds a link from another domain", %{index: index} do
      {:ok, result} = Index.links(index, "bike/via-carolina.md", :in, 1)
      assert Enum.any?(result.incoming, &(&1.source == "training/note-without-anything.md"))
    end

    test "depth 2 adds each directly connected note's own depth-1 view", %{index: index} do
      {:ok, result} = Index.links(index, "bike/via-carolina.md", :both, 2)
      assert Map.has_key?(result.neighbors, "bike/terra-speed.md")

      neighbor = result.neighbors["bike/terra-speed.md"]
      assert Enum.any?(neighbor.incoming, &(&1.source == "bike/via-carolina.md"))
    end

    test "depth 3 is an error", %{index: index} do
      assert {:error, msg} = Index.links(index, "bike/via-carolina.md", :both, 3)
      assert msg =~ "depth"
    end

    test "lenient path resolution", %{index: index} do
      {:ok, result} = Index.links(index, "bike/Via Carolina!!.md", :out, 1)
      assert result.id == "bike/via-carolina.md"
    end
  end

  describe "lint/2" do
    test "duplicate headings", %{index: index} do
      {:ok, file} =
        Parser.parse(
          "bike/messy.md",
          "# Messy\n\n## Duplicate\nOne.\n\n## Duplicate\nTwo.\n",
          @git_meta
        )

      updated = Index.put(index, file)
      report = Index.lint(updated, ~U[2026-01-01 10:00:00Z])

      assert Enum.any?(report.duplicate_headings, &(&1.path == "bike/messy.md"))
    end

    test "sentence-like headings", %{index: index} do
      {:ok, file} =
        Parser.parse(
          "bike/messy.md",
          "# Messy\n\n## This is a rather long heading with punctuation and a full stop.\nText.\n",
          @git_meta
        )

      updated = Index.put(index, file)
      report = Index.lint(updated, ~U[2026-01-01 10:00:00Z])

      assert Enum.any?(report.sentence_headings, &String.starts_with?(&1.id, "bike/messy.md"))
    end

    test "orphaned links, labelled with the fragment when present", %{index: index} do
      {:ok, file} =
        Parser.parse(
          "bike/references-missing-section.md",
          "# References Missing Section\nSee [[via-carolina#does-not-exist]].",
          @git_meta
        )

      updated = Index.put(index, file)
      report = Index.lint(updated, ~U[2026-01-01 10:00:00Z])

      assert "via-carolina#does-not-exist" in report.orphaned_links
    end

    test "overlong notes past the chunk threshold", %{index: index} do
      headings = for n <- 1..45, do: "## Section #{n}\nContent #{n}."
      content = "# Many\n\n" <> Enum.join(headings, "\n\n")
      {:ok, file} = Parser.parse("bike/many.md", content, @git_meta)

      updated = Index.put(index, file)
      report = Index.lint(updated, ~U[2026-01-01 10:00:00Z])

      assert Enum.any?(report.overlong_notes, &(&1.path == "bike/many.md"))
    end

    test "decision notes stale relative to an injected now", %{index: index} do
      long_after = DateTime.add(~U[2026-01-01 10:00:00Z], 200 * 86_400, :second)
      report = Index.lint(index, long_after)

      assert Enum.any?(report.stale_decisions, &(&1.path == "projects/vigil/vigil-ranking.md"))
    end
  end

  describe "current/2" do
    test "an active event appears in current", %{index: index} do
      during_event = ~U[2026-07-11 00:00:00Z]
      result = Index.current(index, during_event)

      assert Enum.any?(result.active, &(&1.id == "bike/via-carolina.md"))
    end
  end

  describe "snapshot/2" do
    test "a vault with events returns active ids, near lists, and titles", %{index: index} do
      during_event = ~U[2026-07-11 00:00:00Z]
      snapshot = Index.snapshot(index, during_event)

      assert MapSet.member?(snapshot.active_ids, "bike/via-carolina.md")
      assert Enum.any?(snapshot.near.active, &(&1.id == "bike/via-carolina.md"))
      assert snapshot.titles["bike/via-carolina.md"] == "Via Carolina"
    end

    test "a vault with no events returns empty ids, near lists, and titles", %{index: index} do
      without_events = Index.remove(index, "bike/via-carolina.md")
      now = ~U[2026-07-11 00:00:00Z]

      assert Index.snapshot(without_events, now) == %{
               active_ids: MapSet.new(),
               near: %{active: [], upcoming: []},
               titles: %{}
             }
    end
  end

  describe "chunk/2" do
    test "returns the Chunk struct at an id, or nil", %{index: index} do
      assert %Index.Chunk{heading: "Fueling"} = Index.chunk(index, "bike/via-carolina.md#fueling")
      assert Index.chunk(index, "bike/via-carolina.md#nope") == nil
    end
  end

  describe "backlinks/2" do
    test "incoming references to a note path", %{index: index} do
      assert Index.backlinks(index, "bike/via-carolina.md") == [
               "training/note-without-anything.md"
             ]
    end

    test "empty for a note with no incoming references", %{index: index} do
      assert Index.backlinks(index, "garden/raised-bed.md") == []
    end
  end

  describe "heading_count/2" do
    test "counts chunks with a heading, ignoring the pre-heading chunk", %{index: index} do
      assert Index.heading_count(index, "bike/via-carolina.md") == 3
    end

    test "zero for an unknown path", %{index: index} do
      assert Index.heading_count(index, "bike/nope.md") == 0
    end
  end

  describe "chunk_by_heading/3" do
    test "finds the chunk whose heading slugifies to the target slug", %{index: index} do
      assert %Index.Chunk{heading: "Gear"} =
               Index.chunk_by_heading(index, "bike/via-carolina.md", "gear")
    end

    test "nil when no heading in the note matches", %{index: index} do
      assert Index.chunk_by_heading(index, "bike/via-carolina.md", "weather") == nil
    end

    test "nil for an unknown path", %{index: index} do
      assert Index.chunk_by_heading(index, "bike/nope.md", "gear") == nil
    end
  end

  describe "note/2 and size/1" do
    test "note/2 returns the Note struct at a path, or nil", %{index: index} do
      assert %Index.Note{path: "bike/via-carolina.md", title: "Via Carolina"} =
               Index.note(index, "bike/via-carolina.md")

      assert Index.note(index, "bike/nope.md") == nil
    end

    test "note/2 carries created_at — the write path's created_at-preservation question", %{
      index: index
    } do
      assert Index.note(index, "bike/via-carolina.md").created_at == @git_meta.created_at
    end

    test "size/1 counts notes and chunks", %{index: index} do
      files = parsed_fixture_files()

      assert Index.size(index) == %{
               notes: length(files),
               chunks: files |> Enum.flat_map(& &1.chunks) |> length()
             }
    end
  end
end
