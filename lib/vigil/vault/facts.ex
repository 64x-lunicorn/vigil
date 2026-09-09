defmodule Vigil.Vault.Facts do
  @moduledoc """
  Everything `Vigil.Vault.Policy` needs to know about the vault to decide one
  request. A plain struct, built fresh per call.

  Three fields are adapters rather than data, because the policy has to ask
  questions whose answers depend on the path it derives itself: `path_exists?`,
  `read_note` and `find_similar`. In production `Vigil.Store` supplies closures
  over the filesystem and the ETS index; in tests they are literals. All three
  default to answering "nothing there", so a `Facts` built without them makes
  no accidental claims.
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
            # H2–H4 headings the target note currently has (rewrite_note).
            heading_count: 0,
            # Incoming references to the target note (delete_note).
            backlinks: [],
            # The indexed chunk a section id resolves to, or nil
            # (replace_section, delete_section). The index, not the
            # filesystem, is what says whether a section exists.
            chunk: nil,
            path_exists?: &__MODULE__.no_such_path/1,
            read_note: &__MODULE__.no_such_note/1,
            find_similar: &__MODULE__.no_similar/2

  @type t :: %__MODULE__{}

  @doc false
  def no_such_path(_path), do: false

  @doc false
  def no_such_note(_path), do: :error

  @doc false
  def no_similar(_query, _domain), do: []
end
