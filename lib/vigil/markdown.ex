defmodule Vigil.Markdown do
  @moduledoc """
  The one reading of a Markdown note: what counts as a heading, where the
  frontmatter block ends, how content splits into lines, and which of those
  lines are fenced code.

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

  # A fence delimiter: leading space, then three or more backticks or three or
  # more tildes. An opening delimiter may carry an info string (```markdown);
  # a closing one carries nothing but whitespace. Group 1 is the run itself,
  # group 2 whatever follows it on the line.
  @fence_re ~r/^\s*(`{3,}|~{3,})(.*)$/

  @typedoc """
  What one line of a note is. `:fence` is a delimiter line, `:code` a line
  inside a fenced block — for everyone but a syntax highlighter the two are
  the same thing: body content that says nothing about the note's structure.
  """
  @type line_kind ::
          :fence
          | :code
          | {:h1, String.t()}
          | {:heading, 2..4, String.t()}
          | :content

  @type read_line :: %{line: String.t(), kind: line_kind()}

  @doc """
  `content` ending in exactly one `\\n` — the shape of every file vigil writes.

  The rule lives here rather than in the module that writes notes because the
  path that writes *skills* must not depend on note editing: skills are never
  notes (docs/design.md, "How a file is written").
  """
  def normalize_trailing_newline(content), do: String.trim_trailing(content, "\n") <> "\n"

  @doc "Splits content into lines, dropping the single trailing empty line a file ends with."
  def split_lines(content) do
    lines = String.split(content, "\n")

    case List.last(lines) do
      "" -> Enum.slice(lines, 0..-2//1)
      _ -> lines
    end
  end

  @doc """
  Reads a note into its lines, each classified: a fence delimiter, a line
  inside a fenced block, the H1 title, an H2–H4 heading, or ordinary content.

  Takes the note's `content`, or the lines a caller has already split off —
  `Vigil.Parser` hands over the body lines it kept past the frontmatter block.
  Line numbers stay with the caller, which is the only one that knows what the
  first line it handed over is numbered.

  Fence state is a fact about a whole file in line order, which is why it is
  decided here and not by a regex over a body: a pair-matching regex cannot
  tell an opening delimiter from a closing one when a note holds an odd number
  of them, and a fence left open at the end of a note is a real case. A block
  opened with backticks is closed by backticks only, by at least as many as
  opened it, and by a delimiter carrying no info string.
  """
  @spec read(String.t() | [String.t()]) :: [read_line()]
  def read(content) when is_binary(content), do: content |> split_lines() |> read()

  def read(lines) when is_list(lines) do
    {read, _open} =
      Enum.map_reduce(lines, nil, fn line, open ->
        {kind, open} = classify(line, open)
        {%{line: line, kind: kind}, open}
      end)

    read
  end

  # Inside a block: only its own closing delimiter ends it; everything else,
  # heading-shaped lines included, is code.
  defp classify(line, {char, length} = open) do
    case fence_delimiter(line) do
      {^char, closing_length, ""} when closing_length >= length -> {:fence, nil}
      _ -> {:code, open}
    end
  end

  defp classify(line, nil) do
    case fence_delimiter(line) do
      {char, length, _info} ->
        {:fence, {char, length}}

      nil ->
        {heading_kind(line), nil}
    end
  end

  defp heading_kind(line) do
    case h1(line) do
      nil ->
        case heading(line) do
          {rank, text} -> {:heading, rank, text}
          nil -> :content
        end

      title ->
        {:h1, title}
    end
  end

  # `{delimiter character, its length, the rest of the line trimmed}`, or `nil`
  # for a line that is no delimiter at all.
  defp fence_delimiter(line) do
    case Regex.run(@fence_re, line) do
      [_, run, info] -> {String.first(run), String.length(run), String.trim(info)}
      nil -> nil
    end
  end

  @doc "`{rank, text}` for an H2–H4 line, `nil` for anything else."
  def heading(line) do
    case Regex.run(@heading_re, line) do
      [_, hashes, text] -> {String.length(hashes), String.trim(text)}
      _ -> nil
    end
  end

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

  @doc """
  Every H2–H4 in `content` as `{rank, text}`, in document order.

  Through `read/1`, so a heading inside a fenced block is not one: what this
  answers is what the index has chunks for.
  """
  def headings(content) do
    content
    |> read()
    |> Enum.flat_map(fn
      %{kind: {:heading, rank, text}} -> [{rank, text}]
      _other -> []
    end)
  end

  @doc "How many H2–H4 headings `content` has, fenced code excluded."
  def count_headings(content), do: content |> headings() |> length()

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
