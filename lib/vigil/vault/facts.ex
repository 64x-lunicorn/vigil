defmodule Vigil.Vault.Facts do
  @moduledoc """
  Everything `Vigil.Vault.Policy` needs to know about the vault to decide one
  request. A plain struct, built fresh per call.

  Most fields are adapters rather than data, because the policy has to ask
  questions whose answers depend on the path it derives itself: a value curated
  before the policy ran is a value looked up for a path the policy had not
  decided on yet. In production `Vigil.Store` supplies closures over the
  filesystem and the index (`Vigil.Index.lookups/1` hands out the ones the
  index answers); in tests they are literals. Every adapter defaults to
  answering "nothing there", so a `Facts` built without one makes no accidental
  claims.
  """

  defstruct vault_path: "/",
            # Discovered domain directories (see Vigil.VaultDiscovery).
            domains: [],
            # VIGIL_EXCLUDE — the hard boundary.
            exclude: [],
            # Existing directory names under projects/.
            project_dirs: [],
            # domain => naming rules parsed from _domains.yml.
            naming: %{},
            # Vault-local today, for the :date naming suggestion.
            today: ~D[1970-01-01],
            path_exists?: &__MODULE__.no_such_path/1,
            read_note: &__MODULE__.no_such_note/1,
            find_similar: &__MODULE__.no_similar/2,
            # H2–H4 headings a note currently has (rewrite_note's shrink gate).
            count_headings: &__MODULE__.no_headings/1,
            # Incoming references to a note (delete_note's confirmation).
            find_backlinks: &__MODULE__.no_backlinks/1,
            # The indexed chunk a section id resolves to, or nil
            # (replace_section, delete_section). The index, not the filesystem,
            # is what says whether a section exists — and the record it hands
            # back carries the path the write uses.
            find_chunk: &__MODULE__.no_chunk/1,
            # The section in a note whose heading matches, or nil (append's
            # target decision).
            find_section: &__MODULE__.no_section/2

  @type t :: %__MODULE__{}

  @doc false
  def no_such_path(_path), do: false

  @doc false
  def no_such_note(_path), do: :error

  @doc false
  def no_similar(_query, _domain), do: []

  @doc false
  def no_headings(_path), do: 0

  @doc false
  def no_backlinks(_path), do: []

  @doc false
  def no_chunk(_id), do: nil

  @doc false
  def no_section(_path, _heading), do: nil
end
