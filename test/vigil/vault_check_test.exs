defmodule Vigil.VaultCheckTest do
  use ExUnit.Case, async: true

  alias Vigil.VaultCheck

  setup do
    tmp = Path.join(System.tmp_dir!(), "vigil_vault_check_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(tmp, "domaina"))
    File.mkdir_p!(Path.join(tmp, "domainb"))

    File.write!(Path.join(tmp, "_domains.yml"), """
    domaina: "Test domain A"
    domainc: "Configured, but no directory"
    """)

    write = fn rel, content -> File.write!(Path.join(tmp, rel), content) end

    write.("domaina/no-frontmatter.md", "# Without Frontmatter\ntext\n")

    write.("domaina/type-missing.md", """
    ---
    description: x
    ---
    # Type Missing
    text
    """)

    write.("domaina/type-unknown.md", """
    ---
    type: foo
    ---
    # Unknown Type
    text
    """)

    write.("domaina/event-without-starts.md", """
    ---
    type: event
    ---
    # Event Without Starts
    text
    """)

    write.("domaina/non-event-with-starts.md", """
    ---
    type: reference
    starts: 2026-01-01T00:00:00+01:00
    ---
    # Reference With Starts
    text
    """)

    write.("domaina/ends-before-starts.md", """
    ---
    type: event
    starts: 2026-06-02T10:00:00+01:00
    ends: 2026-06-01T10:00:00+01:00
    ---
    # Ends Before Starts
    text
    """)

    padding = String.duplicate("x", 1100)

    write.("domaina/large-frontmatter.md", """
    ---
    type: reference
    padding: "#{padding}"
    ---
    # Large Frontmatter
    text
    """)

    write.("domaina/File With Spaces.md", """
    ---
    type: reference
    ---
    # File With Spaces
    text
    """)

    long_basis = String.duplicate("a", 65)

    write.("domaina/#{long_basis}.md", """
    ---
    type: reference
    ---
    # Long Basename
    text
    """)

    write.("domaina/collision_a.md", """
    ---
    type: reference
    ---
    # Collision A
    text
    """)

    write.("domaina/collision-a.md", """
    ---
    type: reference
    ---
    # Collision B
    text
    """)

    many_headings =
      for n <- 1..35, do: "## Section #{n}\nshort.\n"

    write.(
      "domaina/many-headings.md",
      "---\ntype: reference\n---\n# Many Headings\n\n" <>
        Enum.join(many_headings, "\n")
    )

    many_words = String.duplicate("word ", 2100)

    write.("domaina/many-words.md", """
    ---
    type: reference
    ---
    # Many Words

    ## Text
    #{many_words}
    """)

    write.("domaina/duplicate-heading.md", """
    ---
    type: reference
    ---
    # Duplicate Heading

    ## Same
    One.

    ## Same
    Two.
    """)

    write.("domaina/sentence-heading.md", """
    ---
    type: reference
    ---
    # Sentence Heading

    ## This is a whole sentence.
    Text.
    """)

    # One heading of three has lost the blank line above it — the shape a
    # replace_section write left behind before the chunk boundary was fixed.
    write.("domaina/missing-separator.md", """
    ---
    type: reference
    ---
    # Missing Separator

    ## First
    Text.
    ## Second
    More text.

    ## Third
    Fine.
    """)

    # The H1 sits directly under the frontmatter, with no blank line above it.
    # The title creates no chunk and is never checked; its sections are intact.
    write.("domaina/h1-without-separator.md", """
    ---
    type: reference
    ---
    # H1 Without Separator

    ## Section
    Text.

    ## Another
    More.
    """)

    # A title and nothing else: one heading, so nothing to separate.
    write.("domaina/single-heading.md", """
    ---
    type: reference
    ---
    # Single Heading
    Text without any section.
    """)

    # Title plus one section — two headings, so the gate opens and the missing
    # blank line above the section is reported.
    write.("domaina/one-section-no-separator.md", """
    ---
    type: reference
    ---
    # One Section
    Intro.
    ## Only Section
    Text.
    """)

    # A section opening directly under the title, with no prose between them.
    # Nothing precedes it but the H1, which creates no chunk — so the check has
    # nothing to measure against and stays quiet.
    write.("domaina/heading-under-title.md", """
    ---
    type: reference
    ---
    # Heading Under Title
    ## First
    Text.

    ## Second
    More.
    """)

    on_exit(fn -> File.rm_rf!(tmp) end)

    %{vault: tmp}
  end

  test "overview counts domains/notes/chunks", %{vault: vault} do
    report = VaultCheck.run(vault)

    assert report.overview.domains == 2
    assert "domaina" in report.overview.domain_names
    assert "domainb" in report.overview.domain_names
    assert report.overview.notes == 20
  end

  test "B1: missing frontmatter, missing/unknown type, event rules, oversized frontmatter", %{
    vault: vault
  } do
    findings = VaultCheck.run(vault).b1_frontmatter

    messages_for = fn path ->
      findings |> Enum.filter(&(&1.path == path)) |> Enum.map(& &1.message)
    end

    assert ["no frontmatter — treated as reference"] =
             messages_for.("domaina/no-frontmatter.md")

    assert ["field 'type' is missing"] = messages_for.("domaina/type-missing.md")

    assert ["unknown type 'foo' (allowed: reference, decision, event)"] =
             messages_for.("domaina/type-unknown.md")

    assert ["event without starts — will never be picked up by current"] =
             messages_for.("domaina/event-without-starts.md")

    assert ["starts/ends have no effect on type 'reference'"] =
             messages_for.("domaina/non-event-with-starts.md")

    assert ["ends is before starts"] = messages_for.("domaina/ends-before-starts.md")
    assert ["frontmatter exceeds 1 KB"] = messages_for.("domaina/large-frontmatter.md")
  end

  test "B2: non-canonical filenames, long basenames, collision suspects", %{vault: vault} do
    findings = VaultCheck.run(vault).b2_filenames

    non_canonical = Enum.find(findings, &(&1[:path] == "domaina/File With Spaces.md"))
    assert non_canonical.normalized == "domaina/file-with-spaces.md"

    long_basis_path = "domaina/#{String.duplicate("a", 65)}.md"

    assert Enum.any?(
             findings,
             &(Map.get(&1, :path) == long_basis_path and &1.message =~ "60 characters")
           )

    collision =
      Enum.find(findings, fn f ->
        Map.has_key?(f, :paths) and f.normalized == "domaina/collision-a.md"
      end)

    assert collision != nil
    assert "domaina/collision_a.md" in collision.paths
    assert "domaina/collision-a.md" in collision.paths
  end

  test "B3: chunk-id diff is empty except for the deliberately underscored collision fixture", %{
    vault: vault
  } do
    diff = VaultCheck.run(vault).b3_chunk_diff
    assert diff.checked == 20

    assert [
             %{
               kind: "file",
               path: "domaina/collision_a.md",
               old: "collisiona",
               new: "collision-a"
             }
           ] =
             diff.changes
  end

  test "B3: flags a diff when legacy and new slug logic disagree", %{vault: vault} do
    File.write!(Path.join(vault, "domaina/café.md"), """
    ---
    type: reference
    ---
    # café
    text
    """)

    diff = VaultCheck.run(vault).b3_chunk_diff
    assert Enum.any?(diff.changes, &(&1.kind == "file" and &1.path == "domaina/café.md"))
  end

  test "B4: domain drift in both directions", %{vault: vault} do
    findings = VaultCheck.run(vault).b4_domain_drift
    messages = Enum.map(findings, & &1.message)

    assert Enum.any?(
             messages,
             &(&1 =~ "'domainb' exists in the vault but is unknown to the runtime")
           )

    assert Enum.any?(
             messages,
             &(&1 =~ "'domainc' is configured but does not exist in the vault")
           )

    refute Enum.any?(messages, &String.contains?(&1, "'domaina'"))
  end

  test "B6: heading threshold, word threshold, duplicate headings, sentence headings", %{
    vault: vault
  } do
    findings = VaultCheck.run(vault).b6_consolidation
    by_path = Map.new(findings, &{&1.path, &1})

    assert by_path["domaina/many-headings.md"].over_heading_threshold
    assert by_path["domaina/many-headings.md"].headings == 35

    assert by_path["domaina/many-words.md"].over_word_threshold

    assert [%{heading: "Same", count: 2}] =
             by_path["domaina/duplicate-heading.md"].duplicate_headings

    assert "This is a whole sentence." in by_path["domaina/sentence-heading.md"].sentence_headings

    refute Map.has_key?(by_path, "domaina/no-frontmatter.md")
  end

  test "B5: one finding per heading that lost the blank line above it", %{vault: vault} do
    findings = VaultCheck.run(vault).b5_separators

    assert [%{path: "domaina/missing-separator.md", heading: "Second", message: message}] =
             Enum.filter(findings, &(&1.path == "domaina/missing-separator.md"))

    assert message =~ "Second"
    assert message =~ "blank line"
  end

  test "B5: the H1 title is never checked, and one heading is never reported", %{vault: vault} do
    paths = VaultCheck.run(vault).b5_separators |> Enum.map(& &1.path)

    refute "domaina/h1-without-separator.md" in paths
    refute "domaina/single-heading.md" in paths
  end

  test "B5: a title plus one section is two headings, so the section is checked", %{vault: vault} do
    findings = VaultCheck.run(vault).b5_separators

    assert %{heading: "Only Section"} =
             Enum.find(findings, &(&1.path == "domaina/one-section-no-separator.md"))
  end

  test "B5: a heading directly under the title has no chunk before it", %{vault: vault} do
    paths = VaultCheck.run(vault).b5_separators |> Enum.map(& &1.path)

    refute "domaina/heading-under-title.md" in paths
  end

  test "B5: notes whose separators are all in place produce nothing", %{vault: vault} do
    paths = VaultCheck.run(vault).b5_separators |> Enum.map(& &1.path) |> Enum.uniq()

    assert Enum.sort(paths) == [
             "domaina/missing-separator.md",
             "domaina/one-section-no-separator.md"
           ]
  end
end
