defmodule Vigil.Search do
  @moduledoc false

  @preview_len 120

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
    score = if title_hit?, do: score + 10, else: score
    score = if heading_hit?, do: score + 5, else: score
    score = score + min(body_hits, 5)
    score = if prefer && item.type == prefer, do: score + 5, else: score
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
