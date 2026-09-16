defmodule Vigil.Vault.UniqueChunkIdTest do
  @moduledoc """
  "A chunk id is unique within its note" — asserted where it stops being a
  parser detail.

  `Vigil.Index` holds chunks by id, so two chunks of one note under one id are
  one chunk to every reader: the other is on disk and in no search, no `read`
  and no link. `## Setup`, `## Setup`, `## Setup 2` was enough, and the
  instability hid itself — `lint` groups over the index's chunks and found no
  duplicate there, while `mix vigil.vault_check`, grouping over the parsed
  chunks, found one. This file holds the note that did it against the index,
  the note `read` and the two hygiene readers at once.
  """
  use ExUnit.Case, async: true

  alias Vigil.{Index, Parser, VaultCheck}

  @path "gear/setup.md"

  @content """
  ---
  type: reference
  ---
  # Setup

  ## Setup
  first

  ## Setup
  second

  ## Setup 2
  third
  """

  setup do
    vault =
      Path.join(System.tmp_dir!(), "vigil_unique_chunk_id_#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(vault, "gear"))
    File.write!(Path.join(vault, @path), @content)
    on_exit(fn -> File.rm_rf!(vault) end)

    {:ok, file} = Parser.parse(@path, @content, %{})

    %{vault: vault, parsed: file, index: Index.build([file])}
  end

  test "every chunk the parse produces is a chunk the index holds", %{parsed: file, index: index} do
    assert Index.size(index).chunks == length(file.chunks)
    assert Index.count_headings(index, @path) == 3
  end

  test "every id in the note's table of contents reads as its own section", %{index: index} do
    {:ok, note} = Index.read(index, %{id: @path, backlinks: false})

    assert Enum.map(note.toc, & &1.heading) == ["Setup", "Setup", "Setup 2"]
    assert note.toc |> Enum.map(& &1.id) |> Enum.uniq() |> length() == 3

    sections =
      for entry <- note.toc do
        {:ok, section} = Index.read(index, %{id: entry.id, backlinks: false})
        assert {section.id, section.heading} == {entry.id, entry.heading}
        section.body
      end

    assert sections == ["first", "second", "third"]
  end

  test "lint and the doctor report the same duplicate headings", %{vault: vault, index: index} do
    linted =
      index
      |> Index.lint(%{now: ~U[2026-01-01 10:00:00Z]})
      |> Map.fetch!(:duplicate_headings)
      |> Enum.map(fn finding -> {finding.path, finding.slug, length(finding.ids)} end)

    doctored =
      vault
      |> VaultCheck.run()
      |> Map.fetch!(:b6_consolidation)
      |> Enum.flat_map(fn finding ->
        Enum.map(finding.duplicate_headings, fn duplicate ->
          {finding.path, Parser.slug(duplicate.heading), duplicate.count}
        end)
      end)

    assert linted == [{@path, "setup", 2}]
    assert doctored == linted
  end
end
