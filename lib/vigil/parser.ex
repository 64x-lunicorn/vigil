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
  @fenced_code_re ~r/```.*?```/s
  @inline_code_re ~r/`[^`\n]*`/

  defp build_chunks(path, {lines, offset}, type, starts, ends, created_at, updated_at) do
    total = length(lines)

    numbered =
      lines
      |> Enum.with_index(1)
      |> Enum.map(fn {line, idx} -> {line, idx + offset} end)

    state = %{
      title: nil,
      stack: [],
      slug_counts: %{},
      current: nil,
      chunks: [],
      pre: nil
    }

    state =
      Enum.reduce(numbered, state, fn {line, line_no}, acc ->
        cond do
          # The first H1 is the note title and creates no chunk of its own.
          first_h1 = is_nil(acc.title) && Markdown.h1(line) ->
            %{acc | title: first_h1}

          heading = Markdown.heading(line) ->
            {level, text} = heading

            acc =
              close_current(acc, line_no - 1, path, type, starts, ends, created_at, updated_at)

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

          acc.current != nil ->
            %{acc | current: %{acc.current | lines: [line | acc.current.lines]}}

          true ->
            current =
              acc[:pre] ||
                %{
                  heading: nil,
                  heading_path: [],
                  heading_line: nil,
                  body_start_line: line_no,
                  lines: []
                }

            %{acc | pre: %{current | lines: [line | current.lines]}}
        end
      end)

    # finalize trailing chunk (heading-based or none)
    state = close_current(state, total + offset, path, type, starts, ends, created_at, updated_at)

    pre = Map.get(state, :pre)
    pre_chunk = build_pre_chunk(path, pre, type, starts, ends, created_at, updated_at)

    chunks =
      case pre_chunk do
        nil -> Enum.reverse(state.chunks)
        chunk -> [chunk | Enum.reverse(state.chunks)]
      end

    {state.title, chunks}
  end

  defp close_current(%{current: nil} = acc, _end_line, _p, _t, _s, _e, _ca, _ua), do: acc

  defp close_current(acc, end_line, path, type, starts, ends, created_at, updated_at) do
    %{heading: heading, heading_path: heading_path, heading_line: heading_line, lines: rev_lines} =
      acc.current

    body_lines = Enum.reverse(rev_lines)
    body = Enum.join(body_lines, "\n")

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

  defp build_pre_chunk(_path, nil, _type, _starts, _ends, _ca, _ua), do: nil

  defp build_pre_chunk(
         path,
         %{lines: rev_lines, body_start_line: body_start},
         type,
         starts,
         ends,
         created_at,
         updated_at
       ) do
    body_lines = Enum.reverse(rev_lines)
    body = Enum.join(body_lines, "\n")

    if String.trim(body) == "" do
      nil
    else
      body_end = body_start + length(body_lines) - 1

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
    |> blank_matches(@fenced_code_re)
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
