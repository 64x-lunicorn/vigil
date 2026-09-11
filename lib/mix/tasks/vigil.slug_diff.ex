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
  """
  use Mix.Task

  @impl true
  def run(args) do
    case args do
      # The vault is this task's argument and the exclusions are the
      # environment's, read here once and handed to the walk below.
      [vault_path] ->
        diff(Path.expand(vault_path), Application.get_env(:vigil, :exclude, []))

      _ ->
        Mix.raise("Usage: mix vigil.slug_diff <vault-path>")
    end
  end

  defp diff(vault_path, exclude) do
    unless File.dir?(vault_path) do
      Mix.raise("Not a directory: #{vault_path}")
    end

    files =
      vault_path
      |> Vigil.Vault.Layout.over_vault!(exclude)
      |> Vigil.Vault.Layout.note_paths()

    differences = Vigil.Vault.Rules.slug_changes(vault_path, files)

    if differences == [] do
      Mix.shell().info(
        "No difference between legacy_slugify/1 and slugify/1 (#{length(files)} files checked)."
      )

      :ok
    else
      Mix.shell().info("#{length(differences)} difference(s) found:\n")

      Enum.each(differences, fn change ->
        {label, subject} = line(change)

        Mix.shell().info(
          "  [#{label}] #{subject}: #{inspect(change.old)} -> #{inspect(change.new)}"
        )
      end)

      exit({:shutdown, 1})
    end
  end

  # One line per difference, for a human: what it is tagged as, and what it
  # names. The walk and the facts behind it are Vigil.Vault.Rules'; what a
  # line looks like is this task's.
  defp line(%{kind: :file, path: path}), do: {"file", path}
  defp line(%{kind: :heading, path: path, heading: heading}), do: {"heading #{path}", heading}
end
