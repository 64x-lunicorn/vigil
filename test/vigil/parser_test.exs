defmodule Vigil.ParserTest do
  use ExUnit.Case, async: true

  alias Vigil.Parser
  alias Vigil.Parser.Chunk

  @fixtures Path.expand("../fixtures/vault", __DIR__)

  defp parse(rel_path) do
    content = File.read!(Path.join(@fixtures, rel_path))
    {:ok, file} = Parser.parse(rel_path, content, %{})
    file
  end

  # A chunk-shaped map: the same field names, and not a chunk. Built behind a
  # function so the type checker does not read the deliberate mismatch below
  # as unreachable code.
  defp chunk_shaped_map, do: Map.new(heading_line: 6, body_end_line: 7)

  # The note's pre-heading chunk: a body, and no heading line of its own.
  defp pre_chunk, do: struct(Chunk, body_end_line: 3)

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

  # The rule is Vigil.Vault.Frontmatter's; what the parser keeps is the
  # downgrade and the warning. So a `decision` carrying timestamps — which the
  # write gate refuses, and which the parser used to index as a decision with
  # the timestamps silently dropped — is a reference here too.
  test "a non-event carrying starts/ends is downgraded and says why" do
    content = """
    ---
    type: decision
    starts: 2026-07-10T17:00:00+02:00
    ends: 2026-07-12T20:00:00+02:00
    ---
    # D
    text
    """

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:ok, %{type: :reference, starts: nil, ends: nil}} =
                 Parser.parse("x/d.md", content, %{})
      end)

    assert log =~ "starts/ends on a note that is not an event"
    assert log =~ "treating as reference"
  end

  test "event with a starts and no ends is treated as reference" do
    content = """
    ---
    type: event
    starts: 2026-07-10T17:00:00+02:00
    ---
    # E
    text
    """

    {:ok, file} = Parser.parse("x/e.md", content, %{})
    assert file.type == :reference
  end

  test "event whose ends precedes its starts is treated as reference" do
    content = """
    ---
    type: event
    starts: 2026-07-12T20:00:00+02:00
    ends: 2026-07-10T17:00:00+02:00
    ---
    # E
    text
    """

    {:ok, file} = Parser.parse("x/e.md", content, %{})
    assert file.type == :reference
    assert file.starts == nil
    assert file.ends == nil
  end

  # A chunk ends at its last non-blank line. The blank lines between two
  # sections belong to neither — they are punctuation between chunks, so a
  # write that replaces a body cannot eat them (docs/design.md, "How a file is
  # written"). These assertions were written one commit earlier against the
  # old boundary, where the separator sat inside the preceding body; the
  # numbers below are the decision, not a patch.
  describe "chunk boundaries" do
    #  4  # Notes
    #  5
    #  6  Text before the first heading.
    #  7
    #  8  ## First
    #  9  First body.
    # 10
    # 11  ### Nested
    # 12  Nested body.
    # 13
    # 14  ## Last
    # 15  Last body.
    @boundaries """
    ---
    type: reference
    ---
    # Notes

    Text before the first heading.

    ## First
    First body.

    ### Nested
    Nested body.

    ## Last
    Last body.
    """

    defp boundary_chunk(id) do
      {:ok, file} = Parser.parse("x/boundaries.md", @boundaries, %{})
      Enum.find(file.chunks, &(&1.id == id))
    end

    test "a mid-file section ends at its last content line, not at the separator" do
      chunk = boundary_chunk("x/boundaries.md#first")

      assert chunk.body == "First body."
      assert chunk.body_end_line == 9
    end

    test "a ### sibling under a ## ends the same way" do
      chunk = boundary_chunk("x/boundaries.md#nested")

      assert chunk.body == "Nested body."
      assert chunk.body_end_line == 12
    end

    test "the last section runs to EOF, which carries no trailing blank" do
      chunk = boundary_chunk("x/boundaries.md#last")

      assert chunk.body == "Last body."
      assert chunk.body_end_line == 15
    end

    # The fragmentless chunk is built on its own code path, with its own
    # body-end computation — the rule has to be stated there too.
    test "the fragmentless pre-H2 chunk follows the same rule" do
      chunk = boundary_chunk("x/boundaries.md")

      assert chunk.body == "\nText before the first heading."
      assert chunk.body_end_line == 6
    end

    # The first H1 is consumed as the note title and joins no body, so in a
    # note whose H1 sits below its first ##, counting lines from the heading
    # lands one short of the body's real last line.
    test "an H1 inside a section is skipped without shifting the body's end line" do
      content = """
      ---
      type: reference
      ---
      ## First
      body one
      # Late Title
      body two

      ## Second
      Second body.
      """

      {:ok, file} = Parser.parse("x/late-title.md", content, %{})
      first = Enum.find(file.chunks, &(&1.id == "x/late-title.md#first"))

      assert first.body == "body one\nbody two"
      assert first.body_end_line == 7
    end

    test "a section whose body is nothing but blank lines ends on its own heading line" do
      content = """
      ---
      type: reference
      ---
      # Notes

      ## Empty


      ## Next
      Next body.
      """

      {:ok, file} = Parser.parse("x/empty-body.md", content, %{})
      empty = Enum.find(file.chunks, &(&1.id == "x/empty-body.md#empty"))

      assert empty.body == ""
      assert empty.body_end_line == empty.heading_line
    end
  end

  describe "fenced blocks" do
    test "a heading inside a fenced block opens no chunk and stays in the body of its own" do
      file = parse("projects/vigil/vigil-mcp-config.md")

      ids = Enum.map(file.chunks, & &1.id)

      assert ids == [
               "projects/vigil/vigil-mcp-config.md",
               "projects/vigil/vigil-mcp-config.md#client-snippet",
               "projects/vigil/vigil-mcp-config.md#troubleshooting"
             ]

      snippet =
        Enum.find(file.chunks, &(&1.id == "projects/vigil/vigil-mcp-config.md#client-snippet"))

      assert snippet.body =~ "## Fenced Example"
      assert snippet.body =~ "Everything past the closing delimiter is prose again."
      assert snippet.body_end_line == 18
    end

    test "a link inside a fenced block is no reference" do
      file = parse("projects/vigil/vigil-mcp-config.md")

      refute Enum.any?(file.chunks, fn chunk ->
               Enum.any?(chunk.links, &(&1.raw == "fenced-target"))
             end)
    end

    test "an H1 inside a fenced block is not the note's title" do
      {:ok, file} =
        Parser.parse("x/fenced.md", "# Real Title\n\n```\n# Not A Title\n```\n", %{})

      assert file.title == "Real Title"
      assert [%{id: "x/fenced.md"}] = file.chunks
    end

    test "a fence left unclosed swallows every heading below it" do
      {:ok, file} =
        Parser.parse("x/open.md", "# T\n\n## Real\n\n```\n## Never Closed\nmore\n", %{})

      assert Enum.map(file.chunks, & &1.id) == ["x/open.md#real"]
    end
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

    test "a tilde fence hides its links too, and an unclosed one hides the rest of the body" do
      tildes = "See [[real]].\n~~~\n[[tilde-fake]]\n~~~\nAnd [[also-real]].\n"

      assert Parser.extract_links(tildes) == [
               %{raw: "real", fragment: nil},
               %{raw: "also-real", fragment: nil}
             ]

      assert Parser.extract_links("See [[real]].\n```\n[[never-closed]]\n") == [
               %{raw: "real", fragment: nil}
             ]
    end

    test "duplicate raw links (same target and fragment) are deduplicated" do
      body = "[[painpoints]] and again [[painpoints]] and [text](painpoints.md)"
      assert Parser.extract_links(body) == [%{raw: "painpoints", fragment: nil}]
    end
  end

  # The line numbers a chunk carries are 1-based and inclusive; a caller that
  # slices or splices a line list needs them 0-based. The helpers own that
  # offset, and they own it for *this* struct: a chunk of another shape is a
  # mistake the compiler cannot catch on field names alone, so it fails here
  # rather than working by coincidence.
  describe "Chunk line indices" do
    test "0-based indices for the heading, the body's first line and the line after it" do
      [chunk] = parse("bike/terra-speed.md").chunks |> Enum.take(1)

      assert Chunk.heading_index(chunk) == chunk.heading_line - 1
      assert Chunk.body_start_index(chunk) == chunk.heading_line
      assert Chunk.body_end_index(chunk) == chunk.body_end_line
    end

    test "a chunk-shaped map is refused, however its fields are named" do
      shaped = chunk_shaped_map()

      assert_raise FunctionClauseError, fn -> Chunk.heading_index(shaped) end
      assert_raise FunctionClauseError, fn -> Chunk.body_start_index(shaped) end
      assert_raise FunctionClauseError, fn -> Chunk.body_end_index(shaped) end
    end

    test "a chunk with no heading line of its own has no heading index" do
      pre = pre_chunk()

      assert_raise FunctionClauseError, fn -> Chunk.heading_index(pre) end
      assert Chunk.body_end_index(pre) == 3
    end
  end
end
