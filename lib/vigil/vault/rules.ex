defmodule Vigil.Vault.Rules do
  @moduledoc """
  Vault hygiene rules that more than one caller asks about.

  `Vigil.Store.lint/1` and `Vigil.VaultCheck` answer different questions in
  different shapes and stay separate, but the facts underneath — what counts
  as a sentence-shaped heading, which headings collide, which heading slugs
  would change — were restated in both, and drifted. They live here now.
  """

  alias Vigil.{Markdown, Parser, Slug}

  # Rough heuristic: a heading that reads like a sentence is either long or
  # ends in punctuation. Both are signals, not proof.
  @sentence_heading_length_threshold 60

  @doc "True when a heading reads like a sentence rather than a label."
  def sentence_heading?(heading) do
    String.length(heading) > @sentence_heading_length_threshold or
      String.ends_with?(heading, [".", "!", "?"])
  end

  # A note past either of these is asking to be split. Two axes, because the
  # pair says *why* the note is too long — many sections, or much prose —
  # which is what the reader acts on.
  @max_headings 30
  @max_words 2000

  @doc """
  How long one note is, and whether that makes it overlong.

  Takes the note's chunks — anything carrying a `:heading` and a `:body` —
  and returns `%{headings:, words:, over_heading_threshold:,
  over_word_threshold:}`. A note is overlong past #{@max_headings} headings or
  #{@max_words} words; `overlong?/1` says whether either was crossed.

  The counts come back whether or not a threshold was crossed, because a
  caller reporting a note for another reason still wants to say how long it
  is.
  """
  def note_length(chunks) do
    headings = Enum.count(chunks, & &1.heading)

    words =
      chunks
      |> Enum.map(& &1.body)
      |> Enum.join(" ")
      |> String.split(~r/\s+/, trim: true)
      |> length()

    %{
      headings: headings,
      words: words,
      over_heading_threshold: headings > @max_headings,
      over_word_threshold: words > @max_words
    }
  end

  @doc "True when a `note_length/1` result crossed either threshold."
  def overlong?(%{over_heading_threshold: over_headings, over_word_threshold: over_words}) do
    over_headings or over_words
  end

  @doc """
  The headings within one note that collide in its chunk-id space.

  Takes the note's chunks — anything carrying a `:heading` — and groups them
  by the slug of the heading **text alone**, which is what
  `Vigil.Parser`'s uniquifier keys its collision counter on: two `### B`
  headings under different H2s really do produce `b` and `b-2`, however
  different their heading chains are. Grouping by the chain instead would
  under-report exactly the notes whose chunk ids are unstable — and a chunk id
  that moves breaks every stored reference to it (`docs/design.md`, "Known
  trade-offs").

  Returns one entry per colliding slug, `%{slug: slug, chunks: [chunk]}`, in
  slug order, with the chunks in the order the note has them. A note with no
  collisions returns `[]`. Callers shape their own finding from the chunks.
  """
  def duplicate_headings(chunks) do
    chunks
    |> Enum.filter(& &1.heading)
    |> Enum.group_by(&Parser.slug(&1.heading))
    |> Enum.filter(fn {_slug, group} -> length(group) > 1 end)
    |> Enum.map(fn {slug, group} -> %{slug: slug, chunks: group} end)
    |> Enum.sort_by(& &1.slug)
  end

  @doc """
  Whether the *filename* half of `path` would move when the slug function
  changes — the other half of `heading_slug_changes/1`.

  Returns `nil` when the basename slugifies the same way under
  `Vigil.Slug.legacy_slugify/1` and `Vigil.Slug.slugify/1`, otherwise
  `%{old:, new:}` with `new` `nil` when no slug can be derived at all.

  A filename and a heading are one question — what a slug change breaks — so
  the two callers that ask it (`Vigil.VaultCheck` and `mix vigil.slug_diff`)
  cannot disagree about the blast radius, which is the entire reason
  `mix vigil.slug_diff` exists (`docs/design.md`, "Path normalization and
  naming rules").
  """
  def filename_slug_change(path) do
    basename = Path.basename(path, ".md")

    case {Slug.legacy_slugify(basename), Slug.slugify(basename)} do
      {old, {:ok, new}} when old != new -> %{old: old, new: new}
      {old, {:error, _}} -> %{old: old, new: nil}
      _ -> nil
    end
  end

  @doc """
  Every H2–H4 heading in `content` whose chunk id would change when moving
  from `Vigil.Slug.legacy_slugify/1` to `Vigil.Slug.slugify/1`.

  `new` is `nil` for a heading from which no slug can be derived at all.
  Headings whose slug is unchanged are omitted.
  """
  def heading_slug_changes(content) do
    content
    |> Markdown.headings()
    |> Enum.flat_map(fn {_rank, text} ->
      case {Slug.legacy_slugify(text), Slug.slugify(text)} do
        {old, {:ok, new}} when old != new -> [%{text: text, old: old, new: new}]
        {old, {:error, _}} -> [%{text: text, old: old, new: nil}]
        _ -> []
      end
    end)
  end
end
