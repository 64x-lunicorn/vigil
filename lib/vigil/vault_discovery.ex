defmodule Vigil.VaultDiscovery do
  @moduledoc """
  What counts as a domain, and which files are notes.

  Pure file discovery over a vault path, without going through `Vigil.Store`
  (no GenServer, no `git pull`, no named-process collision with a service that
  may already be running). Shared by `Vigil.Store`, `Vigil.VaultCheck`,
  `mix vigil.slug_diff` and `mix vigil.vault_check`, so the running server and
  the doctor tasks cannot disagree about the shape of a vault.

  Two flavours, because the callers differ on what an unreadable vault means.
  `Vigil.Store` loads on startup, where a crash would cost read access to
  everything else, so it takes the forgiving pair. The doctor tasks must never
  hand back a clean bill of health for a vault they could not read, so they
  take the raising pair.
  """

  @doc """
  Top-level domain directories, sorted.

  `skills/`, dotfiles and `_`-prefixed directories are never domains, and
  neither is anything in `exclude` (`VIGIL_EXCLUDE` — see docs/design.md,
  "`VIGIL_EXCLUDE` is the hard boundary"). An unreadable vault path yields no
  domains rather than raising.
  """
  def domain_dirs(vault_path, exclude \\ []) do
    case File.ls(vault_path) do
      {:ok, entries} -> filter_domains(vault_path, entries, exclude)
      {:error, _} -> []
    end
  end

  @doc "As `domain_dirs/2`, but raises when the vault cannot be listed."
  def domain_dirs!(vault_path, exclude \\ []) do
    filter_domains(vault_path, File.ls!(vault_path), exclude)
  end

  defp filter_domains(vault_path, entries, exclude) do
    entries
    |> Enum.filter(fn name -> File.dir?(Path.join(vault_path, name)) end)
    |> Enum.reject(fn name ->
      name == "skills" or name in exclude or String.starts_with?(name, ".") or
        String.starts_with?(name, "_")
    end)
    |> Enum.sort()
  end

  @doc "All note paths relative to the vault root, sorted by domain."
  def discover_files(vault_path, exclude \\ []) do
    vault_path
    |> domain_dirs(exclude)
    |> Enum.flat_map(&domain_files(vault_path, &1))
  end

  @doc "As `discover_files/2`, but raises when the vault cannot be listed."
  def discover_files!(vault_path, exclude \\ []) do
    vault_path
    |> domain_dirs!(exclude)
    |> Enum.flat_map(&domain_files(vault_path, &1))
  end

  @doc "Note paths for one domain. `projects/` nests one level deeper than every other domain."
  def domain_files(vault_path, "projects" = domain) do
    Path.wildcard(Path.join([vault_path, domain, "*", "*.md"]))
    |> Enum.map(&Path.relative_to(&1, vault_path))
  end

  def domain_files(vault_path, domain) do
    Path.wildcard(Path.join([vault_path, domain, "*.md"]))
    |> Enum.map(&Path.relative_to(&1, vault_path))
  end
end
