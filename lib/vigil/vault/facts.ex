defmodule Vigil.Vault.Facts do
  @moduledoc """
  Everything `Vigil.Vault.Policy` needs to know about the vault to decide one
  request. A plain struct, built fresh per call through `new/1`.

  Most fields are adapters rather than data, because the policy has to ask
  questions whose answers depend on the path it derives itself: a value curated
  before the policy ran is a value looked up for a path the policy had not
  decided on yet.

  `Facts` earns its keep as a **purity seam**. Without it `Vigil.Vault.Policy`
  reaches into `File`, `Vigil.Index` and `Vigil.Store` directly — and since
  `Vigil.Store` is what calls the policy, a `Store → Policy → Store` cycle
  appears. With it, the policy performs no effect and can be decided in a test
  with no vault behind it.

  There is one production adapter set (`Vigil.Store` builds it, over the
  filesystem and the index) and one test builder. Neither is a default: every
  field is required, because each of these questions guards a gate and every
  "nothing there" answer sits on the permissive side of the one it feeds. A
  `count_headings` that answers `0` turns the `rewrite_note` shrink gate off;
  a `path_exists?` that answers `false` lets `:create` past its existence
  refusal; a `find_similar` that answers `[]` switches duplicate detection off.
  A field that is not supplied must therefore raise, not answer.
  """

  @enforce_keys [
    :vault_path,
    # Discovered domain directories (see Vigil.VaultDiscovery).
    :domains,
    # VIGIL_EXCLUDE — the hard boundary.
    :exclude,
    # Existing directory names under projects/.
    :project_dirs,
    # domain => naming rules parsed from _domains.yml.
    :naming,
    # Vault-local today, for the :date naming suggestion.
    :today,
    :path_exists?,
    :read_note,
    :find_similar,
    # H2–H4 headings a note currently has (rewrite_note's shrink gate).
    :count_headings,
    # Incoming references to a note (delete_note's confirmation).
    :find_backlinks,
    # The indexed chunk a section id resolves to, or nil
    # (replace_section, delete_section). The index, not the filesystem,
    # is what says whether a section exists — and the record it hands
    # back carries the path the write uses.
    :find_chunk,
    # The section in a note whose heading matches, or nil (append's
    # target decision).
    :find_section
  ]

  defstruct @enforce_keys

  @type t :: %__MODULE__{}

  @doc """
  Builds a `Facts` from an answer to every question.

  Raises `ArgumentError` when a field is missing or unknown. That is the
  point: a question added here and left unwired at a call site must stop the
  write, not open the gate it guards.
  """
  @spec new(Enumerable.t()) :: t
  def new(fields), do: struct!(__MODULE__, fields)
end
