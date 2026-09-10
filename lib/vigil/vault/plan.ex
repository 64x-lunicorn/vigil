defmodule Vigil.Vault.Plan do
  @moduledoc """
  What a write turns into before anything happens: the file to write, the
  bytes to write into it, and the commit message to write them under.

  The third pure module of the write path, and the one that ties the other two
  together. `Vigil.Vault.Policy` decides *whether* a write is allowed and what
  it resolves to; `Vigil.Vault.Edit` produces *what* a chunk-shaped edit turns
  a note's content into; `Plan` turns a resolved decision plus the note's
  current content into the whole write, for every content-shaped operation.

  It performs no effect: it reads no file, touches no git, and knows nothing
  about `Vigil.Store`'s state. `Vigil.Store` reads the note, hands the content
  over, and executes what comes back — write the file, commit, reparse into
  the index, then push (`docs/design.md`, "The write path"). That order used
  to be restated at every write site; the plan is what let it be stated once.

  A plan's `report` carries what only this operation knows about its own
  result — `path_normalized_from` on a create whose path was normalized —
  merged into the write's success map by whoever executes it.
  """

  alias Vigil.{Markdown, Vault.Edit}

  @enforce_keys [:path, :content, :message]
  defstruct [:path, :content, :message, report: %{}]

  @type t :: %__MODULE__{
          path: String.t(),
          content: String.t(),
          message: String.t(),
          report: map()
        }

  @type op ::
          :create
          | :append
          | :replace_section
          | :rewrite_note
          | :delete_section
          | :update_frontmatter

  @doc """
  Builds the plan for `op` from the policy's `resolved` decision, the caller's
  `request`, and `current` — the note's content as it stands on disk, or `nil`
  for `:create`, which has no current content by definition.

  Returns `{:ok, plan}`, or `{:error, message}` when the content cannot be
  shaped: an edit whose chunk is gone, or a note whose frontmatter block is
  unparsable. Both are the caller's message to hand back verbatim.
  """
  @spec build(op, map, map, String.t() | nil) :: {:ok, t} | {:error, String.t()}
  def build(op, resolved, request, current)

  def build(:create, resolved, request, _current) do
    content = Map.fetch!(request, :content)
    frontmatter = frontmatter(resolved.type, resolved.starts, resolved.ends)

    {:ok,
     %__MODULE__{
       path: resolved.path,
       content: Markdown.normalize_trailing_newline(frontmatter <> content),
       message: "create: #{resolved.path} — #{first_line(content)}",
       report: normalized_from(resolved.normalized_from)
     }}
  end

  def build(:append, resolved, request, current) do
    content = Map.fetch!(request, :content)

    with {:ok, new_content} <- Edit.append(current, resolved.target, content) do
      {:ok, plan(resolved.path, new_content, "append: #{resolved.path} — #{first_line(content)}")}
    end
  end

  def build(:replace_section, resolved, request, current) do
    chunk = resolved.chunk

    with {:ok, new_content} <- Edit.replace_body(current, chunk, Map.fetch!(request, :content)) do
      {:ok, plan(resolved.path, new_content, "replace_section: #{chunk.id}")}
    end
  end

  def build(:delete_section, resolved, _request, current) do
    chunk = resolved.chunk

    with {:ok, new_content} <- Edit.delete_section(current, chunk) do
      {:ok, plan(resolved.path, new_content, "delete_section: #{chunk.id}")}
    end
  end

  # The frontmatter block is the half of the file a rewrite never touches, and
  # the body is the half update_frontmatter never touches. Both are the same
  # split, from opposite sides.
  def build(:rewrite_note, resolved, request, current) do
    with {:ok, frontmatter, _old_body} <- Markdown.split_frontmatter(current) do
      content = frontmatter <> Map.fetch!(request, :content)

      {:ok,
       plan(
         resolved.path,
         Markdown.normalize_trailing_newline(content),
         "rewrite_note: #{resolved.path}"
       )}
    end
  end

  def build(:update_frontmatter, resolved, _request, current) do
    with {:ok, _old_frontmatter, body} <- Markdown.split_frontmatter(current) do
      content = frontmatter(resolved.type, resolved.starts, resolved.ends) <> body

      {:ok,
       plan(
         resolved.path,
         Markdown.normalize_trailing_newline(content),
         "update_frontmatter: #{resolved.path}"
       )}
    end
  end

  defp plan(path, content, message) do
    %__MODULE__{path: path, content: content, message: message}
  end

  defp normalized_from(nil), do: %{}
  defp normalized_from(from), do: %{path_normalized_from: from}

  defp frontmatter(type, starts, ends) do
    lines = ["---", "type: #{type}"]

    lines =
      if type == :event do
        lines ++ ["starts: #{DateTime.to_iso8601(starts)}", "ends: #{DateTime.to_iso8601(ends)}"]
      else
        lines
      end

    Enum.join(lines ++ ["---", ""], "\n")
  end

  # What the commit message quotes back: the first line with anything on it,
  # capped so a commit subject stays a subject.
  defp first_line(content) do
    content
    |> String.split("\n")
    |> Enum.find(&(String.trim(&1) != ""))
    |> to_string()
    |> String.slice(0, 50)
  end
end
