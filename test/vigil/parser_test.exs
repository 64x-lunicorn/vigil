defmodule Vigil.ParserTest do
  use ExUnit.Case, async: true

  alias Vigil.Parser

  @fixtures Path.expand("../fixtures/vault", __DIR__)

  defp parse(rel_path) do
    content = File.read!(Path.join(@fixtures, rel_path))
    {:ok, file} = Parser.parse(rel_path, content, %{})
    file
  end

  test "slug/1 transliterates umlauts and sharp s" do
    assert Parser.slug("Heat Pump Größe") == "heat-pump-groesse"
    assert Parser.slug("Grüße-und-Straße") == "gruesse-und-strasse"
  end

  test "terra-speed.md parses without crash and has expected chunks" do
    file = parse("bike/terra-speed.md")
    assert file.type == :reference
    assert file.title == "WTB Terra Speed 40C"

    ids = Enum.map(file.chunks, & &1.id)
    assert ids == ["bike/terra-speed.md#dimensions", "bike/terra-speed.md#gravel-experience"]
  end

  test "via-carolina.md: H1 creates no chunk, pre-H2 text becomes fragmentless chunk, ### is its own chunk" do
    file = parse("bike/via-carolina.md")
    assert file.type == :event
    assert file.title == "Via Carolina"

    ids = Enum.map(file.chunks, & &1.id)

    assert ids == [
             "bike/via-carolina.md",
             "bike/via-carolina.md#fueling",
             "bike/via-carolina.md#second-half",
             "bike/via-carolina.md#gear"
           ]

    second_half = Enum.find(file.chunks, &(&1.id == "bike/via-carolina.md#second-half"))
    assert second_half.heading_path == ["Fueling", "Second Half"]

    fueling = Enum.find(file.chunks, &(&1.id == "bike/via-carolina.md#fueling"))
    refute String.contains?(fueling.body, "caffeine")

    pre = Enum.find(file.chunks, &(&1.id == "bike/via-carolina.md"))
    assert pre.heading_path == []
    assert %{raw: "terra-speed", fragment: nil} in pre.links
  end

  test "file without any heading yields a single fragmentless chunk (ID = path)" do
    file = parse("training/note-without-anything.md")
    assert length(file.chunks) == 1
    [chunk] = file.chunks
    assert chunk.id == "training/note-without-anything.md"
    assert chunk.heading_path == []
    assert %{raw: "via-carolina", fragment: nil} in chunk.links
    assert file.type == :reference
  end

  test "unknown frontmatter field is tolerated; diacritics in path and heading are transliterated" do
    file = parse("home/diacritics-äöü-café.md")
    assert file.type == :reference

    # The path keeps its non-ASCII characters verbatim; only the heading part
    # of the chunk id is slugified.
    assert Enum.any?(
             file.chunks,
             &(&1.id == "home/diacritics-äöü-café.md#heat-pump-groesse")
           )
  end

  test "wikilinks with display text extract only the target part" do
    file = parse("bike/via-carolina.md")
    pre = Enum.find(file.chunks, &(&1.id == "bike/via-carolina.md"))
    assert pre.links == [%{raw: "terra-speed", fragment: nil}]
  end

  test "duplicate headings within a file get -2, -3 suffixes" do
    content = """
    ---
    type: reference
    ---
    # Duplicated

    ## Repetition
    first

    ## Repetition
    second

    ## Repetition
    third
    """

    {:ok, file} = Parser.parse("x/duplicated.md", content, %{})
    ids = Enum.map(file.chunks, & &1.id)

    assert ids == [
             "x/duplicated.md#repetition",
             "x/duplicated.md#repetition-2",
             "x/duplicated.md#repetition-3"
           ]
  end

  test "defensive parsing: missing frontmatter, unparsable YAML, invalid type never crash" do
    assert {:ok, %{type: :reference}} = Parser.parse("x/no-fm.md", "no frontmatter here", %{})

    assert {:ok, %{type: :reference}} =
             Parser.parse("x/bad-yaml.md", "---\n:::not yaml:::\n---\n# T\ntext", %{})

    assert {:ok, %{type: :reference}} =
             Parser.parse("x/bad-type.md", "---\ntype: nonsense\n---\n# T\ntext", %{})
  end

  test "event without offset on starts/ends is treated as reference" do
    content = """
    ---
    type: event
    starts: 2026-07-10T17:00:00
    ends: 2026-07-12T20:00:00
    ---
    # E
    text
    """

    {:ok, file} = Parser.parse("x/e.md", content, %{})
    assert file.type == :reference
  end

  describe "extract_links/1" do
    test "links inside fenced code blocks and inline code are not extracted" do
      body = """
      See [[painpoints]] for details.
      ```
      [[fake-link]] inside a code block
      ```
      Inline `[[also-fake]]` code.
      Real [[second-real]] link.
      """

      assert Parser.extract_links(body) == [
               %{raw: "painpoints", fragment: nil},
               %{raw: "second-real", fragment: nil}
             ]
    end

    test "wikilink with a #fragment splits target and fragment" do
      assert Parser.extract_links("See [[painpoints#deploy-error]].") == [
               %{raw: "painpoints", fragment: "deploy-error"}
             ]
    end

    test "markdown link to a .md file is extracted, non-.md targets are not" do
      body = "[Error](painpoints.md) and [X](domain/note.md#chunk-slug) and [img](pic.png)"

      assert Parser.extract_links(body) == [
               %{raw: "painpoints", fragment: nil},
               %{raw: "domain/note", fragment: "chunk-slug"}
             ]
    end

    test "duplicate raw links (same target and fragment) are deduplicated" do
      body = "[[painpoints]] and again [[painpoints]] and [text](painpoints.md)"
      assert Parser.extract_links(body) == [%{raw: "painpoints", fragment: nil}]
    end
  end
end
