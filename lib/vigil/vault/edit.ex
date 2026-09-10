defmodule Vigil.Vault.Edit do
  @moduledoc """
  What a chunk-shaped write turns a note's content into.

  The pairing with `Vigil.Vault.Policy` states the split: `Policy` decides
  *whether* a write is allowed, `Edit` produces *what* the file becomes. Both
  are pure — no process, no filesystem, no git. The caller hands this module
  the string it read from disk and gets a string back; `Edit` owns the split
  into lines and the join. How a file ends is `Vigil.Markdown`'s rule, stated
  once for every write path (docs/design.md, "How a file is written").

  The target of a splice is an `%Vigil.Index.Chunk{}` — the value `Store`
  already holds from the index. `Edit` depends on `Vigil.Index` for the
  struct; `Index` does not depend back.

  `Vigil.Vault.Policy` already guarantees a non-nil chunk
  with a non-nil heading before a splice is reached, but that guarantee lives
  in a different module. A failed write must never take the `Store` GenServer
  down, so the precondition is checked here too — an error tuple, not a raise.
  """

  alias Vigil.{Index, Markdown}
  alias Vigil.Parser.Chunk

  @type target :: {:section, Index.Chunk.t()} | {:new_section, String.t()} | :end

  @doc "The heading line stays; the body under it becomes `new_body`."
  @spec replace_body(String.t(), Index.Chunk.t() | nil, String.t()) ::
          {:ok, String.t()} | {:error, String.t()}
  def replace_body(content, chunk, new_body) do
    with :ok <- validate_chunk(chunk) do
      lines = Markdown.split_lines(content)

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
  @spec delete_section(String.t(), Index.Chunk.t() | nil) ::
          {:ok, String.t()} | {:error, String.t()}
  def delete_section(content, chunk) do
    with :ok <- validate_chunk(chunk) do
      lines = Markdown.split_lines(content)
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
    with :ok <- validate_chunk(chunk) do
      # Insert right at the chunk's end — no separator needed, since the body
      # ends at its last non-blank line and the blank line that follows it is
      # still there, after the insert point (docs/design.md, "Chunking").
      lines = Markdown.split_lines(content)
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

  defp validate_chunk(%{heading: nil}),
    do: {:error, "a section without a heading cannot be edited"}

  defp validate_chunk(_chunk), do: :ok
end
