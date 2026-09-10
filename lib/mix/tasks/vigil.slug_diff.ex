defmodule Mix.Tasks.Vigil.SlugDiff do
  @shortdoc "Compares legacy_slugify/1 against slugify/1 across a vault (migration check)"
  @moduledoc """
  Run this against a real vault before deploying a change to the slug logic.

  It shows every file and every heading whose chunk id or filename would change
  when moving from `Vigil.Slug.legacy_slugify/1` to `Vigil.Slug.slugify/1` —
  in other words, every existing `[[…]]` reference and stored chunk id that
  would break.

      mix vigil.slug_diff /path/to/vault

  Exit 0 on an empty diff, exit 1 when there are differences, so it can be used
  from a script.

  The vault to check is this task's argument, but the domains excluded from
  the diff come from the `:vigil, :exclude` application config
  (`VIGIL_EXCLUDE`) — the environment's exclusions, not necessarily the
  target vault's. In practice this task always runs against the vault that
  is (or is about to become) *the* configured vault, with the matching
  environment, so the two never drift apart.
  """
  use Mix.Task

  @impl true
  def run(args) do
    case args do
      [vault_path] -> diff(Path.expand(vault_path))
      _ -> Mix.raise("Usage: mix vigil.slug_diff <vault-path>")
    end
  end

  defp diff(vault_path) do
    unless File.dir?(vault_path) do
      Mix.raise("Not a directory: #{vault_path}")
    end

    files =
      Vigil.VaultDiscovery.discover_files!(vault_path, Application.get_env(:vigil, :exclude, []))

    differences = Enum.flat_map(files, &file_differences(vault_path, &1))

    if differences == [] do
      Mix.shell().info(
        "No difference between legacy_slugify/1 and slugify/1 (#{length(files)} files checked)."
      )

      :ok
    else
      Mix.shell().info("#{length(differences)} difference(s) found:\n")

      Enum.each(differences, fn {kind, path, old, new} ->
        Mix.shell().info("  [#{kind}] #{path}: #{inspect(old)} -> #{inspect(new)}")
      end)

      exit({:shutdown, 1})
    end
  end

  defp file_differences(vault_path, rel_path) do
    file_diff =
      case Vigil.Vault.Rules.filename_slug_change(rel_path) do
        nil -> []
        %{old: old, new: nil} -> [{"file", rel_path, old, :error}]
        %{old: old, new: new} -> [{"file", rel_path, old, new}]
      end

    heading_diffs =
      case File.read(Path.join(vault_path, rel_path)) do
        {:ok, content} -> heading_differences(rel_path, content)
        {:error, _} -> []
      end

    file_diff ++ heading_diffs
  end

  defp heading_differences(rel_path, content) do
    content
    |> Vigil.Vault.Rules.heading_slug_changes()
    |> Enum.map(fn
      %{text: text, old: old, new: nil} -> {"heading #{rel_path}", text, old, :error}
      %{text: text, old: old, new: new} -> {"heading #{rel_path}", text, old, new}
    end)
  end
end
