defmodule Vigil.Vault.Plan do
  @moduledoc """
  What a write turns into before anything happens: the action to perform and
  the commit message to perform it under.

  The third pure module of the write path, and the one that ties the other two
  together. `Vigil.Vault.Policy` decides *whether* a write is allowed and what
  it resolves to; `Vigil.Vault.Edit` produces *what* a chunk-shaped edit turns
  a note's content into; `Plan` turns a resolved decision plus the note's
  current content into the whole write. All eight write operations go through
  it.

  Three actions, because there are three shapes of write:

    * `{:write, path, content}` — the six content-shaped operations, which
      differ only in the bytes they produce.
    * `{:delete, path}` and `{:move, from, to}` — the two git-level
      operations, which produce no content at all.

  A plan performs no effect: it reads no file, touches no git, and knows
  nothing about `Vigil.Store`'s state. `Vigil.Store` reads the note, hands the
  content over, and executes what comes back — perform the action, commit,
  reparse into the index, then push (`docs/design.md`, "The write path"). That
  order used to be restated at every write site; the plan is what let it be
  stated once.

  A plan's `report` carries what only this operation knows about its own
  result — `path_normalized_from` on a create whose path was normalized, the
  backlinks a delete is about to break — merged into the success map by
  whoever executes it. What only the *effect* knows stays with the executor.
  """

  alias Vigil.{Markdown, Vault.Decision, Vault.Edit}

  @enforce_keys [:action, :message]
  defstruct [:action, :message, report: %{}]

  @type action ::
          {:write, String.t(), String.t()}
          | {:delete, String.t()}
          | {:move, String.t(), String.t()}

  @type t :: %__MODULE__{
          action: action,
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
          | :delete_note
          | :move_note

  @doc """
  Builds the plan for `op` from the policy's `decision`, the caller's
  `request`, and `current` — the note's content as it stands on disk, or `nil`
  for the operations that do not read it: `:create`, which has no current
  content by definition, and the two git-level ones, which never look at it.

  Each clause matches the `Vigil.Vault.Decision` shape its operation is
  decided in, rather than reaching into the keys it hopes are there: an
  operation paired with a decision that cannot answer for it fails here, on
  the clause, and not as a `KeyError` several frames into the writer.

  Returns `{:ok, plan}`, or `{:error, message}` when the content cannot be
  shaped: an edit whose chunk is gone, a note whose frontmatter block never
  closes, or a rewrite of a note that has no block to preserve. Each is the
  caller's message to hand back verbatim.
  """
  @spec build(op, Decision.t(), map, String.t() | nil) :: {:ok, t} | {:error, String.t()}
  def build(op, decision, request, current)

  def build(:create, %Decision.Create{} = resolved, request, _current) do
    content = Map.fetch!(request, :content)
    frontmatter = frontmatter(resolved.type, resolved.starts, resolved.ends)

    {:ok,
     %__MODULE__{
       action:
         {:write, resolved.path, Markdown.normalize_trailing_newline(frontmatter <> content)},
       message: "create: #{resolved.path} — #{first_line(content)}",
       report: normalized_from(resolved.normalized_from)
     }}
  end

  def build(:append, %Decision.Append{} = resolved, request, current) do
    content = Map.fetch!(request, :content)

    with {:ok, new_content} <- Edit.append(current, resolved.target, content) do
      {:ok, plan(resolved.path, new_content, "append: #{resolved.path} — #{first_line(content)}")}
    end
  end

  def build(:replace_section, %Decision.Section{} = resolved, request, current) do
    chunk = resolved.chunk

    with {:ok, new_content} <- Edit.replace_body(current, chunk, Map.fetch!(request, :content)) do
      {:ok, plan(resolved.path, new_content, "replace_section: #{chunk.id}")}
    end
  end

  def build(:delete_section, %Decision.Section{} = resolved, _request, current) do
    chunk = resolved.chunk

    with {:ok, new_content} <- Edit.delete_section(current, chunk) do
      {:ok, plan(resolved.path, new_content, "delete_section: #{chunk.id}")}
    end
  end

  # The frontmatter block is the half of the file a rewrite never touches, and
  # the body is the half update_frontmatter never touches. Both are the same
  # split, from opposite sides.
  #
  # The split does not end there when the note has no block. A rewrite has no
  # type to write and preserves the block it finds, so it has nothing to
  # preserve and refuses, naming the tool that can give the note one.
  def build(:rewrite_note, %Decision.RewriteNote{} = resolved, request, current) do
    case Markdown.split_frontmatter(current) do
      {:ok, frontmatter, _old_body} ->
        content = frontmatter <> Map.fetch!(request, :content)

        {:ok,
         plan(
           resolved.path,
           Markdown.normalize_trailing_newline(content),
           "rewrite_note: #{resolved.path}"
         )}

      :none ->
        {:error,
         "#{resolved.path} has no frontmatter, and rewrite_note preserves the frontmatter it finds. " <>
           "Give the note one with update_frontmatter first."}

      :unterminated ->
        unterminated(resolved.path)
    end
  end

  # With no block, the whole note is the body, and the block it lacks goes in
  # front of it. That is an explicit call to write frontmatter, not the server
  # repairing a note on its own initiative (docs/design.md, "Frontmatter —
  # exactly one required field").
  def build(:update_frontmatter, %Decision.UpdateFrontmatter{} = resolved, _request, current) do
    case Markdown.split_frontmatter(current) do
      {:ok, _old_frontmatter, body} -> {:ok, frontmatter_plan(resolved, body)}
      :none -> {:ok, frontmatter_plan(resolved, current)}
      :unterminated -> unterminated(resolved.path)
    end
  end

  # The backlinks are the policy's answer, looked up before anything is
  # deleted — after the effect there is nothing left to ask about.
  def build(:delete_note, %Decision.DeleteNote{} = resolved, _request, _current) do
    {:ok,
     %__MODULE__{
       action: {:delete, resolved.path},
       message: "delete: #{resolved.path}",
       report: %{broken_backlinks: resolved.backlinks}
     }}
  end

  # Which references the move actually broke is a diff across the effect, so
  # it belongs to whoever performs it, not here.
  def build(:move_note, %Decision.MoveNote{} = resolved, _request, _current) do
    {:ok,
     %__MODULE__{
       action: {:move, resolved.from, resolved.to},
       message: "move: #{resolved.from} -> #{resolved.to}"
     }}
  end

  defp frontmatter_plan(resolved, body) do
    content = frontmatter(resolved.type, resolved.starts, resolved.ends) <> body

    plan(
      resolved.path,
      Markdown.normalize_trailing_newline(content),
      "update_frontmatter: #{resolved.path}"
    )
  end

  # A block left open is not a note without one: where it ends, and so where
  # the body starts, is not something the file says. Neither whole-file write
  # guesses.
  defp unterminated(path) do
    {:error,
     "Unterminated frontmatter in #{path}: the block opened by its first line never closes " <>
       "with ---, so where the body starts is unknown."}
  end

  defp plan(path, content, message) do
    %__MODULE__{action: {:write, path, content}, message: message}
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
