defmodule Vigil.Search do
  @moduledoc """
  Ranking and previews behind the `search` tool.

  A hit's score is the sum of what matched — the scale is published as
  `strength/1`, because a caller that filters on a score is filtering on this
  scale. `Vigil.Vault.Policy`'s duplicate gate is such a caller: it keeps hits
  at `strength(:title)` and above. Published rather than left to be inferred,
  so the scale cannot be changed here without the gate that reads it moving
  with it.
  """

  @preview_len 120

  # The scoring scale, defined once and read by both `score/3` and
  # `strength/1`.
  @title 10
  @heading 5
  @body_occurrence 1
  @body_occurrence_cap 5
  @preferred_type 5

  @doc """
  What `kind` is worth on the scoring scale.

    * `:title` — the query appears in the note's title.
    * `:heading` — it appears in a heading on the way to the chunk.
    * `:body_occurrence` — it appears once in the body.
    * `:body_occurrences_max` — the most the body can contribute, however
      often the query occurs in it.
    * `:preferred_type` — the chunk has the type the caller preferred.

  The whole scale is published, not only the one number a caller compares
  against: what a threshold means is a claim about how the parts add up, and
  neither a caller nor a test can check that claim unless the parts are named.

  `strength(:title)` is the lowest score meaning *the query names this note*
  rather than merely appearing in it — for a search with no preferred type. A
  title hit reaches it alone; the only other way to it is a heading hit with
  the body at its maximum. A `prefer` hint adds a second axis and the reading
  no longer holds: `:preferred_type` lifts a heading hit or a body at its
  maximum to the same score, and a chunk of the preferred type scores above
  zero without matching the query anywhere. `Vigil.Vault.Policy`'s duplicate
  gate is asked without a preference, which is what makes the reading it
  relies on true.
  """
  @spec strength(atom) :: pos_integer
  def strength(:title), do: @title
  def strength(:heading), do: @heading
  def strength(:body_occurrence), do: @body_occurrence
  def strength(:body_occurrences_max), do: @body_occurrence * @body_occurrence_cap
  def strength(:preferred_type), do: @preferred_type

  @doc """
  `items` is a list of maps:
  `%{id:, file_title:, heading_path:, type:, body:, body_downcased:, updated_at:}`.

  `opts`: `:prefer`, and `:limit`, which is required. The bound on `limit` is
  declared in `Vigil.MCP.Tools`' table and refused there; a limit that arrives
  here has already been validated against it, so this function takes the
  caller at its word rather than silently returning fewer hits than asked for.
  """
  def run(items, query, opts) do
    q = String.downcase(query)
    limit = Map.fetch!(opts, :limit)
    prefer = Map.get(opts, :prefer)

    items
    |> Enum.map(&{score(&1, q, prefer), &1})
    |> Enum.filter(fn {score, _} -> score > 0 end)
    |> Enum.sort_by(fn {score, item} -> {-score, negated_time(item.updated_at)} end)
    |> Enum.take(limit)
    |> Enum.map(fn {score, item} -> to_result(item, score) end)
  end

  defp negated_time(nil), do: 0

  defp negated_time(%DateTime{} = dt), do: -DateTime.to_unix(dt)

  defp score(item, q, prefer) when q != "" do
    title_hit? = String.contains?(String.downcase(item.file_title), q)

    heading_hit? =
      Enum.any?(item.heading_path, fn h -> String.contains?(String.downcase(h), q) end)

    body_hits = count_occurrences(item.body_downcased, q)

    score = 0
    score = if title_hit?, do: score + @title, else: score
    score = if heading_hit?, do: score + @heading, else: score
    score = score + @body_occurrence * min(body_hits, @body_occurrence_cap)
    score = if prefer && item.type == prefer, do: score + @preferred_type, else: score
    score
  end

  defp score(_item, "", _prefer), do: 0

  defp count_occurrences(_haystack, ""), do: 0

  defp count_occurrences(haystack, needle) do
    case :binary.matches(haystack, needle) do
      :nomatch -> 0
      matches -> length(matches)
    end
  end

  defp to_result(item, score) do
    %{
      id: item.id,
      title: display_title(item),
      type: item.type,
      score: score,
      preview: preview(item.body)
    }
  end

  def display_title(%{file_title: title, heading_path: path}) do
    Enum.join([title | path], " › ")
  end

  def preview(body, limit \\ @preview_len) do
    text =
      body
      |> String.replace(~r/\r?\n/, " ")
      |> String.replace(~r/[#*_\[\]]/, "")
      |> String.replace(~r/\s+/, " ")
      |> String.trim()

    if String.length(text) <= limit do
      text
    else
      truncate_at_word(text, limit) <> "…"
    end
  end

  defp truncate_at_word(text, limit) do
    truncated = String.slice(text, 0, limit)

    case :binary.matches(truncated, " ") do
      [] ->
        truncated

      matches ->
        {pos, _len} = List.last(matches)
        String.slice(truncated, 0, pos)
    end
  end
end
