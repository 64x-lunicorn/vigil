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
  each link syntax including one that does not resolve. **Nothing in that
  directory may be edited.** A failure here is not a broken test; it says that
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

  # Named here so the frozen vault cannot quietly shrink: deleting a note would
  # otherwise just mean fewer things are checked, which is the failure mode a
  # compatibility fixture is least able to notice about itself.
  @frozen_notes [
    "admin/bank-account.md",
    "admin/insurance.md",
    "home/heizung-öl-café.md",
    "journal/2026-01-15.md",
    "training/altitude-week.md",
    "training/no-frontmatter.md",
    "training/winter-camp.md"
  ]

  test "the frozen vault still holds exactly the notes it was frozen with" do
    on_disk =
      @vault
      |> Path.join("**/*.md")
      |> Path.wildcard()
      |> Enum.map(&Path.relative_to(&1, @vault))
      |> Enum.sort()

    assert on_disk == @frozen_notes
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
               "admin/insurance.md#household"
             ]

      assert Enum.map(file.chunks, & &1.heading) == ["Liability", "Household"]
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

      assert Enum.map(result.incoming, & &1.source) == ["admin/insurance.md#liability"]
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
