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

  There are two adapter sets and both are named here: `over_vault/2` answers
  over the vault's filesystem and its index, and `Vigil.Vault.AbsentFacts`
  answers "nothing there" to everything. Building the production one is a pure
  function of an index and the vault's plain facts, so what it claims is
  checkable without a git repository or a running writer — it used to be a
  private closure inside `Vigil.Store`'s `GenServer`, reachable only by
  performing a real write. Neither set is a default: every field is required,
  because each of these questions guards a gate and every
  "nothing there" answer sits on the permissive side of the one it feeds. A
  `count_headings` that answers `0` turns the `rewrite_note` shrink gate off;
  a `path_exists?` that answers `false` lets `:create` past its existence
  refusal; a `find_similar` that answers `[]` switches duplicate detection off.
  A field that is not supplied must therefore raise, not answer.
  """

  alias Vigil.Index
  alias Vigil.Vault.Layout

  @enforce_keys [
    # Which paths in this vault are notes (see Vigil.Vault.Layout). One value,
    # asked one question — the domains, the exclude boundary and the project
    # directories are what it was built from, not three facts of their own.
    :layout,
    # domain => naming rules parsed from _domains.yml.
    :naming,
    # Vault-local today, for the :date naming suggestion.
    :today,
    :path_exists?,
    :read_note,
    # Notes in `domain` matching a term, best first, as deep as the caller
    # asks (:create's duplicate gate). The gate's terms, depth and threshold
    # are stated together in `Vigil.Vault.Policy`, so the depth arrives with
    # the question rather than being chosen by whoever answers it.
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

  @typedoc """
  The vault's plain facts, as the caller gathered them: its layout — which
  paths in it are notes, and where on disk it is — and what `_domains.yml`
  says about naming. Everything here is a fact about the vault; the instant
  the write belongs to is not one, and travels beside it.
  """
  @type vault :: %{
          layout: Layout.t(),
          naming: %{optional(String.t()) => map}
        }

  @doc """
  The production answer set: `vault`'s plain facts as they were gathered, and
  an adapter per question over `index` and the vault's filesystem.

  Pure — it performs no effect, it builds the functions that will. `vault` is
  matched rather than fetched from, so a caller that has not gathered one of
  the plain facts fails in its own process on the head, the way a broken
  contract does everywhere else here (docs/design.md, "The write path").

  `now` is the instant the write's own response's envelope was decided at
  (`Vigil.MCP.Envelope.for_tool/2`) and `today` is that instant's own date, in
  that instant's own zone. It is derived from what was handed in rather than
  read from a clock here — see docs/design.md, "The write path", for what a
  second clock read behind the writer cost.
  """
  @spec over_vault(Index.t(), vault, DateTime.t()) :: t
  def over_vault(
        %Index{} = index,
        %{layout: %Layout{vault_path: vault_path} = layout, naming: naming},
        %DateTime{} = now
      ) do
    new(
      layout: layout,
      naming: naming,
      today: DateTime.to_date(now),
      path_exists?: fn path -> File.exists?(Path.join(vault_path, path)) end,
      read_note: fn path -> File.read(Path.join(vault_path, path)) end,
      find_backlinks: fn path -> Index.backlinks(index, path) end,
      # The depth comes from the policy, which is where the duplicate gate's
      # sensitivity is stated — terms, depth and threshold together. An adapter
      # that chose its own would be a third module deciding how sensitive the
      # gate is. No `prefer`, and deliberately: the policy's threshold is
      # `Index.strength(:title)`, which means "the query names this note" only
      # for a search with no preferred type.
      find_similar: fn query, domain, depth ->
        Index.search(index, %{query: query, domain: domain, limit: depth})
      end,
      count_headings: fn path -> Index.count_headings(index, path) end,
      find_chunk: fn id -> Index.find_chunk(index, id) end,
      find_section: fn path, heading -> Index.find_section(index, path, heading) end
    )
  end
end
