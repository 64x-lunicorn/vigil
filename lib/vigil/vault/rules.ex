defmodule Vigil.Vault.Rules do
  @moduledoc """
  Vault hygiene rules that more than one caller asks about.

  `Vigil.Store.lint/1` and `Vigil.VaultCheck` answer different questions in
  different shapes and stay separate, but the facts underneath — what counts
  as a sentence-shaped heading, which heading slugs would change — were
  restated in both, and drifted. They live here now.
  """

  alias Vigil.{Markdown, Slug}

  # Rough heuristic: a heading that reads like a sentence is either long or
  # ends in punctuation. Both are signals, not proof.
  @sentence_heading_length_threshold 60

  @doc "True when a heading reads like a sentence rather than a label."
  def sentence_heading?(heading) do
    String.length(heading) > @sentence_heading_length_threshold or
      String.ends_with?(heading, [".", "!", "?"])
  end

  @doc """
  Every H2–H4 heading in `content` whose chunk id would change when moving
  from `Vigil.Slug.legacy_slugify/1` to `Vigil.Slug.slugify/1`.

  `new` is `nil` for a heading from which no slug can be derived at all.
  Headings whose slug is unchanged are omitted.
  """
  def slug_changes(content) do
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
