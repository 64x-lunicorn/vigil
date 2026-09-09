defmodule Vigil.Vault.Edit do
  @moduledoc """
  What a chunk-shaped write turns a note's content into.

  The pairing with `Vigil.Vault.Policy` states the split: `Policy` decides
  *whether* a write is allowed, `Edit` produces *what* the file becomes. Both
  are pure — no process, no filesystem, no git. The caller hands this module
  the string it read from disk and gets a string back; `Edit` owns the split
  into lines, the join, and the trailing newline.

  The target of a splice is an `%Vigil.Index.Chunk{}` — the value `Store`
  already holds from the index. `Edit` depends on `Vigil.Index` for the
  struct; `Index` does not depend back.

  `Vigil.Vault.Policy.section_present/3` already guarantees a non-nil chunk
  with a non-nil heading before a splice is reached, but that guarantee lives
  in a different module. A failed write must never take the `Store` GenServer
  down, so the precondition is checked here too — an error tuple, not a raise.
  """

  alias Vigil.{Index, Markdown}

  @type target :: {:section, Index.Chunk.t()} | {:new_section, String.t()} | :end

  @doc "The heading line stays; the body under it becomes `new_body`."
  @spec replace_body(String.t(), Index.Chunk.t() | nil, String.t()) ::
          {:ok, String.t()} | {:error, String.t()}
  def replace_body(content, chunk, new_body) do
    with :ok <- validate_chunk(chunk) do
      splice(content, chunk.heading_line, chunk.body_end_line, Markdown.split_lines(new_body))
    end
  end

  @doc "The heading goes with the body it heads."
  @spec delete_section(String.t(), Index.Chunk.t() | nil) ::
          {:ok, String.t()} | {:error, String.t()}
  def delete_section(content, chunk) do
    with :ok <- validate_chunk(chunk) do
      splice(content, chunk.heading_line - 1, chunk.body_end_line, [])
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
      # Insert right at the chunk's end — no separator, since the chunk's
      # body already carries the blank line before whatever follows it
      # (docs/design.md, "Chunking").
      splice(
        content,
        chunk.body_end_line,
        chunk.body_end_line,
        Markdown.split_lines(new_content)
      )
    end
  end

  def append(content, {:new_section, heading}, new_content) do
    lines = Markdown.split_lines(content)
    {:ok, join(lines ++ ["", "## #{heading}"] ++ Markdown.split_lines(new_content))}
  end

  def append(content, :end, new_content) do
    lines = Markdown.split_lines(content)
    {:ok, join(lines ++ [""] ++ Markdown.split_lines(new_content))}
  end

  # Rewrites the file around one chunk: every line before `keep_lines`, then
  # `replacement`, then everything from the chunk's `body_end_line` onwards.
  defp splice(content, keep_lines, body_end_line, replacement) do
    lines = Markdown.split_lines(content)
    prefix = Enum.slice(lines, 0, keep_lines)
    suffix = Enum.slice(lines, body_end_line, length(lines) - body_end_line)

    {:ok, join(prefix ++ replacement ++ suffix)}
  end

  defp join(lines), do: Enum.join(lines, "\n") <> "\n"

  defp validate_chunk(nil), do: {:error, "no such section"}

  defp validate_chunk(%{heading: nil}),
    do: {:error, "a section without a heading cannot be edited"}

  defp validate_chunk(_chunk), do: :ok
end
