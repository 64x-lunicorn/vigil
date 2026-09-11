defmodule Vigil.Vault.SectionIdParityTest do
  @moduledoc """
  "An id that reads is an id that writes" — asserted rather than documented.

  `Vigil.Index.find_chunk/2` claims it in its own docstring, and until the
  resolution owned the path check the claim rested on two modules agreeing:
  `read/2` checked that the id's path part was safe to resolve and
  `find_chunk/2` did not, so the check was re-done in `Vigil.Vault.Policy`,
  in another module, with a normalization step of its own and a comment
  explaining which had to come first. Both go through
  `Vigil.Slug.canonical_path/1` now, and this file is what says so.

  One table, four surfaces, one row per id shape. The two readers and the two
  writers are written out per row rather than derived from one another,
  because the rows where they *must* differ are the point as much as the ones
  where they must not: the write gate judges what may be written before it
  resolves what is there, so an id naming `skills/` or an excluded domain
  answers "Invalid path" where a reader answers "Not found" — a refusal must
  not confirm that a path it will not touch exists. Everywhere else the four
  agree, and that is the claim.
  """
  use ExUnit.Case, async: true

  alias Vigil.{Index, Parser}
  alias Vigil.Vault.{AbsentFacts, Layout, Policy}

  @fixtures Path.expand("../../fixtures/vault", __DIR__)

  # One excluded domain, so the vault the index holds and the vault the gate
  # judges against are the same vault — which is what makes a difference
  # between them a difference in the decision rather than in the data.
  @exclude ["work"]

  @git_meta %{
    created_at: ~U[2026-01-01 10:00:00Z],
    updated_at: ~U[2026-01-01 10:00:00Z],
    last_author: "Daniel"
  }

  # `read` and `links` answer about the id; `replace_section` and
  # `delete_section` answer about the write. Four verdicts cover both:
  # `:resolved` reached a record, `:not_found` and `:invalid_path` are the two
  # refusals the readers already keep apart, and `:no_fragment` is the write
  # gate's own — a bare path names a note, which is not a section to replace
  # or delete.
  #
  # {description, id, what the readers answer, what the write gate answers}
  @shapes [
    {"a safe id naming a section that is there", "bike/via-carolina.md#gear", :resolved,
     :resolved},
    {"the same section under a path that normalizes to it", "Bike/Via Carolina.md#gear",
     :resolved, :resolved},
    {"a note whose stored filename carries diacritics",
     "home/diacritics-äöü-café.md#heat-pump-groesse", :resolved, :resolved},
    {"a fragment no section in the note carries", "bike/via-carolina.md#nosuch", :not_found,
     :not_found},
    {"a note the vault does not have", "bike/nosuch.md#gear", :not_found, :not_found},
    {"a reserved path", "_domains.yml#gear", :invalid_path, :invalid_path},
    {"a traversal", "../bike/via-carolina.md#gear", :invalid_path, :invalid_path},
    {"an absolute path", "/bike/via-carolina.md#gear", :invalid_path, :invalid_path},
    {"a hidden segment", ".git/config.md#gear", :invalid_path, :invalid_path},
    # The two rows where the four are meant to differ, and the reason they do.
    # Both paths are safe to resolve and neither is writable, so the gate
    # refuses before it looks anything up.
    {"a path under skills/", "skills/tdd.md#red-green", :not_found, :invalid_path},
    {"a path in an excluded domain", "work/secret.md#anything", :not_found, :invalid_path},
    # A bare path names a note. It reads, and it is not a section id at all —
    # which the write gate says before it looks at the path, because "this is
    # not a section id" is true of the id's shape and needs nothing resolved.
    {"a safe path with no fragment", "bike/via-carolina.md", :resolved, :no_fragment},
    {"a reserved path with no fragment", "_domains.yml", :invalid_path, :no_fragment}
  ]

  setup do
    layout = Layout.over_vault(@fixtures, @exclude)
    index = Index.build(Enum.map(Layout.note_paths(layout), &parse/1))

    facts =
      AbsentFacts.answering_nothing(
        layout: layout,
        find_chunk: &Index.find_chunk(index, &1)
      )

    %{index: index, facts: facts}
  end

  defp parse(rel_path) do
    {:ok, file} = Parser.parse(rel_path, File.read!(Path.join(@fixtures, rel_path)), @git_meta)
    file
  end

  for {description, id, reads, writes} <- @shapes do
    test "#{description}: the readers answer #{reads}, the write gate #{writes}", %{
      index: index,
      facts: facts
    } do
      id = unquote(id)

      assert verdict(Index.read(index, %{id: id, backlinks: false})) == unquote(reads)
      assert verdict(Index.links(index, %{id: id, direction: :both, depth: 1})) == unquote(reads)

      assert verdict(Policy.check(:replace_section, %{id: id, content: "body"}, facts)) ==
               unquote(writes)

      assert verdict(Policy.check(:delete_section, %{id: id}, facts)) == unquote(writes)

      # The function the write gate resolves through, asserted against the
      # readers' own verdict: a chunk comes back exactly when the id reads as
      # a section. This is the row that bites on an absolute path — it
      # normalizes onto a real chunk id, so a `find_chunk` doing its own
      # lookup without the safety check hands back a section `read` refuses.
      names_section? = unquote(reads) == :resolved and String.contains?(id, "#")
      assert is_map(Index.find_chunk(index, id)) == names_section?
    end
  end

  # The split rows, named once over the table rather than only row by row: a
  # row added with a reader/writer split has to be one of these or this fails.
  # Every one of them is the write gate refusing the id before resolving
  # anything — two for a path it may not write, two for an id that is not a
  # section id at all. No row with a fragment and a writable path splits, and
  # that is the claim `find_chunk/2` makes in its docstring.
  test "the only ids the four disagree about are the ones the write gate refuses outright" do
    disagreeing =
      for {_description, id, reads, writes} <- @shapes, reads != writes, do: {id, writes}

    assert disagreeing == [
             {"skills/tdd.md#red-green", :invalid_path},
             {"work/secret.md#anything", :invalid_path},
             {"bike/via-carolina.md", :no_fragment},
             {"_domains.yml", :no_fragment}
           ]
  end

  defp verdict({:ok, _}), do: :resolved
  defp verdict({:error, "Invalid path"}), do: :invalid_path
  defp verdict({:error, "Invalid path." <> _}), do: :invalid_path
  defp verdict({:error, "Not found: " <> _}), do: :not_found
  defp verdict({:error, "id must contain a fragment" <> _}), do: :no_fragment
end
