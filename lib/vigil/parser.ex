defmodule Vigil.Parser do
  @moduledoc false

  require Logger

  alias Vigil.Markdown

  defmodule Chunk do
    @moduledoc false
    defstruct [
      :id,
      :path,
      :heading,
      :heading_path,
      :heading_line,
      :body_end_line,
      :body,
      :body_downcased,
      :links,
      :type,
      :starts,
      :ends,
      :created_at,
      :updated_at
    ]
  end

  defmodule File_ do
    @moduledoc false
    defstruct [:path, :title, :type, :starts, :ends, :chunks, :created_at, :updated_at]
  end

  @doc """
  Parses raw file content into a `File_` struct with its `Chunk`s.

  `git_meta` is `%{created_at: DateTime.t() | nil, updated_at: DateTime.t() | nil, last_author: String.t() | nil}`.
  Warnings are logged with `path` and reason; the function never raises.
  """
  def parse(path, content, git_meta \\ %{}) do
    created_at = Map.get(git_meta, :created_at)
    updated_at = Map.get(git_meta, :updated_at)

    {frontmatter, body_lines_with_offset} = extract_frontmatter(path, content)

    {type, starts, ends} = resolve_type(path, frontmatter)

    {title, chunks} =
      build_chunks(path, body_lines_with_offset, type, starts, ends, created_at, updated_at)

    file = %File_{
      path: path,
      title: title || fallback_title(path),
      type: type,
      starts: starts,
      ends: ends,
      chunks: chunks,
      created_at: created_at,
      updated_at: updated_at
    }

    {:ok, file}
  end

  defp extract_frontmatter(path, content) do
    case Markdown.frontmatter(content) do
      {:ok, yaml_text, body_lines, offset} ->
        {parse_yaml(path, yaml_text), {body_lines, offset}}

      :unterminated ->
        Logger.warning("unterminated frontmatter in #{path} (no closing ---)")
        {%{}, {Markdown.split_lines(content), 0}}

      :none ->
        Logger.warning("no frontmatter in #{path}")
        {%{}, {Markdown.split_lines(content), 0}}
    end
  end

  defp parse_yaml(path, yaml_text) do
    case YamlElixir.read_from_string(yaml_text) do
      {:ok, map} when is_map(map) ->
        map

      {:ok, _other} ->
        %{}

      {:error, reason} ->
        Logger.warning("unparsable frontmatter YAML in #{path}: #{inspect(reason)}")
        %{}
    end
  end

  defp resolve_type(path, frontmatter) do
    raw_type = Map.get(frontmatter, "type")

    type =
      case raw_type do
        "reference" ->
          :reference

        "decision" ->
          :decision

        "event" ->
          :event

        nil ->
          Logger.warning("missing 'type' field in #{path}, treating as reference")
          :reference

        other ->
          Logger.warning("invalid type '#{inspect(other)}' in #{path}, treating as reference")
          :reference
      end

    if type == :event do
      with {:ok, starts} <- parse_timestamp(Map.get(frontmatter, "starts")),
           {:ok, ends} <- parse_timestamp(Map.get(frontmatter, "ends")),
           true <- DateTime.compare(ends, starts) != :lt do
        {:event, starts, ends}
      else
        _ ->
          Logger.warning("event #{path} has invalid/missing starts/ends, treating as reference")

          {:reference, nil, nil}
      end
    else
      {type, nil, nil}
    end
  end

  defp parse_timestamp(nil), do: :error

  defp parse_timestamp(%DateTime{} = dt), do: {:ok, dt}

  defp parse_timestamp(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _offset} -> {:ok, dt}
      {:error, _} -> :error
    end
  end

  defp parse_timestamp(_), do: :error

  defp fallback_title(path) do
    path
    |> Path.basename(".md")
    |> String.replace("-", " ")
  end

  # Group 1: target (basename or path), group 2: optional #chunk fragment.
  # An alias (after |) is matched but not captured — it carries no meaning.
  @wikilink_re ~r/\[\[([^\]|#]+)(?:#([^\]|]+))?(?:\|[^\]]*)?\]\]/
  # Only .md targets — markdown links to anything else (images, external
  # URLs) are not note references. Group 1: path without extension,
  # group 2: fragment.
  @mdlink_re ~r/\[[^\]]*\]\(([^)#\s]+)\.md(?:#([^)]+))?\)/
  @inline_code_re ~r/`[^`\n]*`/

  defp build_chunks(path, {lines, offset}, type, starts, ends, created_at, updated_at) do
    # One reading of the note, fence state included: a heading inside a fenced
    # block is a line of somebody's code sample, and opens no chunk.
    numbered =
      lines
      |> Markdown.read()
      |> Enum.with_index(1)
      |> Enum.map(fn {read, idx} -> {read, idx + offset} end)

    state = %{
      title: nil,
      stack: [],
      slug_counts: %{},
      current: nil,
      chunks: [],
      pre: nil
    }

    state =
      Enum.reduce(numbered, state, fn {%{line: line, kind: kind}, line_no}, acc ->
        case kind do
          # The first H1 is the note title and creates no chunk of its own. A
          # second one is body text like any other line.
          {:h1, title} ->
            if acc.title, do: content_line(acc, line, line_no), else: %{acc | title: title}

          {:heading, level, text} ->
            acc = close_current(acc, path, type, starts, ends, created_at, updated_at)

            new_stack =
              acc.stack
              |> Enum.reject(fn {lvl, _} -> lvl >= level end)
              |> Kernel.++([{level, text}])

            heading_path = Enum.map(new_stack, fn {_, t} -> t end)

            %{
              acc
              | stack: new_stack,
                current: %{
                  heading: text,
                  heading_path: heading_path,
                  heading_line: line_no,
                  lines: []
                }
            }

          _fence_or_content ->
            content_line(acc, line, line_no)
        end
      end)

    # finalize trailing chunk (heading-based or none)
    state = close_current(state, path, type, starts, ends, created_at, updated_at)

    pre = Map.get(state, :pre)
    pre_chunk = build_pre_chunk(path, pre, type, starts, ends, created_at, updated_at)

    chunks =
      case pre_chunk do
        nil -> Enum.reverse(state.chunks)
        chunk -> [chunk | Enum.reverse(state.chunks)]
      end

    {state.title, chunks}
  end

  # A line that is neither the title nor a heading: the body of the chunk that
  # is open, or of the note's fragmentless opening chunk when none is.
  defp content_line(%{current: nil} = acc, line, line_no) do
    pre = acc.pre || %{heading: nil, heading_path: [], heading_line: nil, lines: []}
    %{acc | pre: %{pre | lines: [{line, line_no} | pre.lines]}}
  end

  defp content_line(acc, line, line_no) do
    %{acc | current: %{acc.current | lines: [{line, line_no} | acc.current.lines]}}
  end

  defp close_current(%{current: nil} = acc, _p, _t, _s, _e, _ca, _ua), do: acc

  defp close_current(acc, path, type, starts, ends, created_at, updated_at) do
    %{heading: heading, heading_path: heading_path, heading_line: heading_line, lines: rev_lines} =
      acc.current

    # A body of nothing but blank lines collapses onto its own heading line.
    {body, end_line} = close_body(rev_lines)
    end_line = end_line || heading_line

    base_slug = slug(heading)
    {final_slug, slug_counts} = uniquify(base_slug, acc.slug_counts)
    id = "#{path}##{final_slug}"

    chunk = %Chunk{
      id: id,
      path: path,
      heading: heading,
      heading_path: heading_path,
      heading_line: heading_line,
      body_end_line: end_line,
      body: body,
      body_downcased: String.downcase(body),
      links: extract_links(body),
      type: type,
      starts: starts,
      ends: ends,
      created_at: created_at,
      updated_at: updated_at
    }

    %{acc | current: nil, slug_counts: slug_counts, chunks: [chunk | acc.chunks]}
  end

  # A chunk's body and the line it ends on, from the body's lines in reverse
  # order. The body ends at its **last non-blank** line: the blank lines
  # separating two sections belong to neither (docs/design.md, "Chunking").
  # `nil` for a body that has no content line at all — the caller says what
  # an empty body's end line is.
  #
  # The end line is the line's own number, not a count from the heading: the
  # first H1 is consumed as the note title without joining any body, so a
  # note whose H1 sits below its first `##` has a gap in the count.
  defp close_body(rev_lines) do
    numbered =
      rev_lines
      |> Enum.drop_while(fn {line, _no} -> String.trim(line) == "" end)
      |> Enum.reverse()

    body = numbered |> Enum.map(fn {line, _no} -> line end) |> Enum.join("\n")

    case List.last(numbered) do
      nil -> {body, nil}
      {_line, line_no} -> {body, line_no}
    end
  end

  defp build_pre_chunk(_path, nil, _type, _starts, _ends, _ca, _ua), do: nil

  defp build_pre_chunk(
         path,
         %{lines: rev_lines},
         type,
         starts,
         ends,
         created_at,
         updated_at
       ) do
    # The same boundary as a heading chunk, through the same function — this
    # chunk just has no heading to fall back on, so a body with no content
    # line at all makes no chunk.
    {body, body_end} = close_body(rev_lines)

    if body_end == nil do
      nil
    else
      %Chunk{
        id: path,
        path: path,
        heading: nil,
        heading_path: [],
        heading_line: nil,
        body_end_line: body_end,
        body: body,
        body_downcased: String.downcase(body),
        links: extract_links(body),
        type: type,
        starts: starts,
        ends: ends,
        created_at: created_at,
        updated_at: updated_at
      }
    end
  end

  @doc """
  Extracts **raw**, unresolved outgoing references.

  Actual resolution (candidate lookup, ambiguous/broken classification)
  happens in `Vigil.Store`, which needs to know about every note in the vault —
  knowledge the parser, as a pure file-to-chunks function, does not have.

  Recognises `[[target]]`, `[[target#fragment]]`, `[[target|alias]]` and
  `[text](path.md)` / `[text](path.md#fragment)`. Links inside fenced code
  blocks (` ``` `) and inline code (`` ` ``) are **not** extracted — otherwise
  the parser would index example code as real references.

  Which lines are fenced comes from `Vigil.Markdown.read/1`, the same reading
  the chunker takes its headings from, so the two halves of parsing one file
  cannot disagree about where the code samples are. Inline code is a
  within-line fact and stays a regex.
  """
  def extract_links(body) do
    cleaned = strip_code(body)

    wiki =
      Regex.scan(@wikilink_re, cleaned)
      |> Enum.map(fn
        [_, target] -> {String.trim(target), nil}
        [_, target, fragment] -> {String.trim(target), trim_or_nil(fragment)}
      end)

    markdown =
      Regex.scan(@mdlink_re, cleaned)
      |> Enum.map(fn
        [_, target] -> {String.trim(target), nil}
        [_, target, fragment] -> {String.trim(target), trim_or_nil(fragment)}
      end)

    (wiki ++ markdown)
    |> Enum.reject(fn {target, _fragment} -> target == "" end)
    |> Enum.uniq()
    |> Enum.map(fn {target, fragment} -> %{raw: target, fragment: fragment} end)
  end

  defp trim_or_nil(nil), do: nil
  defp trim_or_nil(text), do: String.trim(text)

  defp strip_code(text) do
    text
    |> Markdown.read()
    |> Enum.map(fn
      %{kind: kind} when kind in [:fence, :code] -> ""
      %{line: line} -> line
    end)
    |> Enum.join("\n")
    |> blank_matches(@inline_code_re)
  end

  defp blank_matches(text, regex) do
    Regex.replace(regex, text, fn match -> String.replace(match, ~r/[^\n]/, " ") end)
  end

  defp uniquify(base_slug, counts) do
    case Map.get(counts, base_slug) do
      nil ->
        {base_slug, Map.put(counts, base_slug, 1)}

      n ->
        candidate = "#{base_slug}-#{n + 1}"
        {candidate, Map.put(counts, base_slug, n + 1)}
    end
  end

  @doc """
  Slugifies text via `Vigil.Slug.slugify/1` — the single slug implementation
  in the project, so chunk IDs and normalized file/directory names never
  diverge. An empty result (no alphanumeric characters at all, e.g. a heading
  of just "---") falls back to "".
  """
  def slug(text) do
    case Vigil.Slug.slugify(text) do
      {:ok, slug} -> slug
      {:error, _reason} -> ""
    end
  end
end
