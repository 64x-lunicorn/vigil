defmodule Vigil.Markdown do
  @moduledoc """
  The one reading of a Markdown note: what counts as a heading, where the
  frontmatter block ends, how content splits into lines.

  Before this module the same three facts were restated in `Vigil.Parser`,
  `Vigil.Store`, `Vigil.VaultCheck` and `mix vigil.slug_diff`, so the running
  server and the doctor task could disagree about the same file. Every caller
  now asks here.
  """

  # H1 is deliberately not a heading: it is the note title and creates no
  # chunk. H5 and deeper are not headings either — chunk ids derive from
  # H2–H4 only (see docs/design.md, "Chunking").
  @h1_re ~r/^\#\s+(.+?)\s*$/
  @heading_re ~r/^(\#{2,4})\s+(.+?)\s*$/

  @frontmatter_marker "---"

  @doc "Splits content into lines, dropping the single trailing empty line a file ends with."
  def split_lines(content) do
    lines = String.split(content, "\n")

    case List.last(lines) do
      "" -> Enum.slice(lines, 0..-2//1)
      _ -> lines
    end
  end

  @doc "`{rank, text}` for an H2–H4 line, `nil` for anything else."
  def heading(line) do
    case Regex.run(@heading_re, line) do
      [_, hashes, text] -> {String.length(hashes), String.trim(text)}
      _ -> nil
    end
  end

  @doc "True for an H2–H4 line."
  def heading?(line), do: Regex.match?(@heading_re, line)

  @doc "The trimmed title of an H1 line, `nil` for anything else."
  def h1(line) do
    case Regex.run(@h1_re, line) do
      [_, text] -> String.trim(text)
      _ -> nil
    end
  end

  @doc "The first H1 title anywhere in `content`, or `nil`."
  def first_h1(content) do
    content
    |> split_lines()
    |> Enum.find_value(&h1/1)
  end

  @doc "Every H2–H4 in `content` as `{rank, text}`, in document order."
  def headings(content) do
    content
    |> split_lines()
    |> Enum.flat_map(fn line ->
      case heading(line) do
        nil -> []
        h -> [h]
      end
    end)
  end

  @doc "How many H2–H4 headings `content` has."
  def count_headings(content) do
    content |> split_lines() |> Enum.count(&heading?/1)
  end

  @doc "True when `content`, ignoring leading whitespace, opens with an H1."
  def starts_with_h1?(content) do
    Regex.match?(~r/^\#\s+.+/, String.trim_leading(content))
  end

  @doc "True when `content`, ignoring leading whitespace, opens a frontmatter block."
  def starts_with_frontmatter?(content) do
    String.starts_with?(String.trim_leading(content), @frontmatter_marker)
  end

  @doc """
  The frontmatter block of `content`.

  `{:ok, yaml_text, body_lines, offset}` where `offset` is the number of lines
  consumed (opening marker + YAML + closing marker), `:none` when the content
  does not start with a marker, `:unterminated` when the block never closes.
  """
  def frontmatter(content) do
    case frontmatter_lines(content) do
      {:ok, yaml_lines, body_lines, offset} ->
        {:ok, Enum.join(yaml_lines, "\n"), body_lines, offset}

      other ->
        other
    end
  end

  @doc """
  Splits `content` into its frontmatter block and its body, both terminated by
  a newline. The two failure modes are reported distinctly because they mean
  different things to a writer: no block at all, versus a block left open.

  Works on the block's lines rather than its joined text, so a frontmatter
  block whose only line is blank round-trips unchanged.
  """
  def split_frontmatter(content) do
    case frontmatter_lines(content) do
      {:ok, yaml_lines, body_lines, _offset} ->
        block = Enum.join([@frontmatter_marker | yaml_lines] ++ [@frontmatter_marker], "\n")
        {:ok, block <> "\n", Enum.join(body_lines, "\n") <> "\n"}

      :unterminated ->
        {:error, "Unterminated frontmatter"}

      :none ->
        {:error, "No frontmatter found"}
    end
  end

  defp frontmatter_lines(content) do
    case split_lines(content) do
      [@frontmatter_marker | rest] ->
        case Enum.find_index(rest, &(&1 == @frontmatter_marker)) do
          nil -> :unterminated
          idx -> {:ok, Enum.take(rest, idx), Enum.drop(rest, idx + 1), idx + 2}
        end

      _ ->
        :none
    end
  end
end
