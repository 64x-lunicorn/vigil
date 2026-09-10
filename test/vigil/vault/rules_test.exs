defmodule Vigil.Vault.RulesTest do
  use ExUnit.Case, async: true

  alias Vigil.{Parser, Vault.Rules}

  defp chunks(content) do
    {:ok, file} = Parser.parse("bike/x.md", content)
    file.chunks
  end

  describe "sentence_heading?/1" do
    test "a heading longer than the threshold reads as a sentence" do
      refute Rules.sentence_heading?(String.duplicate("a", 60))
      assert Rules.sentence_heading?(String.duplicate("a", 61))
    end

    test "trailing sentence punctuation reads as a sentence at any length" do
      assert Rules.sentence_heading?("Why.")
      assert Rules.sentence_heading?("Why!")
      assert Rules.sentence_heading?("Why?")
      refute Rules.sentence_heading?("Why")
    end
  end

  describe "note_length/1 and overlong?/1" do
    defp note_of(heading_count, words_per_body) do
      body = String.duplicate("wort ", words_per_body)
      sections = for n <- 1..heading_count, do: "## Section #{n}\n#{body}"
      chunks("# T\n\n" <> Enum.join(sections, "\n\n"))
    end

    test "a note is clean at both thresholds and overlong one past either" do
      at_headings = note_of(30, 1)
      assert Rules.note_length(at_headings).headings == 30
      refute Rules.note_length(at_headings).over_heading_threshold
      refute Rules.overlong?(Rules.note_length(at_headings))

      past_headings = note_of(31, 1)
      assert Rules.note_length(past_headings).headings == 31
      assert Rules.note_length(past_headings).over_heading_threshold
      assert Rules.overlong?(Rules.note_length(past_headings))
    end

    test "the word threshold is the other axis, and is crossed on its own" do
      at_words = note_of(1, 2000)
      assert Rules.note_length(at_words).words == 2000
      refute Rules.note_length(at_words).over_word_threshold
      refute Rules.overlong?(Rules.note_length(at_words))

      past_words = note_of(1, 2001)
      assert Rules.note_length(past_words).words == 2001
      assert Rules.note_length(past_words).over_word_threshold
      refute Rules.note_length(past_words).over_heading_threshold
      assert Rules.overlong?(Rules.note_length(past_words))
    end

    test "an empty note measures zero on both axes" do
      assert Rules.note_length([]) == %{
               headings: 0,
               words: 0,
               over_heading_threshold: false,
               over_word_threshold: false
             }
    end
  end

  describe "duplicate_headings/1" do
    # The case lint used to miss: grouped by heading chain, `## A / ### B` and
    # `## C / ### B` looked distinct — but the parser's uniquifier keys on the
    # heading text's slug, so they are exactly the pair whose chunk ids moved.
    test "same heading text under different chains is one collision" do
      chunks = chunks("# T\n\n## A\n\n### B\nOne.\n\n## C\n\n### B\nTwo.\n")

      assert [%{slug: "b", chunks: [first, second]}] = Rules.duplicate_headings(chunks)
      assert first.id == "bike/x.md#b"
      assert second.id == "bike/x.md#b-2"
      assert first.heading_path != second.heading_path
    end

    test "headings that differ in text but share a slug collide" do
      chunks = chunks("# T\n\n## Café\nOne.\n\n## cafe\nTwo.\n")

      assert [%{slug: "cafe", chunks: [first, second]}] = Rules.duplicate_headings(chunks)
      assert first.heading == "Café"
      assert second.heading == "cafe"
    end

    test "distinct headings do not collide, and the pre-heading chunk is not one" do
      assert Rules.duplicate_headings(chunks("# T\n\nIntro.\n\n## A\nOne.\n\n## B\nTwo.\n")) ==
               []
    end

    test "three of a kind is one entry carrying all three chunks" do
      chunks = chunks("# T\n\n## A\n1.\n\n## A\n2.\n\n## A\n3.\n")

      assert [%{slug: "a", chunks: group}] = Rules.duplicate_headings(chunks)
      assert Enum.map(group, & &1.id) == ["bike/x.md#a", "bike/x.md#a-2", "bike/x.md#a-3"]
    end

    test "entries come back in slug order" do
      chunks = chunks("# T\n\n## Zed\n1.\n\n## Zed\n2.\n\n## Alpha\n3.\n\n## Alpha\n4.\n")

      assert ["alpha", "zed"] = Enum.map(Rules.duplicate_headings(chunks), & &1.slug)
    end
  end

  describe "heading_slug_changes/1" do
    test "reports every H2-H4 heading whose slug would change" do
      content = "# Title\n## Café Overview\n## already-clean\n"

      assert [%{text: "Café Overview", old: old, new: new}] = Rules.heading_slug_changes(content)
      assert old != new
      assert new == "cafe-overview"
    end

    test "H1 is not a heading and never appears in the diff" do
      assert Rules.heading_slug_changes("# Café Title\n\nbody\n") == []
    end

    test "a heading with no derivable slug reports new: nil" do
      assert [%{text: "———", new: nil}] = Rules.heading_slug_changes("## ———\n")
    end
  end

  describe "filename_slug_change/1" do
    test "a basename whose slug moves reports both slugs" do
      assert Rules.filename_slug_change("bike/café.md") == %{old: "caf", new: "cafe"}
    end

    test "a canonical basename reports no change" do
      assert Rules.filename_slug_change("bike/terra-speed.md") == nil
    end

    test "a basename from which no slug can be derived reports new: nil" do
      assert %{new: nil} = Rules.filename_slug_change("bike/———.md")
    end

    test "only the basename is compared, not the directories" do
      assert Rules.filename_slug_change("Bike Stuff/terra-speed.md") == nil
    end
  end
end
