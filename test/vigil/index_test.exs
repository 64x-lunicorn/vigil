defmodule Vigil.IndexTest do
  use ExUnit.Case, async: true

  alias Vigil.{Index, Parser, Slug}
  alias Vigil.Vault.Layout

  @fixtures Path.expand("../fixtures/vault", __DIR__)
  @git_meta %{
    created_at: ~U[2026-01-01 10:00:00Z],
    updated_at: ~U[2026-01-01 10:00:00Z],
    last_author: "Daniel"
  }

  # The `limit` the MCP table supplies on every real call. Vigil.MCP.Tools
  # declares it (1..25, default 10) and refuses anything else, so search/2
  # requires one rather than inventing a second default.
  defp search(index, params) do
    {:ok, %{results: results}} = Index.search(index, Map.put_new(params, :limit, 10))
    results
  end

  # search/2 is pure over an %Index{} — no GenServer, no fixture vault, no
  # Parser needed to reach it. These build the bare struct directly, the way
  # the ranking tests here used to build a synthetic item for a since-removed
  # `Vigil.Search.run/3`.
  defp ranking_chunk(overrides) do
    Map.merge(
      %Parser.Chunk{
        id: "x/a.md",
        path: "x/a.md",
        domain: "x",
        file_title: "A",
        heading_path: [],
        type: :reference,
        body: "",
        updated_at: nil
      },
      overrides
    )
    |> with_folded_text()
  end

  # What Vigil.Index adds to a chunk as it indexes one: the text search
  # compares against, folded once.
  defp with_folded_text(chunk) do
    %{
      chunk
      | folded: %{
          title: Slug.fold(chunk.file_title),
          headings: Enum.map(chunk.heading_path, &Slug.fold/1),
          body: Slug.fold(chunk.body)
        }
    }
  end

  defp ranking_index(chunks), do: %Index{chunks: Map.new(chunks, &{&1.id, &1})}

  defp parse(rel_path) do
    content = File.read!(Path.join(@fixtures, rel_path))
    {:ok, file} = Parser.parse(rel_path, content, @git_meta)
    file
  end

  defp parsed_fixture_files do
    @fixtures
    |> Layout.over_vault()
    |> Layout.note_paths()
    |> Enum.map(&parse/1)
  end

  setup do
    %{index: Index.build(parsed_fixture_files())}
  end

  describe "read/2 — chunk by id" do
    test "returns exactly that chunk, without backlinks by default", %{index: index} do
      {:ok, result} = Index.read(index, %{id: "bike/via-carolina.md#fueling", backlinks: false})

      assert result.heading == "Fueling"
      assert result.body =~ "baseline"
      refute Map.has_key?(result, :backlinks)
    end

    test "backlinks is opt-in (note-level, even for a chunk read)", %{index: index} do
      {:ok, with_backlinks} =
        Index.read(index, %{id: "bike/terra-speed.md#dimensions", backlinks: true})

      assert with_backlinks.backlinks == ["bike/via-carolina.md"]

      {:ok, without_backlinks} =
        Index.read(index, %{id: "bike/terra-speed.md#dimensions", backlinks: false})

      refute Map.has_key?(without_backlinks, :backlinks)
    end

    # What `replace_section` and `delete_section` take back as `if_match`
    # (docs/design.md, "A retried write is applied once"): the SHA-256 of the
    # heading and the body, so the same content hashes the same wherever it
    # has been renumbered to.
    test "carries the hash of its heading and body", %{index: index} do
      {:ok, result} = Index.read(index, %{id: "bike/via-carolina.md#fueling", backlinks: false})

      expected =
        :crypto.hash(:sha256, "Fueling\nSteady baseline intake across the day.")
        |> Base.encode16(case: :lower)

      assert result.hash == expected
    end
  end

  describe "read/2 — note by path" do
    test "returns the preamble as its body, a table of contents and links out/in/broken counters",
         %{index: index} do
      {:ok, result} = Index.read(index, %{id: "bike/via-carolina.md", backlinks: false})

      assert result.title == "Via Carolina"
      assert result.body == "328 km Prague to Nuremberg. Tires: [[terra-speed|Terra Speed]]."
      assert Enum.map(result.toc, & &1.heading) == ["Fueling", "Second Half", "Gear"]

      {:ok, fueling} = Index.read(index, %{id: "bike/via-carolina.md#fueling", backlinks: false})
      assert hd(result.toc).hash == fueling.hash

      # via-carolina.md links out to terra-speed.md, and is itself linked to
      # from training/note-without-anything.md — see fixture vault.
      assert result.links == %{out: 1, in: 1, broken: 0}
    end

    # docs/design.md, "Chunking": the text before the first `##` is the
    # note's own chunk, and reading the note is how it is read back.
    test "a note with no ## heading returns its text and an empty table of contents",
         %{index: index} do
      {:ok, result} = Index.read(index, %{id: "garden/raised-bed.md", backlinks: false})

      assert result.body == "A raised bed built from larch wood, three levels, south-facing."
      assert result.toc == []
    end

    test "a note with no heading at all returns every paragraph of it", %{index: index} do
      {:ok, result} =
        Index.read(index, %{id: "training/note-without-anything.md", backlinks: false})

      assert result.body =~ ~r/\AShort paragraph with no frontmatter/
      assert result.body =~ ~r/still unstructured\. The transfer stage was long but doable\.\z/
    end

    test "a note whose first line after the H1 is a ## heading has an empty body",
         %{index: index} do
      {:ok, result} = Index.read(index, %{id: "bike/terra-speed.md", backlinks: false})

      assert result.body == ""
      assert Enum.map(result.toc, & &1.heading) == ["Dimensions", "Gravel Experience"]
    end

    test "a search hit on a preamble names an id that reads back as the preamble text",
         %{index: index} do
      [hit] = search(index, %{query: "larch wood"})

      {:ok, result} = Index.read(index, %{id: hit.id, backlinks: false})

      assert result.body =~ "larch wood"
    end

    test "backlinks is opt-in", %{index: index} do
      {:ok, result} = Index.read(index, %{id: "bike/terra-speed.md", backlinks: true})
      assert "bike/via-carolina.md" in result.backlinks
    end
  end

  describe "read/2 — lenient path" do
    test "an id that misses exactly is retried once through path normalization", %{index: index} do
      {:ok, result} = Index.read(index, %{id: "Bike/Via-Carolina.md", backlinks: false})
      assert result.path == "bike/via-carolina.md"
    end
  end

  describe "read/2 — invalid and missing" do
    test "a path that fails the safety check answers Invalid path", %{index: index} do
      assert Index.read(index, %{id: "../etc/passwd", backlinks: false}) ==
               {:error, "Invalid path"}
    end

    test "anything else answers Not found", %{index: index} do
      assert {:error, "Not found: bike/nope.md"} =
               Index.read(index, %{id: "bike/nope.md", backlinks: false})
    end
  end

  describe "put/2 and remove/2" do
    test "put makes a new note (and its links) show up in read", %{index: index} do
      {:ok, file} = Parser.parse("bike/new.md", "# New\n\nSee [[via-carolina]].\n", @git_meta)

      updated = Index.put(index, file)

      assert {:ok, result} = Index.read(updated, %{id: "bike/new.md", backlinks: false})
      assert result.title == "New"

      {:ok, via_carolina} = Index.read(updated, %{id: "bike/via-carolina.md", backlinks: false})
      assert via_carolina.links == %{out: 1, in: 2, broken: 0}
    end

    test "remove makes read answer Not found again, and drops its links", %{index: index} do
      {:ok, file} = Parser.parse("bike/new.md", "# New\n\nSee [[via-carolina]].\n", @git_meta)
      with_new = Index.put(index, file)

      removed = Index.remove(with_new, "bike/new.md")

      assert Index.read(removed, %{id: "bike/new.md", backlinks: false}) ==
               {:error, "Not found: bike/new.md"}

      {:ok, via_carolina} = Index.read(removed, %{id: "bike/via-carolina.md", backlinks: false})
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

    # macOS writes file names, and editors on it sometimes text, decomposed
    # (NFD); an assistant sends its query composed (NFC).
    test "an NFD body is found by an NFC query, and by its transliteration", %{index: index} do
      nfd = String.normalize("# Tank\n\nDer Heizöltank ist voll.\n", :nfd)
      {:ok, file} = Parser.parse("home/tank.md", nfd, @git_meta)
      updated = Index.put(index, file)

      query = String.normalize("Heizöltank", :nfc)
      assert [%{id: "home/tank.md"}] = search(updated, %{query: query})
      assert [%{id: "home/tank.md"}] = search(updated, %{query: "heizoeltank voll"})
    end

    test "words of a query are found apart in an indexed note", %{index: index} do
      {:ok, file} =
        Parser.parse(
          "garden/tomatoes.md",
          "# Tomatoes\n\n## Where\n\nThey grow in the raised beds.\n",
          @git_meta
        )

      updated = Index.put(index, file)

      assert [%{id: "garden/tomatoes.md#where"}] =
               search(updated, %{query: "raised bed tomatoes", domain: "garden"})
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
            body: "nothing"
          }),
          ranking_chunk(%{
            id: "x/b.md",
            file_title: "Anderes",
            body: "mentions terra speed once"
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
            body: "wort"
          }),
          ranking_chunk(%{id: "x/dec.md", type: :decision, body: "wort"})
        ])

      [first, _second] = search(index, %{query: "wort", prefer: :decision})
      assert first.id == "x/dec.md"
    end

    test "preview is capped at 120 characters" do
      long_body = String.duplicate("word ", 40)

      index =
        ranking_index([
          ranking_chunk(%{file_title: "Treffer", body: long_body})
        ])

      [result] = search(index, %{query: "treffer"})
      assert String.length(result.preview) <= 121
    end

    test "a chunk holding all the query's words apart is found, below a phrase hit" do
      index =
        ranking_index([
          ranking_chunk(%{id: "x/together.md", body: "terra speed is good"}),
          ranking_chunk(%{
            id: "x/apart.md",
            file_title: "Speed and Terra",
            body: "terra Reifen ... weit entfernt speed"
          }),
          ranking_chunk(%{id: "x/one-word.md", file_title: "Terra", body: "only one of them"})
        ])

      results = search(index, %{query: "terra speed"})
      assert Enum.map(results, & &1.id) == ["x/together.md", "x/apart.md"]
    end

    test "a phrase hit ranks above a words-apart hit whatever their scores" do
      index =
        ranking_index([
          ranking_chunk(%{id: "x/phrase.md", body: "the raised bed"}),
          ranking_chunk(%{
            id: "x/apart.md",
            file_title: "Bed, raised",
            type: :decision,
            body: String.duplicate("raised and bed ", 10)
          })
        ])

      assert [phrase, apart] = search(index, %{query: "raised bed", prefer: :decision})
      assert phrase.id == "x/phrase.md"
      assert apart.id == "x/apart.md"
      assert apart.score > phrase.score
    end

    # A one-letter word is in nearly every chunk, inside longer words too:
    # as a word it would narrow nothing and cap a hit's score at its own
    # handful of stray letters. It is left out of the words — never out of
    # the phrase.
    test "a word of one letter is not one of the words a hit must hold" do
      index =
        ranking_index([
          ranking_chunk(%{id: "x/plan.md", file_title: "Plan", body: "nothing here"}),
          ranking_chunk(%{id: "x/letters.md", body: "xylophone yard"}),
          ranking_chunk(%{id: "x/phrase.md", body: "the letter x y"})
        ])

      assert [%{id: "x/plan.md", score: score}] = search(index, %{query: "Plan B"})
      assert score == Index.strength(:title)
      assert Enum.map(search(index, %{query: "x y"}), & &1.id) == ["x/phrase.md"]
      assert Enum.map(search(index, %{query: "y"}), & &1.id) == ["x/letters.md", "x/phrase.md"]
    end

    test "a chunk missing one of the query's words is not found" do
      index = ranking_index([ranking_chunk(%{body: "raised beds of tomatoes"})])

      assert search(index, %{query: "raised bed peppers"}) == []
    end

    # The words-apart score is the weakest word's: a hit is only as strong as
    # the least of the words it has to contain.
    test "a words-apart hit scores what its weakest word scores" do
      index =
        ranking_index([
          ranking_chunk(%{file_title: "Tomatoes", body: "raised, raised, raised, then tomatoes"})
        ])

      assert [%{score: score}] = search(index, %{query: "raised tomatoes"})
      # "raised": three body occurrences; "tomatoes": the title and one occurrence.
      assert score == 3 * Index.strength(:body_occurrence)
    end

    test "query and text are folded alike: heizoel finds Heizöl" do
      index =
        ranking_index([
          ranking_chunk(%{id: "x/tank.md", file_title: "Heizöl", body: "Der Heizöltank"})
        ])

      assert [%{id: "x/tank.md"}] = search(index, %{query: "heizoel"})
      assert [%{id: "x/tank.md"}] = search(index, %{query: "HEIZÖL"})
    end

    test "leading and trailing whitespace in a query is ignored" do
      index = ranking_index([ranking_chunk(%{id: "x/bed.md", body: "the raised bed"})])

      assert search(index, %{query: "  raised bed\n"}) == search(index, %{query: "raised bed"})
      assert [%{id: "x/bed.md"}] = search(index, %{query: " raised bed "})
      assert search(index, %{query: "   "}) == []
    end

    test "equal scores and times rank by id, so the order is the same on every call" do
      chunks = for id <- ~w(x/c.md x/a.md x/b.md), do: ranking_chunk(%{id: id, body: "wort"})
      index = ranking_index(chunks)

      assert Enum.map(search(index, %{query: "wort"}), & &1.id) == ~w(x/a.md x/b.md x/c.md)
    end

    test "limit is taken at its word — no clamp, no default of its own" do
      chunks = for n <- 1..30, do: ranking_chunk(%{id: "x/#{n}.md", file_title: "Treffer #{n}"})
      index = ranking_index(chunks)

      assert length(search(index, %{query: "treffer", limit: 25})) == 25
      assert length(search(index, %{query: "treffer", limit: 3})) == 3
    end

    test "a limit is required: search/2 does not invent one" do
      index = ranking_index([ranking_chunk(%{file_title: "Treffer"})])

      # Built rather than written as a literal: the type checker reads a literal
      # here and warns about the very shape this test exists to pass, which
      # would make the suite unable to run under --warnings-as-errors.
      without_limit = Map.new(query: "treffer")

      assert_raise KeyError, fn -> Index.search(index, without_limit) end
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

      once = ranking_index([ranking_chunk(%{body: "terra"})])
      assert [%{score: score}] = search(once, %{query: "terra"})
      assert score == Index.strength(:body_occurrence)

      preferred =
        ranking_index([ranking_chunk(%{file_title: "Terra", type: :decision})])

      assert [%{score: score}] = search(preferred, %{query: "terra", prefer: :decision})
      assert score == Index.strength(:title) + Index.strength(:preferred_type)
    end

    test "the body contributes at most its published maximum, however often it hits" do
      body = String.duplicate("terra ", 20)
      index = ranking_index([ranking_chunk(%{body: body})])

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
          ranking_chunk(%{heading_path: ["Terra"], body: body})
        ])

      assert [%{score: score}] = search(index, %{query: "terra"})
      assert score == Index.strength(:heading) + Index.strength(:body_occurrences_max)
      assert score == Index.strength(:title)
    end
  end

  describe "links/2" do
    test "outgoing to a broken note", %{index: index} do
      {:ok, file} =
        Parser.parse(
          "bike/points-nowhere.md",
          "# Points Nowhere\nSee [[does-not-exist]].",
          @git_meta
        )

      updated = Index.put(index, file)

      {:ok, result} =
        Index.links(updated, %{id: "bike/points-nowhere.md", direction: :out, depth: 1})

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

      {:ok, result} =
        Index.links(updated, %{
          id: "bike/references-missing-section.md",
          direction: :out,
          depth: 1
        })

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

      {:ok, result} =
        Index.links(updated, %{id: "garden/verweist-mehrdeutig.md", direction: :out, depth: 1})

      assert [%{status: "ambiguous", candidates: candidates}] =
               Enum.map(result.outgoing, &Map.take(&1, [:status, :candidates]))

      assert Enum.sort(candidates) == ["bike/doppelganger.md", "training/doppelganger.md"]
    end

    test "incoming finds a link from another domain", %{index: index} do
      {:ok, result} = Index.links(index, %{id: "bike/via-carolina.md", direction: :in, depth: 1})
      assert Enum.any?(result.incoming, &(&1.source == "training/note-without-anything.md"))
    end

    test "depth 2 adds each directly connected note's own depth-1 view", %{index: index} do
      {:ok, result} =
        Index.links(index, %{id: "bike/via-carolina.md", direction: :both, depth: 2})

      assert Map.has_key?(result.neighbors, "bike/terra-speed.md")

      neighbor = result.neighbors["bike/terra-speed.md"]
      assert Enum.any?(neighbor.incoming, &(&1.source == "bike/via-carolina.md"))
    end

    test "lenient path resolution", %{index: index} do
      {:ok, result} =
        Index.links(index, %{id: "bike/Via Carolina!!.md", direction: :out, depth: 1})

      assert result.id == "bike/via-carolina.md"
    end

    # Both readers resolve an id the same way, so both refuse the same way:
    # a path that fails the safety check is not quoted back at the caller, a
    # miss is.
    test "invalid and missing ids answer as read/2 does", %{index: index} do
      assert Index.links(index, %{id: "../etc/passwd", direction: :out, depth: 1}) ==
               {:error, "Invalid path"}

      assert Index.links(index, %{id: "bike/nope.md", direction: :out, depth: 1}) ==
               {:error, "Not found: bike/nope.md"}
    end
  end

  describe "lint/2" do
    # docs/design.md, "A note that is not UTF-8 is skipped".
    test "names the notes the load skipped for not being UTF-8, until one is deleted" do
      index = Index.build([], ["bike/windows-note.md", "bike/another.md"])
      now = %{now: ~U[2026-01-01 10:00:00Z]}

      assert Index.lint(index, now).invalid_utf8 == ["bike/another.md", "bike/windows-note.md"]

      assert Index.lint(Index.remove(index, "bike/windows-note.md"), now).invalid_utf8 ==
               ["bike/another.md"]
    end

    test "duplicate headings", %{index: index} do
      {:ok, file} =
        Parser.parse(
          "bike/messy.md",
          "# Messy\n\n## Duplicate\nOne.\n\n## Duplicate\nTwo.\n",
          @git_meta
        )

      updated = Index.put(index, file)
      report = Index.lint(updated, %{now: ~U[2026-01-01 10:00:00Z]})

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
      report = Index.lint(updated, %{now: ~U[2026-01-01 10:00:00Z]})

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
      report = Index.lint(updated, %{now: ~U[2026-01-01 10:00:00Z]})

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
      report = Index.lint(updated, %{now: ~U[2026-01-01 10:00:00Z]})

      assert "via-carolina#does-not-exist" in report.orphaned_links
    end

    # The same definition Vigil.VaultCheck reports, owned by Vigil.Vault.Rules:
    # headings and words, not a chunk count.
    test "overlong notes name the axis that was crossed", %{index: index} do
      headings = for n <- 1..31, do: "## Section #{n}\nContent #{n}."
      content = "# Many\n\n" <> Enum.join(headings, "\n\n")
      {:ok, file} = Parser.parse("bike/many.md", content, @git_meta)

      updated = Index.put(index, file)
      report = Index.lint(updated, %{now: ~U[2026-01-01 10:00:00Z]})

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

      report = index |> Index.put(file) |> Index.lint(%{now: ~U[2026-01-01 10:00:00Z]})

      assert Enum.any?(report.overlong_notes, &(&1.path == "bike/many.md"))
    end

    test "decision notes stale relative to an injected now", %{index: index} do
      long_after = DateTime.add(~U[2026-01-01 10:00:00Z], 200 * 86_400, :second)
      report = Index.lint(index, %{now: long_after})

      assert Enum.any?(report.stale_decisions, &(&1.path == "projects/vigil/vigil-ranking.md"))
    end
  end

  describe "current/2" do
    test "an active event appears in current", %{index: index} do
      during_event = ~U[2026-07-11 00:00:00Z]
      result = Index.current(index, %{now: during_event})

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

  describe "find_chunk/2" do
    test "returns the Chunk struct at an id, or nil", %{index: index} do
      assert %Parser.Chunk{heading: "Fueling"} =
               Index.find_chunk(index, "bike/via-carolina.md#fueling")

      assert Index.find_chunk(index, "bike/via-carolina.md#nope") == nil
    end

    test "resolves leniently, as read/2 does, and carries the canonical path", %{index: index} do
      assert %Parser.Chunk{id: "bike/via-carolina.md#fueling", path: "bike/via-carolina.md"} =
               Index.find_chunk(index, "bike/Via Carolina!!.md#fueling")
    end

    test "nil for an id without a fragment", %{index: index} do
      assert Index.find_chunk(index, "bike/via-carolina.md") == nil
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

  describe "relinks/3" do
    defp note_file(path, content) do
      {:ok, file} = Parser.parse(path, content, @git_meta)
      file
    end

    defp with_notes(index, notes) do
      Enum.reduce(notes, index, fn {path, content}, acc ->
        Index.put(acc, note_file(path, content))
      end)
    end

    test "names every link to the moved note, per linking note, with what it has to become",
         %{index: index} do
      index =
        with_notes(index, [
          {"bike/explicit.md", "# Explicit\nSee [t](bike/terra-speed.md#dimensions)."},
          {"training/basename.md", "# Basename\nSee [[terra-speed]]."}
        ])

      assert Index.relinks(index, "bike/terra-speed.md", "gear/terra-40c.md") == %{
               "bike/via-carolina.md" => %{"terra-speed" => "terra-40c"},
               "bike/explicit.md" => %{"bike/terra-speed" => "gear/terra-40c"},
               "training/basename.md" => %{"terra-speed" => "terra-40c"}
             }
    end

    test "a link that still leads to the note after the move is left alone", %{index: index} do
      # Same basename, same domain: [[terra-speed]] from via-carolina still finds it.
      assert Index.relinks(index, "bike/terra-speed.md", "bike/tyres/terra-speed.md") == %{}
    end

    test "a basename the cascade would send elsewhere becomes the note's path", %{index: index} do
      # After the move, [[terra-40c]] from bike/ finds bike/terra-40c.md first.
      index = with_notes(index, [{"bike/terra-40c.md", "# Another Terra 40c"}])

      assert Index.relinks(index, "bike/terra-speed.md", "training/terra-40c.md") == %{
               "bike/via-carolina.md" => %{"terra-speed" => "training/terra-40c"}
             }
    end

    test "a note linking to itself is named under the path it had", %{index: index} do
      index =
        with_notes(index, [
          {"bike/terra-speed.md",
           "# Terra\nSee [[bike/terra-speed.md#dimensions]].\n\n## Dimensions\n40mm."}
        ])

      assert %{"bike/terra-speed.md" => %{"bike/terra-speed.md" => "gear/terra-40c.md"}} =
               Index.relinks(index, "bike/terra-speed.md", "gear/terra-40c.md")
    end
  end

  describe "inbound_chunk_links/2" do
    test "links from other notes into the note's sections, not to the note as a whole",
         %{index: index} do
      index =
        index
        |> Index.put(
          note_file("bike/deep.md", "# Deep\nSee [[terra-speed#dimensions]] and [[terra-speed]].")
        )
        |> Index.put(
          note_file(
            "bike/terra-speed.md",
            "# Terra\nSelf: [[terra-speed#dimensions]].\n\n## Dimensions\n40mm."
          )
        )

      assert Index.inbound_chunk_links(index, "bike/terra-speed.md") == [
               %{from: "bike/deep.md", to: "bike/terra-speed.md#dimensions"}
             ]

      assert Index.inbound_chunk_links(index, "bike/unknown.md") == []
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

      {:ok, chunk} =
        Index.read(rewritten, %{id: "bike/via-carolina.md#fueling", backlinks: false})

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

      assert {:ok, _} =
               Index.read(same_path, %{id: "bike/via-carolina.md#fueling", backlinks: false})
    end

    test "a move carries the creation date from the source path", %{index: index} do
      content = File.read!(Path.join(@fixtures, "bike/via-carolina.md"))
      {:ok, moved} = Parser.parse("training/via-carolina.md", content, @later)

      after_move = Index.move(index, "bike/via-carolina.md", moved)

      assert Index.note(after_move, "bike/via-carolina.md") == nil
      assert Index.note(after_move, "training/via-carolina.md").created_at == @git_meta.created_at
    end
  end

  describe "count_headings/2" do
    test "counts chunks with a heading, ignoring the pre-heading chunk", %{index: index} do
      assert Index.count_headings(index, "bike/via-carolina.md") == 3
    end

    test "zero for an unknown path", %{index: index} do
      assert Index.count_headings(index, "bike/nope.md") == 0
    end
  end

  describe "find_section/3" do
    test "finds the chunk whose heading slugifies to the same slug", %{index: index} do
      assert %Parser.Chunk{heading: "Gear"} =
               Index.find_section(index, "bike/via-carolina.md", "Gear")

      assert %Parser.Chunk{heading: "Gear"} =
               Index.find_section(index, "bike/via-carolina.md", "gear!")
    end

    test "nil when no heading in the note matches", %{index: index} do
      assert Index.find_section(index, "bike/via-carolina.md", "Weather") == nil
    end

    test "nil for an unknown path", %{index: index} do
      assert Index.find_section(index, "bike/nope.md", "Gear") == nil
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

  # One chunk, one owner (docs/design.md, "Chunking"): what the index holds is
  # the value the parser produced, with the fields search needs on it.
  # Nothing copies it field by field, which is what this asserts by comparing
  # the whole struct — a field added to the parser's chunk arrives here with
  # no second edit, and a copy that forgot one would fail.
  describe "the chunk the index holds" do
    test "is the parser's own chunk, plus the note's domain and title, and its folded text",
         %{index: index} do
      parsed =
        parse("bike/via-carolina.md").chunks
        |> Enum.find(&(&1.heading == "Fueling"))

      assert Index.find_chunk(index, parsed.id) ==
               %{
                 parsed
                 | domain: "bike",
                   file_title: "Via Carolina",
                   folded: %{
                     title: "via carolina",
                     headings: ["fueling"],
                     body: "steady baseline intake across the day."
                   }
               }
    end
  end

  describe "list/2" do
    defp listed(index, params) do
      {:ok, page} = Index.list(index, Map.merge(%{sort: :updated, limit: 100}, params))
      page
    end

    defp dated(path, content, day) do
      at = DateTime.new!(Date.new!(2026, 3, day), ~T[10:00:00], "Etc/UTC")
      {:ok, file} = Parser.parse(path, content, %{@git_meta | updated_at: at})
      file
    end

    test "cards every note outside journal/, never a body", %{index: index} do
      page = listed(index, %{})

      assert Enum.map(page.notes, & &1.id) |> Enum.sort() == [
               "bike/terra-speed.md",
               "bike/via-carolina.md",
               "garden/raised-bed.md",
               "home/diacritics-äöü-café.md",
               "projects/vigil/vigil-mcp-config.md",
               "projects/vigil/vigil-ranking.md",
               "projects/vigil/vigil.md",
               "training/note-without-anything.md",
               "work/secret.md"
             ]

      assert %{id: "bike/terra-speed.md", type: :reference, updated_at: "2026-01-01T10:00:00Z"} =
               card = Enum.find(page.notes, &(&1.id == "bike/terra-speed.md"))

      assert Map.keys(card) |> Enum.sort() == [:id, :title, :type, :updated_at]
      assert page.next_cursor == nil
    end

    test "journal/ is listed only when it is the domain asked for", %{index: index} do
      refute Enum.any?(listed(index, %{}).notes, &String.starts_with?(&1.id, "journal/"))
      assert [%{id: "journal/2026-07-09.md"}] = listed(index, %{domain: "journal"}).notes
    end

    test "within one domain, and by type", %{index: index} do
      assert Enum.map(listed(index, %{domain: "bike"}).notes, & &1.id) |> Enum.sort() ==
               ["bike/terra-speed.md", "bike/via-carolina.md"]

      assert listed(index, %{domain: "nowhere"}).notes == []

      assert Enum.all?(listed(index, %{type: :decision}).notes, &(&1.type == :decision))
    end

    test "sorted by most recently updated, then by path" do
      index =
        Index.build([
          dated("a/old.md", "# Zebra", 1),
          dated("a/new.md", "# Apple", 20),
          dated("b/tie-2.md", "# Mango", 10),
          dated("b/tie-1.md", "# mango", 10)
        ])

      assert Enum.map(listed(index, %{}).notes, & &1.id) ==
               ["a/new.md", "b/tie-1.md", "b/tie-2.md", "a/old.md"]
    end

    test "sorted by title, folded, then by path" do
      index =
        Index.build([
          dated("a/z.md", "# zebra", 1),
          dated("a/a.md", "# Äpfel", 2),
          dated("a/b.md", "# Banana", 3),
          dated("b/b.md", "# banana", 4)
        ])

      assert Enum.map(listed(index, %{sort: :title}).notes, & &1.title) ==
               ["Äpfel", "Banana", "banana", "zebra"]
    end
  end

  describe "paging" do
    defp many(count) do
      for n <- 1..count do
        {:ok, file} =
          Parser.parse(
            "notes/n#{String.pad_leading("#{n}", 3, "0")}.md",
            "# Note #{n}\n\nPaging tomatoes.\n",
            @git_meta
          )

        file
      end
    end

    defp all_pages(fun, cursor \\ nil, acc \\ []) do
      {:ok, page} = fun.(cursor)
      items = Map.get(page, :notes) || Map.get(page, :results)

      case page.next_cursor do
        nil -> acc ++ items
        next -> all_pages(fun, next, acc ++ items)
      end
    end

    test "list pages cover every note once, in the order of one long page" do
      index = Index.build(many(23))
      params = %{sort: :title, limit: 5}

      pages = all_pages(&Index.list(index, Map.put(params, :cursor, &1)))
      {:ok, whole} = Index.list(index, %{params | limit: 100})

      assert Enum.map(pages, & &1.id) == Enum.map(whole.notes, & &1.id)
      assert length(pages) == 23
    end

    test "search pages cover every hit once, in ranked order" do
      index = Index.build(many(12))
      params = %{query: "tomatoes", limit: 5}

      pages = all_pages(&Index.search(index, Map.put(params, :cursor, &1)))
      {:ok, whole} = Index.search(index, %{params | limit: 25})

      assert Enum.map(pages, & &1.id) == Enum.map(whole.results, & &1.id)
      assert length(pages) == 12
    end

    test "a page is the same every time it is asked for while nothing is written" do
      index = Index.build(many(12))
      {:ok, first} = Index.list(index, %{sort: :updated, limit: 5})
      params = %{sort: :updated, limit: 5, cursor: first.next_cursor}

      assert Index.list(index, params) == Index.list(index, params)
      assert Index.list(Index.build(many(12)), params) == Index.list(index, params)
    end

    test "a write that changes the answer refuses the cursor, one elsewhere does not" do
      index = Index.build(many(12))
      {:ok, first} = Index.list(index, %{domain: "notes", sort: :title, limit: 5})
      params = %{domain: "notes", sort: :title, limit: 5, cursor: first.next_cursor}

      {:ok, other} = Parser.parse("elsewhere/x.md", "# X\n", @git_meta)
      assert {:ok, _page} = Index.list(Index.put(index, other), params)

      {:ok, added} = Parser.parse("notes/n000.md", "# Note 0\n", @git_meta)
      assert {:error, message} = Index.list(Index.put(index, added), params)
      assert message =~ "no longer matches"
      assert message =~ "without a cursor"
    end

    test "a cursor from other parameters is refused" do
      index = Index.build(many(12))
      {:ok, first} = Index.list(index, %{sort: :title, limit: 5})

      assert {:error, message} =
               Index.list(index, %{sort: :updated, limit: 5, cursor: first.next_cursor})

      assert message =~ "no longer matches"

      assert {:error, _} =
               Index.search(index, %{query: "tomatoes", limit: 5, cursor: first.next_cursor})
    end

    test "a cursor that is not one is refused" do
      index = Index.build(many(3))

      for cursor <- ["", "nonsense!", Base.url_encode64("x.y", padding: false)] do
        assert {:error, "Invalid cursor" <> _} =
                 Index.list(index, %{sort: :title, limit: 5, cursor: cursor})
      end
    end
  end

  describe "caps" do
    test "lint lists at most 50 findings per category and says it cut them" do
      body = Enum.map_join(1..60, " ", &"[[missing-#{&1}]]")
      {:ok, file} = Parser.parse("bike/broken.md", "# Broken\n\n#{body}\n", @git_meta)
      report = Index.lint(Index.build([file]), %{now: ~U[2026-01-01 10:00:00Z]})

      assert length(report.orphaned_links) == 50
      assert report.orphaned_links == Enum.take(Enum.sort(report.orphaned_links), 50)
      assert report.totals.orphaned_links == 60
      assert report.truncated == true
    end

    test "lint says truncated: false when nothing was cut", %{index: index} do
      report = Index.lint(index, %{now: ~U[2026-01-01 10:00:00Z]})

      assert report.truncated == false
      assert report.totals.orphaned_links == length(report.orphaned_links)
    end

    test "links at depth 2 describes at most 25 neighbours and says it cut them" do
      hub_body = Enum.map_join(1..30, " ", &"[[spoke-#{String.pad_leading("#{&1}", 2, "0")}]]")
      {:ok, hub} = Parser.parse("hub/hub.md", "# Hub\n\n#{hub_body}\n", @git_meta)

      spokes =
        for n <- 1..30 do
          name = "spoke-#{String.pad_leading("#{n}", 2, "0")}"
          {:ok, file} = Parser.parse("hub/#{name}.md", "# #{name}\n", @git_meta)
          file
        end

      index = Index.build([hub | spokes])
      {:ok, deep} = Index.links(index, %{id: "hub/hub.md", direction: :both, depth: 2})

      assert map_size(deep.neighbors) == 25
      assert Map.keys(deep.neighbors) |> Enum.sort() |> List.last() == "hub/spoke-25.md"
      assert deep.truncated == true

      {:ok, shallow} = Index.links(index, %{id: "hub/spoke-01.md", direction: :both, depth: 2})
      assert shallow.truncated == false

      refute Map.has_key?(
               elem(Index.links(index, %{id: "hub/hub.md", direction: :both, depth: 1}), 1),
               :truncated
             )
    end
  end
end
