defmodule Vigil.Vault.Edit do
  @moduledoc """
  What a chunk-shaped write turns a note's content into.

  The pairing with `Vigil.Vault.Policy` states the split: `Policy` decides
  *whether* a write is allowed, `Edit` produces *what* the file becomes. Both
  are pure — no process, no filesystem, no git. The caller hands this module
  the string it read from disk and gets a string back; `Edit` owns the split
  into lines and the join. How a file ends is `Vigil.Markdown`'s rule, stated
  once for every write path (docs/design.md, "How a file is written").

  The target of a splice is a `%Vigil.Parser.Chunk{}` — the value `Store`
  already holds from the index, produced by the parser and unchanged since.
  `Edit` depends on `Vigil.Parser` for the struct and for the line-index
  helpers it splices by; the line numbers are the parser's, so the module
  that states what they mean is the module the splice asks.

  Before any splice the line the chunk's `heading_line` names is checked to
  still hold its heading: the numbers are the index's, the content is what is
  on disk, and when the two have drifted apart the edit is refused rather
  than spliced into another section.

  The frontmatter block is edited here too, by line: the keys vigil owns are
  replaced, added or removed, and every other line stays as the human wrote
  it (docs/design.md, "Frontmatter — exactly one required field").

  `Vigil.Vault.Policy` already guarantees a non-nil chunk
  with a non-nil heading before a splice is reached, but that guarantee lives
  in a different module. A failed write must never take the `Store` GenServer
  down, so the precondition is checked here too — an error tuple, not a raise.
  """

  alias Vigil.Markdown
  alias Vigil.Parser.Chunk

  @type target :: {:section, Chunk.t()} | {:new_section, String.t()} | :end

  @doc "The heading line stays; the body under it becomes `new_body`."
  @spec replace_body(String.t(), Chunk.t() | nil, String.t()) ::
          {:ok, String.t()} | {:error, String.t()}
  def replace_body(content, chunk, new_body) do
    lines = Markdown.split_lines(content)

    with :ok <- validate_chunk(chunk),
         :ok <- heading_in_place(lines, chunk) do
      {:ok,
       splice(
         lines,
         Chunk.body_start_index(chunk),
         Chunk.body_end_index(chunk),
         body_lines(new_body)
       )}
    end
  end

  @doc """
  The heading goes with the body it heads, and so does the one blank line
  after it — the slot the section occupied, which belongs to no chunk
  (docs/design.md, "How a file is written"). Only one: a wider gap someone
  set on purpose survives, one line narrower.
  """
  @spec delete_section(String.t(), Chunk.t() | nil) ::
          {:ok, String.t()} | {:error, String.t()}
  def delete_section(content, chunk) do
    lines = Markdown.split_lines(content)

    with :ok <- validate_chunk(chunk),
         :ok <- heading_in_place(lines, chunk) do
      body_end_index = Chunk.body_end_index(chunk)
      resume = body_end_index + separator_after(lines, body_end_index)

      {:ok, splice(lines, Chunk.heading_index(chunk), resume, [])}
    end
  end

  @doc """
  Inserts `new_content` at `target`: `{:section, chunk}` appends at the end of
  an existing section's body, `{:new_section, heading}` opens a fresh `##`
  section at the end of the file, `:end` appends at EOF with no heading.
  """
  @spec append(String.t(), target, String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def append(content, {:section, chunk}, new_content) do
    lines = Markdown.split_lines(content)

    with :ok <- validate_chunk(chunk),
         :ok <- heading_in_place(lines, chunk) do
      # Insert right at the chunk's end — no separator needed, since the body
      # ends at its last non-blank line and the blank line that follows it is
      # still there, after the insert point (docs/design.md, "Chunking").
      body_end_index = Chunk.body_end_index(chunk)

      {:ok, splice(lines, body_end_index, body_end_index, body_lines(new_content))}
    end
  end

  def append(content, {:new_section, heading}, new_content) do
    lines = Markdown.split_lines(content)
    {:ok, join(lines ++ ["", "## #{heading}"] ++ body_lines(new_content))}
  end

  def append(content, :end, new_content) do
    lines = Markdown.split_lines(content)
    {:ok, join(lines ++ [""] ++ body_lines(new_content))}
  end

  @owned_keys ~w(type starts ends)
  @owned_key_re ~r/^(type|starts|ends)[ \t]*:(?:[ \t]|$)/

  @doc """
  The lines of a frontmatter block with the keys vigil owns — `type`,
  `starts`, `ends` — set to `owned`, an ordered list of `{key, value}`, and
  every other line kept byte for byte and in its order. An owned key that is
  in the block is replaced where it stands, or removed when `owned` leaves it
  out; one that is not goes after the owned key before it, and `type` at the
  top of the block.

  YAML decides only whether the block may be edited: it must parse to a
  mapping, before and after, and the edit must leave every key but the owned
  ones meaning what it meant. A block the line edit cannot handle — an owned
  key whose value runs over several lines, one written twice, one written in
  a form the edit does not find — is refused rather than half rewritten, with
  a reason the caller can name.
  """
  @spec set_frontmatter([String.t()], [{String.t(), String.t()}]) ::
          {:ok, [String.t()]} | {:error, String.t()}
  def set_frontmatter(yaml_lines, owned) do
    with {:ok, before} <- yaml_mapping(yaml_lines),
         {:ok, found} <- owned_lines(yaml_lines),
         :ok <- all_found(before, found) do
      lines = yaml_lines |> replace_owned(owned) |> insert_missing(owned)

      case yaml_mapping(lines) do
        {:ok, after_edit} ->
          if Map.drop(after_edit, @owned_keys) == Map.drop(before, @owned_keys) and
               {:ok, Map.take(after_edit, @owned_keys)} == yaml_mapping(owned_block(owned)) do
            {:ok, lines}
          else
            {:error, "editing it by line would change keys vigil does not own"}
          end

        {:error, _reason} ->
          {:error, "editing it by line would leave YAML that does not parse"}
      end
    end
  end

  defp yaml_mapping(lines) do
    case YamlElixir.read_from_string(Enum.join(lines, "\n")) do
      {:ok, map} when is_map(map) -> {:ok, map}
      {:ok, _other} -> {:error, "its YAML is not a mapping of keys to values"}
      {:error, _reason} -> {:error, "its YAML does not parse"}
    end
  end

  # Where each owned key stands, by line index. A value that continues on the
  # lines below its key — a block scalar, a nested list, a flow collection
  # broken over lines — is not one line to replace, and neither is a key
  # written twice.
  defp owned_lines(lines) do
    indexed = Enum.with_index(lines)

    Enum.reduce_while(indexed, {:ok, %{}}, fn {line, index}, {:ok, found} ->
      case owned_key(line) do
        nil ->
          {:cont, {:ok, found}}

        key when is_map_key(found, key) ->
          {:halt, {:error, "`#{key}` appears more than once"}}

        key ->
          if continues?(Enum.at(lines, index + 1)) do
            {:halt, {:error, "the value of `#{key}` runs over several lines"}}
          else
            {:cont, {:ok, Map.put(found, key, index)}}
          end
      end
    end)
  end

  defp owned_key(line) do
    case Regex.run(@owned_key_re, line) do
      [_, key] -> key
      nil -> nil
    end
  end

  defp continues?(nil), do: false
  defp continues?(line), do: Regex.match?(~r/^(?:[ \t]+\S|-(?:[ \t]|$))/, line)

  # A key YAML reads but the line edit did not find would survive the edit
  # beside the line written for it.
  defp all_found(before, found) do
    case Enum.find(@owned_keys, &(Map.has_key?(before, &1) and not Map.has_key?(found, &1))) do
      nil -> :ok
      key -> {:error, "`#{key}` is written in a form vigil does not edit"}
    end
  end

  defp replace_owned(lines, owned) do
    Enum.flat_map(lines, fn line ->
      case owned_key(line) do
        nil ->
          [line]

        key ->
          case List.keyfind(owned, key, 0) do
            {^key, value} -> [owned_line(key, value)]
            nil -> []
          end
      end
    end)
  end

  # Each owned key missing from the block goes after the one before it in
  # `owned`, so an event reads type, starts, ends wherever it can.
  defp insert_missing(lines, owned) do
    {lines, _previous} =
      Enum.reduce(owned, {lines, nil}, fn {key, value}, {lines, previous} ->
        if Enum.any?(lines, &(owned_key(&1) == key)) do
          {lines, key}
        else
          at = if previous, do: Enum.find_index(lines, &(owned_key(&1) == previous)) + 1, else: 0
          {List.insert_at(lines, at, owned_line(key, value)), key}
        end
      end)

    lines
  end

  @doc "The lines `owned` is written as in a block that has nothing else."
  @spec owned_block([{String.t(), String.t()}]) :: [String.t()]
  def owned_block(owned), do: Enum.map(owned, fn {key, value} -> owned_line(key, value) end)

  defp owned_line(key, value), do: "#{key}: #{value}"

  # Rewrites the file around one chunk: every line before `keep_lines`, then
  # `replacement`, then everything from `resume_line` onwards.
  defp splice(lines, keep_lines, resume_line, replacement) do
    prefix = Enum.slice(lines, 0, keep_lines)
    suffix = Enum.drop(lines, resume_line)

    join(prefix ++ replacement ++ suffix)
  end

  # 1 when the line after a section's body is the blank one that separated it
  # from what follows — the slot the section occupied. Never more than one: a
  # wider gap someone set on purpose survives, one line narrower.
  defp separator_after(lines, body_end_index) do
    case Enum.at(lines, body_end_index) do
      nil -> 0
      line -> if String.trim(line) == "", do: 1, else: 0
    end
  end

  # A body as the chunk model defines one: content lines, no trailing blanks.
  # Content the caller ended with a blank line would otherwise put a second
  # separator in front of the next heading — a body no parse would give back
  # (docs/design.md, "How a file is written").
  defp body_lines(content) do
    content
    |> Markdown.split_lines()
    |> Enum.reverse()
    |> Enum.drop_while(&(String.trim(&1) == ""))
    |> Enum.reverse()
  end

  defp join(lines), do: lines |> Enum.join("\n") |> Markdown.normalize_trailing_newline()

  defp validate_chunk(nil), do: {:error, "no such section"}

  defp validate_chunk(%Chunk{heading: nil}),
    do: {:error, "a section without a heading cannot be edited"}

  defp validate_chunk(%Chunk{}), do: :ok

  # The splice goes by the index's line numbers, and the file is what is on
  # disk now. If the line the index names no longer holds the chunk's heading,
  # the two have drifted apart and the splice would land in whichever section
  # sits there instead (docs/design.md, "A retried write is applied once").
  # Only the heading's text is compared: the chunk does not record its rank.
  defp heading_in_place(lines, chunk) do
    case Markdown.heading(Enum.at(lines, Chunk.heading_index(chunk)) || "") do
      {_rank, text} when text == chunk.heading ->
        :ok

      _ ->
        {:error,
         "The index no longer matches the file: line #{chunk.heading_line} does not hold " <>
           "the heading \"#{chunk.heading}\". Call reload, then try again."}
    end
  end
end
