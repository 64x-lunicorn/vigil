defmodule Vigil.VaultDiscovery do
  @moduledoc """
  Pure file discovery over a vault path, without going through `Vigil.Store`
  (no GenServer, no `git pull`, no named-process collision with a service that
  may already be running). Shared by `mix vigil.slug_diff` and
  `mix vigil.vault_check`.
  """

  @doc "Top-level domain directories (skills, dotfiles and `_`-prefixed excluded)."
  def domain_dirs(vault_path) do
    vault_path
    |> File.ls!()
    |> Enum.filter(&File.dir?(Path.join(vault_path, &1)))
    |> Enum.reject(fn name ->
      name == "skills" or String.starts_with?(name, ".") or String.starts_with?(name, "_")
    end)
  end

  @doc "All note paths relative to the vault root (special case: `projects/*/*.md`)."
  def discover_files(vault_path) do
    vault_path
    |> domain_dirs()
    |> Enum.flat_map(fn
      "projects" = domain ->
        Path.wildcard(Path.join([vault_path, domain, "*", "*.md"]))
        |> Enum.map(&Path.relative_to(&1, vault_path))

      domain ->
        Path.wildcard(Path.join([vault_path, domain, "*.md"]))
        |> Enum.map(&Path.relative_to(&1, vault_path))
    end)
  end
end
