defmodule Vigil.IndexTest do
  use ExUnit.Case, async: true

  alias Vigil.{Index, Parser, VaultDiscovery}

  @fixtures Path.expand("../fixtures/vault", __DIR__)
  @git_meta %{
    created_at: ~U[2026-01-01 10:00:00Z],
    updated_at: ~U[2026-01-01 10:00:00Z],
    last_author: "Daniel"
  }

  # The `limit` the MCP table supplies on every real call. Vigil.MCP.Tools
  # declares it (1..25, default 10) and refuses anything else, so search/2
  # requires one rather than inventing a second default.
  defp search(index, params), do: Index.search(index, Map.put_new(params, :limit, 10))

  # search/2 is pure over an %Index{} — no GenServer, no fixture vault, no
  # Parser needed to reach it. These build the bare struct directly, the way
  # the ranking tests here used to build a synthetic item for a since-removed
  # `Vigil.Search.run/3`.
  defp ranking_chunk(overrides) do
    Map.merge(
      %Index.Chunk{
        id: "x/a.md",
        path: "x/a.md",
        domain: "x",
        file_title: "A",
        heading_path: [],
        type: :reference,
        body: "",
        body_downcased: "",
        updated_at: nil
      },
      overrides
    )
  end

  defp ranking_index(chunks), do: %Index{chunks: Map.new(chunks, &{&1.id, &1})}

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
      assert search(index, %{query: "raised bed", domain: "training"}) == []

      assert [%{id: "garden/raised-bed.md"}] =
               search(index, %{query: "raised bed", domain: "garden"})
    end

    test "type filter is applied", %{index: index} do
      results = search(index, %{query: "vigil", type: :decision})
      assert Enum.all?(results, &(&1.type == :decision))
      refute Enum.any?(results, &(&1.id == "projects/vigil/vigil.md"))
    end

    test "journal is hidden unless asked for by name", %{index: index} do
      refute search(index, %{query: "terra speed"})
             |> Enum.any?(&String.starts_with?(&1.id, "journal/"))

      assert search(index, %{query: "terra speed", domain: "journal"})
             |> Enum.any?(&String.starts_with?(&1.id, "journal/"))
    end

    test "prefer boost ranks the preferred type first", %{index: index} do
      results = search(index, %{query: "vigil", prefer: :decision})
      assert Enum.at(results, 0).type == :decision
    end

    test "empty result is an empty list, not an error", %{index: index} do
      assert search(index, %{query: "nowhereatall"}) == []
    end

    test "hub is present when exactly one other note links to the hit's note", %{index: index} do
      results = search(index, %{query: "tubeless", domain: "bike"})
      hit = Enum.find(results, &(&1.id =~ "terra-speed"))
      assert hit.hub == "bike/via-carolina.md"
    end

    test "hub is absent when zero notes link to the hit's note", %{index: index} do
      {:ok, file} = Parser.parse("bike/unlinked.md", "# Unlinked Tubeless\ntext", @git_meta)
      updated = Index.put(index, file)

      results = search(updated, %{query: "unlinked tubeless"})
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

      results = search(updated, %{query: "tubeless", domain: "bike"})
      hit = Enum.find(results, &(&1.id =~ "terra-speed"))
      refute Map.has_key?(hit, :hub)
    end
  end

  describe "search/2 — ranking" do
    test "title hit outranks body hit" do
      index =
        ranking_index([
          ranking_chunk(%{
            id: "x/a.md",
            file_title: "Terra Speed",
            body: "nothing",
            body_downcased: "nothing"
          }),
          ranking_chunk(%{
            id: "x/b.md",
            file_title: "Anderes",
            body: "mentions terra speed once",
            body_downcased: "mentions terra speed once"
          })
        ])

      [first, second] = search(index, %{query: "terra speed"})
      assert first.id == "x/a.md"
      assert second.id == "x/b.md"
      assert first.score > second.score
    end

    test "prefer hint boosts matching type" do
      index =
        ranking_index([
          ranking_chunk(%{
            id: "x/ref.md",
            type: :reference,
            body: "wort",
            body_downcased: "wort"
          }),
          ranking_chunk(%{id: "x/dec.md", type: :decision, body: "wort", body_downcased: "wort"})
        ])

      [first, _second] = search(index, %{query: "wort", prefer: :decision})
      assert first.id == "x/dec.md"
    end

    test "preview is capped at 120 characters" do
      long_body = String.duplicate("word ", 40)

      index =
        ranking_index([
          ranking_chunk(%{file_title: "Treffer", body: long_body, body_downcased: long_body})
        ])

      [result] = search(index, %{query: "treffer"})
      assert String.length(result.preview) <= 121
    end

    test "phrase match requires contiguous substring" do
      index =
        ranking_index([
          ranking_chunk(%{
            id: "x/together.md",
            body: "terra speed is good",
            body_downcased: "terra speed is good"
          }),
          ranking_chunk(%{
            id: "x/apart.md",
            body: "terra Reifen ... weit entfernt speed",
            body_downcased: "terra reifen ... weit entfernt speed"
          })
        ])

      results = search(index, %{query: "terra speed"})
      assert Enum.map(results, & &1.id) == ["x/together.md"]
    end

    test "limit is taken at its word — no clamp, no default of its own" do
      chunks = for n <- 1..30, do: ranking_chunk(%{id: "x/#{n}.md", file_title: "Treffer #{n}"})
      index = ranking_index(chunks)

      assert length(search(index, %{query: "treffer", limit: 25})) == 25
      assert length(search(index, %{query: "treffer", limit: 3})) == 3
    end

    test "a limit is required: search/2 does not invent one" do
      index = ranking_index([ranking_chunk(%{file_title: "Treffer"})])

      assert_raise KeyError, fn -> Index.search(index, %{query: "treffer"}) end
    end
  end

  # The scale a caller filters a score against. Vigil.Vault.Policy's
  # duplicate gate keeps hits at strength(:title) and above, so these are
  # load-bearing for a module outside this one: they are published rather
  # than inferred.
  describe "strength/1" do
    test "each kind contributes what it is published as" do
      title = ranking_index([ranking_chunk(%{file_title: "Terra"})])
      assert [%{score: score}] = search(title, %{query: "terra"})
      assert score == Index.strength(:title)

      heading = ranking_index([ranking_chunk(%{heading_path: ["Terra"]})])
      assert [%{score: score}] = search(heading, %{query: "terra"})
      assert score == Index.strength(:heading)

      once = ranking_index([ranking_chunk(%{body: "terra", body_downcased: "terra"})])
      assert [%{score: score}] = search(once, %{query: "terra"})
      assert score == Index.strength(:body_occurrence)

      preferred =
        ranking_index([ranking_chunk(%{file_title: "Terra", type: :decision})])

      assert [%{score: score}] = search(preferred, %{query: "terra", prefer: :decision})
      assert score == Index.strength(:title) + Index.strength(:preferred_type)
    end

    test "the body contributes at most its published maximum, however often it hits" do
      body = String.duplicate("terra ", 20)
      index = ranking_index([ranking_chunk(%{body: body, body_downcased: body})])

      assert [%{score: score}] = search(index, %{query: "terra"})
      assert score == Index.strength(:body_occurrences_max)
    end

    # Which is why strength(:title) is documented as "the query names this
    # note", not as "the title matched": a heading hit with the body at its
    # maximum reaches exactly the same score.
    test "a heading hit with the body at its maximum reaches a title hit's score" do
      body = String.duplicate("terra ", 20)

      index =
        ranking_index([
          ranking_chunk(%{heading_path: ["Terra"], body: body, body_downcased: body})
        ])

      assert [%{score: score}] = search(index, %{query: "terra"})
      assert score == Index.strength(:heading) + Index.strength(:body_occurrences_max)
      assert score == Index.strength(:title)
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

      assert [finding] = Enum.filter(report.duplicate_headings, &(&1.path == "bike/messy.md"))
      assert finding.slug == "duplicate"
      assert finding.headings == ["Duplicate"]
      assert finding.ids == ["bike/messy.md#duplicate", "bike/messy.md#duplicate-2"]
    end

    # What collides is the heading text's slug, not the heading chain: these
    # two really do become #b and #b-2. Grouping by the chain reported nothing.
    test "same heading under two different H2s is a duplicate", %{index: index} do
      {:ok, file} =
        Parser.parse(
          "bike/chains.md",
          "# Chains\n\n## A\n\n### B\nOne.\n\n## C\n\n### B\nTwo.\n",
          @git_meta
        )

      updated = Index.put(index, file)
      report = Index.lint(updated, ~U[2026-01-01 10:00:00Z])

      assert [finding] = Enum.filter(report.duplicate_headings, &(&1.path == "bike/chains.md"))
      assert finding.ids == ["bike/chains.md#b", "bike/chains.md#b-2"]
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

    # The same definition Vigil.VaultCheck reports, owned by Vigil.Vault.Rules:
    # headings and words, not a chunk count.
    test "overlong notes name the axis that was crossed", %{index: index} do
      headings = for n <- 1..31, do: "## Section #{n}\nContent #{n}."
      content = "# Many\n\n" <> Enum.join(headings, "\n\n")
      {:ok, file} = Parser.parse("bike/many.md", content, @git_meta)

      updated = Index.put(index, file)
      report = Index.lint(updated, ~U[2026-01-01 10:00:00Z])

      assert [finding] = Enum.filter(report.overlong_notes, &(&1.path == "bike/many.md"))
      assert finding.headings == 31
      assert finding.over_heading_threshold
      refute finding.over_word_threshold
      assert finding.words > 0
    end

    test "a note with 35 headings is overlong to lint, as it already was to the doctor",
         %{index: index} do
      headings = for n <- 1..35, do: "## Section #{n}\nContent #{n}."

      {:ok, file} =
        Parser.parse("bike/many.md", "# Many\n\n" <> Enum.join(headings, "\n\n"), @git_meta)

      report = index |> Index.put(file) |> Index.lint(~U[2026-01-01 10:00:00Z])

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

  describe "event_notes/1" do
    test "returns the event-typed notes and nothing else", %{index: index} do
      paths = index |> Index.event_notes() |> Enum.map(& &1.path)

      assert "bike/via-carolina.md" in paths
      assert Enum.all?(Index.event_notes(index), &(&1.type == :event))
      refute Enum.empty?(Map.values(index.notes) -- Index.event_notes(index))
    end

    test "a vault with no events publishes nothing", %{index: index} do
      without_events = Index.remove(index, "bike/via-carolina.md")

      assert Index.event_notes(without_events) == []
    end
  end

  describe "lookups/1 find_chunk" do
    test "returns the Chunk struct at an id, or nil", %{index: index} do
      find = Index.lookups(index).find_chunk

      assert %Index.Chunk{heading: "Fueling"} = find.("bike/via-carolina.md#fueling")
      assert find.("bike/via-carolina.md#nope") == nil
    end

    test "resolves leniently, as read/3 does, and carries the canonical path", %{index: index} do
      assert %Index.Chunk{id: "bike/via-carolina.md#fueling", path: "bike/via-carolina.md"} =
               Index.lookups(index).find_chunk.("bike/Via Carolina!!.md#fueling")
    end

    test "nil for an id without a fragment", %{index: index} do
      assert Index.lookups(index).find_chunk.("bike/via-carolina.md") == nil
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

  describe "put/2 and move/3 own created_at" do
    @later %{
      created_at: ~U[2026-06-01 09:00:00Z],
      updated_at: ~U[2026-06-01 09:00:00Z],
      last_author: "vigil"
    }

    defp reparsed(rel_path, meta) do
      content = File.read!(Path.join(@fixtures, rel_path))
      {:ok, file} = Parser.parse(rel_path, content, meta)
      file
    end

    test "replacing a note the index holds keeps its creation date", %{index: index} do
      rewritten = Index.put(index, reparsed("bike/via-carolina.md", @later))

      note = Index.note(rewritten, "bike/via-carolina.md")
      assert note.created_at == @git_meta.created_at
      assert note.updated_at == @later.updated_at
    end

    test "the note's chunks keep it too", %{index: index} do
      rewritten = Index.put(index, reparsed("bike/via-carolina.md", @later))

      {:ok, chunk} = Index.read(rewritten, "bike/via-carolina.md#fueling", false)
      assert chunk.created_at == DateTime.to_iso8601(@git_meta.created_at)
    end

    test "a note the index has not seen takes the commit metadata's value", %{index: index} do
      {:ok, fresh} = Parser.parse("bike/fresh.md", "# Fresh\n\nbody\n", @later)

      assert Index.note(Index.put(index, fresh), "bike/fresh.md").created_at ==
               @later.created_at
    end

    test "a move onto the note's own path keeps the note", %{index: index} do
      same_path =
        Index.move(index, "bike/via-carolina.md", reparsed("bike/via-carolina.md", @later))

      note = Index.note(same_path, "bike/via-carolina.md")
      assert note.created_at == @git_meta.created_at
      assert {:ok, _} = Index.read(same_path, "bike/via-carolina.md#fueling", false)
    end

    test "a move carries the creation date from the source path", %{index: index} do
      content = File.read!(Path.join(@fixtures, "bike/via-carolina.md"))
      {:ok, moved} = Parser.parse("training/via-carolina.md", content, @later)

      after_move = Index.move(index, "bike/via-carolina.md", moved)

      assert Index.note(after_move, "bike/via-carolina.md") == nil
      assert Index.note(after_move, "training/via-carolina.md").created_at == @git_meta.created_at
    end
  end

  describe "lookups/1 count_headings" do
    test "counts chunks with a heading, ignoring the pre-heading chunk", %{index: index} do
      assert Index.lookups(index).count_headings.("bike/via-carolina.md") == 3
    end

    test "zero for an unknown path", %{index: index} do
      assert Index.lookups(index).count_headings.("bike/nope.md") == 0
    end
  end

  describe "lookups/1 find_section" do
    test "finds the chunk whose heading slugifies to the same slug", %{index: index} do
      find = Index.lookups(index).find_section

      assert %Index.Chunk{heading: "Gear"} = find.("bike/via-carolina.md", "Gear")
      assert %Index.Chunk{heading: "Gear"} = find.("bike/via-carolina.md", "gear!")
    end

    test "nil when no heading in the note matches", %{index: index} do
      assert Index.lookups(index).find_section.("bike/via-carolina.md", "Weather") == nil
    end

    test "nil for an unknown path", %{index: index} do
      assert Index.lookups(index).find_section.("bike/nope.md", "Gear") == nil
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
