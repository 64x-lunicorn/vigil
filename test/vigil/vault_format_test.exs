defmodule Vigil.VaultFormatTest do
  @moduledoc """
  The vault's on-disk format, frozen.

  `test/fixtures/vault/` is a *live* fixture: it grows a note whenever a
  feature needs one, and a test that reads it is testing today's code against
  today's fixture. That pairing cannot notice the one failure that matters
  here — the reader drifting away from files that are already on disk.

  Daniel's vault is years of notes written by earlier versions of this server,
  and vigil never migrates them: it re-reads them on every boot. So the format
  is a compatibility surface with every past version, and the only way to test
  it is against files that do not change when the code does.

  `test/fixtures/vault_frozen/` is that: a small vault covering the whole
  surface — the three frontmatter types, an event's timestamps, a note with no
  frontmatter at all, a non-ASCII filename, both `_domains.yml` spellings, and
  every link syntax the parser has a pattern for, including two that do not
  resolve. **Nothing in that directory may be edited**, and the digests below
  enforce it. A failure here is not a broken test; it says that
  a note already in the vault now parses differently than it did, and that
  needs a migration and a decision, not a fixture update.

  What it deliberately does not assert: search ranking, scoring, previews.
  Those are decisions about the *answer*, free to change. This is about what
  the bytes on disk mean.
  """
  use ExUnit.Case, async: true

  alias Vigil.{Index, Parser}
  alias Vigil.Vault.Domains

  @vault Path.expand("../fixtures/vault_frozen", __DIR__)

  defp parse!(relative) do
    content = File.read!(Path.join(@vault, relative))
    {:ok, file} = Parser.parse(relative, content)
    file
  end

  defp index do
    @vault
    |> Path.join("**/*.md")
    |> Path.wildcard()
    |> Enum.map(fn absolute ->
      relative = Path.relative_to(absolute, @vault)
      {:ok, file} = Parser.parse(relative, File.read!(absolute))
      file
    end)
    |> Index.build()
  end

  # The freeze, made mechanical. The file list alone was not enough: deleting a
  # note would have meant fewer things are checked, and rewriting one whose body
  # no assertion names would have gone unnoticed — the same self-blindness a
  # compatibility fixture is least able to see in itself.
  #
  # A failing digest here is not a stale expectation to update. It means
  # somebody edited a file that exists to stay exactly as it is.
  @frozen_notes [
    {"admin/bank-account.md", "a65019d4c3856cb4b102a0ce61c6e276bfb391384ad46d4f0aa8015eeb2c01c6"},
    {"admin/insurance.md", "f83e14fb0942f5afc8071b4bf685089348322ce542a6f0d403fa0e379feef9d4"},
    {"home/heizung-öl-café.md",
     "8da5594b39d2dd32cc74e99d2193e1feb5e8e1554e94cbe90487593c2443099a"},
    {"journal/2026-01-15.md", "519e82b17daf6efb6da976b788f58ef2db4f11e9e27c65901ce2519b5ca04ad9"},
    {"training/altitude-week.md",
     "3cfdec37b8ad00f025c4f76963fd51fd293666c9a70ec98dfe4859c00b746cc8"},
    {"training/no-frontmatter.md",
     "8af5218c00951cc30588f4aa5d3cb3e37b51c41b6d01ac61fac38c6e8f2da570"},
    {"training/winter-camp.md",
     "aabbaab96ee8ca9d8f901a5945ee38c384c019eb8455bd900ff98ca329944fc4"}
  ]

  test "the frozen vault still holds exactly the notes it was frozen with" do
    on_disk =
      @vault
      |> Path.join("**/*.md")
      |> Path.wildcard()
      |> Enum.map(&Path.relative_to(&1, @vault))
      |> Enum.sort()

    assert on_disk == Enum.map(@frozen_notes, &elem(&1, 0))
  end

  test "and every one of them byte for byte" do
    for {path, digest} <- @frozen_notes do
      actual =
        @vault
        |> Path.join(path)
        |> File.read!()
        |> then(&:crypto.hash(:sha256, &1))
        |> Base.encode16(case: :lower)

      assert {path, actual} == {path, digest}
    end
  end

  describe "frontmatter" do
    test "a reference note carries its type and no timestamps" do
      file = parse!("admin/insurance.md")

      assert file.type == :reference
      assert file.starts == nil
      assert file.ends == nil
      assert file.title == "Insurance"
    end

    test "a decision note carries its type" do
      assert parse!("admin/bank-account.md").type == :decision
    end

    test "an event note's timestamps parse to the instants the file names" do
      file = parse!("training/winter-camp.md")

      assert file.type == :event
      assert DateTime.to_iso8601(file.starts) == "2026-01-12T09:00:00Z"
      assert DateTime.to_iso8601(file.ends) == "2026-01-19T17:00:00Z"
    end

    test "an offset that is not UTC is preserved as the same instant" do
      file = parse!("training/altitude-week.md")

      assert file.type == :event
      # 2026-03-02T08:00:00+01:00 is 07:00 UTC.
      assert DateTime.to_iso8601(DateTime.shift_zone!(file.starts, "Etc/UTC")) ==
               "2026-03-02T07:00:00Z"
    end

    test "a note with no frontmatter is read as a reference rather than refused" do
      file = parse!("training/no-frontmatter.md")

      assert file.type == :reference
      assert file.title == "Threshold test"
    end
  end

  describe "chunking" do
    test "a note's chunks are its headings, addressed as path#heading-slug" do
      file = parse!("admin/insurance.md")

      assert Enum.map(file.chunks, & &1.id) == [
               "admin/insurance.md#liability",
               "admin/insurance.md#household",
               "admin/insurance.md#claims"
             ]

      assert Enum.map(file.chunks, & &1.heading) == ["Liability", "Household", "Claims"]
    end

    test "text before the first heading is the note's own chunk" do
      file = parse!("admin/bank-account.md")

      assert hd(file.chunks).id == "admin/bank-account.md"
      assert hd(file.chunks).heading == nil
    end

    test "a chunk inherits the note's type and timestamps" do
      [chunk | _] = parse!("training/winter-camp.md").chunks

      assert chunk.type == :event
      assert DateTime.to_iso8601(chunk.starts) == "2026-01-12T09:00:00Z"
    end
  end

  describe "filenames" do
    test "a non-ASCII filename is read, and addresses its chunks" do
      file = parse!("home/heizung-öl-café.md")

      assert file.title == "Heizung"
      assert hd(file.chunks).id == "home/heizung-öl-café.md#brenner"
    end
  end

  describe "links" do
    test "a [[wiki]] link resolves to the note it names" do
      {:ok, result} =
        Index.links(index(), %{id: "admin/insurance.md", direction: :out, depth: 1})

      assert %{target: "admin/bank-account.md", status: "ok"} =
               Enum.find(result.outgoing, &(&1.from_chunk == "admin/insurance.md#liability"))
    end

    test "a [text](path.md) link that names no note stays broken rather than resolving" do
      {:ok, result} =
        Index.links(index(), %{id: "admin/insurance.md", direction: :out, depth: 1})

      assert %{target: "admin/nonexistent-note", status: "broken"} =
               Enum.find(result.outgoing, &(&1.from_chunk == "admin/insurance.md#household"))
    end

    test "a link is visible from the note it points at" do
      {:ok, result} =
        Index.links(index(), %{id: "admin/bank-account.md", direction: :in, depth: 1})

      assert Enum.map(result.incoming, & &1.source) == [
               "admin/insurance.md#liability",
               "admin/insurance.md#claims"
             ]
    end
  end

  describe "link syntax" do
    # The four remaining forms, all in admin/insurance.md#claims: a wiki link
    # with a fragment, one with an alias, a markdown link with a fragment, and
    # a fragment that names no heading. Each has its own group in the parser's
    # patterns, and a regression in any of them would otherwise go unseen.
    setup do
      {:ok, result} =
        Index.links(index(), %{id: "admin/insurance.md#claims", direction: :out, depth: 1})

      %{targets: result.outgoing |> Enum.map(&{&1.target, &1.status}) |> Enum.sort()}
    end

    test "[[note#Heading]] resolves to the chunk, not merely the note", %{targets: targets} do
      assert {"admin/bank-account.md#standing-orders", "ok"} in targets
    end

    test "[text](note.md#heading) resolves to the same chunk", %{targets: targets} do
      # Both spellings of the same link are present, so it appears twice.
      assert Enum.count(targets, &(&1 == {"admin/bank-account.md#standing-orders", "ok"})) == 2
    end

    test "[[note|alias]] resolves to the note, and the alias is not the target", %{
      targets: targets
    } do
      assert {"admin/bank-account.md", "ok"} in targets
      refute Enum.any?(targets, fn {target, _} -> target =~ "the account note" end)
    end

    test "a fragment naming no heading is broken, and says which fragment", %{targets: targets} do
      # The fragment is in the label on purpose: without it the finding reads
      # as "note missing" when only the section is.
      assert {"bank-account#No such heading", "broken"} in targets
    end
  end

  describe "_domains.yml" do
    # The file's text is handed to the client verbatim and only `naming` is
    # interpreted, so that is the whole of what a format test can pin: a
    # domain with a bare description parses to no rule, and the expanded form
    # parses to the rule it spells out.
    test "a bare description carries no naming rule, the expanded form carries one" do
      {naming, warnings} =
        @vault |> Path.join("_domains.yml") |> File.read!() |> Domains.parse()

      assert warnings == []
      assert Map.keys(naming) |> Enum.sort() == ["admin", "home", "journal", "training"]
      assert naming["admin"] == nil

      assert %Domains.Naming{scope: :filename, suggestion: :date} = naming["journal"]
      assert Regex.source(naming["journal"].pattern) == "^\\d{4}-\\d{2}-\\d{2}\\.md$"
      assert naming["journal"].hint == "Journal notes are named YYYY-MM-DD.md"
    end
  end
end
