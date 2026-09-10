defmodule Vigil.Vault.Decision do
  @moduledoc """
  What the write gate answers with: one struct per write shape, each enforcing
  every field its operation needs.

  The counterpart to `Vigil.Vault.Facts`, which enforces the *questions*. A
  question added there and left unwired stops the write at construction rather
  than quietly opening the gate it guards; a decision that cannot answer what
  its operation needs now fails the same way, where the mistake is.

  Before this the answer was a bare map of six different shapes and
  `Vigil.Vault.Plan` reached into whichever keys it expected, unchecked. The
  failure mode that leaves is the one `docs/design.md` rules out under "The
  write path": a missing key raised a `KeyError` inside `Plan.build/4`, inside
  `Vigil.Store`'s write sequence, inside `handle_call` — taking down the
  single writer, in a module that converts every filesystem failure into an
  error tuple precisely so that a failed write never takes the server down.

  `:replace_section` and `:delete_section` share `Section`: the decision is
  the same one, and what differs is what the plan does with it.
  """

  alias Vigil.{Index, Vault.Edit}

  defmodule Create do
    @moduledoc "A note to write where none is: where it lands, and as what."
    @enforce_keys [:path, :normalized_from, :create_project_dir, :type, :starts, :ends]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            path: String.t(),
            normalized_from: String.t() | nil,
            create_project_dir: String.t() | nil,
            type: atom(),
            starts: DateTime.t() | nil,
            ends: DateTime.t() | nil
          }
  end

  defmodule Append do
    @moduledoc "Content to add to a note, and the resolved target it lands on."
    @enforce_keys [:path, :target]
    defstruct @enforce_keys

    @type t :: %__MODULE__{path: String.t(), target: Edit.target()}
  end

  defmodule Section do
    @moduledoc "One section of a note, as the index resolved it."
    @enforce_keys [:path, :chunk]
    defstruct @enforce_keys

    @type t :: %__MODULE__{path: String.t(), chunk: Index.Chunk.t()}
  end

  defmodule RewriteNote do
    @moduledoc "A note's whole body, replaced. Nothing but the note it happens to."
    @enforce_keys [:path]
    defstruct @enforce_keys

    @type t :: %__MODULE__{path: String.t()}
  end

  defmodule UpdateFrontmatter do
    @moduledoc "A note's frontmatter block, replaced by the type it now claims."
    @enforce_keys [:path, :type, :starts, :ends]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            path: String.t(),
            type: atom(),
            starts: DateTime.t() | nil,
            ends: DateTime.t() | nil
          }
  end

  defmodule DeleteNote do
    @moduledoc """
    A note to remove, with the references it is about to break — looked up
    before the effect, because afterwards there is nothing left to ask about.
    """
    @enforce_keys [:path, :backlinks]
    defstruct @enforce_keys

    @type t :: %__MODULE__{path: String.t(), backlinks: [String.t()]}
  end

  defmodule MoveNote do
    @moduledoc "A note to move, from one path in the vault to another."
    @enforce_keys [:from, :to]
    defstruct @enforce_keys

    @type t :: %__MODULE__{from: String.t(), to: String.t()}
  end

  @type t ::
          Create.t()
          | Append.t()
          | Section.t()
          | RewriteNote.t()
          | UpdateFrontmatter.t()
          | DeleteNote.t()
          | MoveNote.t()
end
