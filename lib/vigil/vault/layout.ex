defmodule Vigil.Vault.Layout do
  @moduledoc """
  Which paths in a vault are notes — asked once, answered in one place.

  The rule used to be stated three times: the write gate decided what it would
  write to, vault discovery decided what it would load, and both of them
  separately knew that `projects/` nests one level deeper than every other
  domain. They agreed by coincidence and neither pointed at the other, so a
  second nesting domain would have been writable-but-undiscoverable, or
  discoverable-but-unwritable, depending on which of the two was edited.

  A layout is built once from the vault — its domain directories, the project
  directories inside `projects/`, and the `VIGIL_EXCLUDE` boundary — and
  answers one question, `classify/2`: is this path a note (and in which
  domain), a skill, excluded, or not a note at all. `Vigil.Vault.Policy` asks
  it before a write, and discovery asks it for every file it finds.

  What it does not answer is whether a path is *safe*. Traversal, absolute
  paths, backslashes, NUL bytes and dot- or underscore-prefixed segments belong
  to `Vigil.Slug.safe_path/1`, which every write path checks first. A layout
  describes a vault's shape, not a caller's manners.
  """

  alias Vigil.Slug

  @enforce_keys [
    # Where the vault is.
    :vault_path,
    # Its domain directories, sorted. `skills/`, dotfiles, `_`-prefixed
    # directories and anything excluded are never among them.
    :domains,
    # VIGIL_EXCLUDE — the hard boundary (docs/design.md).
    :exclude,
    # The directories that exist inside the nesting domain.
    :project_dirs
  ]

  defstruct @enforce_keys

  @type t :: %__MODULE__{}

  @typedoc """
  What a path is. `{:note, domain}` is the only answer a write may proceed on
  and the only one discovery keeps; the rest are distinct because the write
  gate answers them in different words — a path under `skills/` or an excluded
  domain is refused without naming anything, while a domain that simply is not
  there gets the list of the ones that are.
  """
  @type classification ::
          {:note, String.t()}
          | {:missing_project, String.t(), String.t()}
          | {:unknown_domain, String.t()}
          | :skill
          | :excluded
          | :not_a_note

  # `projects/` nests one level deeper than every other domain: a note lives at
  # `projects/<project>/<name>.md` there and at `<domain>/<name>.md`
  # everywhere else. This is the only statement of that rule in the project —
  # the write gate and discovery both reach it through `classify/2`.
  @nesting_domain "projects"

  defp segment_count(@nesting_domain), do: 3
  defp segment_count(_domain), do: 2

  @doc """
  The one domain that nests, and where a project directory inside it lives.

  Callers that build or read a path in the nesting domain ask rather than
  writing the name themselves: `Vigil.Store` creates the one directory a
  `create` may create, and `Vigil.Vault.Policy`'s duplicate gate tells two
  notes in the same project folder apart from two that merely share a domain.
  """
  @spec nesting_domain() :: String.t()
  def nesting_domain, do: @nesting_domain

  @doc "Where `project`'s directory lives, relative to the vault root."
  @spec project_dir(String.t()) :: Path.t()
  def project_dir(project), do: Path.join(@nesting_domain, project)

  @doc "The project a path lies in, or `nil` when it lies in none."
  @spec project_of(Path.t()) :: String.t() | nil
  def project_of(path) do
    case String.split(path, "/") do
      [@nesting_domain, project | _] -> project
      _ -> nil
    end
  end

  @doc """
  Builds a layout from what is on disk. An unreadable vault yields no domains
  rather than raising — `Vigil.Store` loads on startup, where a crash would
  cost read access to everything else.
  """
  @spec over_vault(Path.t(), [String.t()]) :: t
  def over_vault(vault_path, exclude \\ []) do
    entries =
      case File.ls(vault_path) do
        {:ok, entries} -> entries
        {:error, _} -> []
      end

    build(vault_path, entries, exclude)
  end

  @doc """
  As `over_vault/2`, but raises when the vault cannot be listed.

  For the doctor tasks, which must never hand back a clean bill of health for a
  vault they could not read.
  """
  @spec over_vault!(Path.t(), [String.t()]) :: t
  def over_vault!(vault_path, exclude \\ []) do
    build(vault_path, File.ls!(vault_path), exclude)
  end

  @doc """
  Builds a layout from stated facts rather than from a vault.

  Raises when a field is missing or unknown, the same rule
  `Vigil.Vault.Facts` and `Vigil.Git` are built under: a layout that is
  short a field must fail where it is built, not answer half a question.
  """
  @spec new(Enumerable.t()) :: t
  def new(fields), do: struct!(__MODULE__, fields)

  defp build(vault_path, entries, exclude) do
    domains =
      entries
      |> Enum.filter(fn name -> File.dir?(Path.join(vault_path, name)) end)
      |> Enum.reject(fn name ->
        name == "skills" or name in exclude or Slug.reserved_segment?(name)
      end)
      |> Enum.sort()

    new(
      vault_path: vault_path,
      domains: domains,
      exclude: exclude,
      project_dirs: project_dirs(vault_path)
    )
  end

  defp project_dirs(vault_path) do
    nesting = Path.join(vault_path, @nesting_domain)

    case File.ls(nesting) do
      {:ok, entries} -> Enum.filter(entries, &File.dir?(Path.join(nesting, &1)))
      {:error, _} -> []
    end
  end

  @doc """
  What `path` — relative to the vault root — is.

  See `t:classification/0` for the answers.
  """
  @spec classify(t, Path.t()) :: classification
  def classify(%__MODULE__{} = layout, path) do
    parts = String.split(path, "/")
    domain = hd(parts)

    cond do
      not String.ends_with?(List.last(parts), ".md") -> :not_a_note
      domain == "skills" -> :skill
      domain in layout.exclude -> :excluded
      Slug.reserved_segment?(domain) -> :not_a_note
      length(parts) != segment_count(domain) -> :not_a_note
      domain not in layout.domains -> {:unknown_domain, domain}
      domain == @nesting_domain -> project(layout, domain, Enum.at(parts, 1))
      true -> {:note, domain}
    end
  end

  defp project(layout, domain, project) do
    if project in layout.project_dirs do
      {:note, domain}
    else
      {:missing_project, domain, project}
    end
  end

  @doc """
  Every note in the vault, relative to its root and sorted by domain.

  One walk per domain, and every file it finds is put to `classify/2` — so
  what a load takes in is what the write gate would let out. Dot-prefixed
  files are not walked: they are not vault content, and the write gate refuses
  them through `Vigil.Slug.safe_path/1` rather than through the layout.
  """
  @spec note_paths(t) :: [Path.t()]
  def note_paths(%__MODULE__{} = layout) do
    Enum.flat_map(layout.domains, &domain_notes(layout, &1))
  end

  defp domain_notes(layout, domain) do
    [layout.vault_path, domain, "**", "*.md"]
    |> Path.join()
    |> Path.wildcard()
    |> Enum.map(&Path.relative_to(&1, layout.vault_path))
    |> Enum.filter(&match?({:note, ^domain}, classify(layout, &1)))
  end
end
