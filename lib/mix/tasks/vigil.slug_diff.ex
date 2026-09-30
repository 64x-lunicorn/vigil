defmodule Mix.Tasks.Vigil.SlugDiff do
  @shortdoc "Shows which chunk ids a slug change would move across a vault (migration check)"
  @moduledoc """
  Run this against a real vault before deploying a change to the slug logic.

  It shows every file and every heading whose chunk id or filename would change
  when moving from `Vigil.Slug.legacy_slugify/1` to `Vigil.Slug.slugify/1` —
  in other words, every existing `[[…]]` reference and stored chunk id that
  would break.

      mix vigil.slug_diff /path/to/vault

  Exit 0 on an empty diff, exit 1 when there are differences, so it can be used
  from a script.

      mix vigil.slug_diff --against <ids-file> /path/to/vault

  compares the chunk ids this build derives from the vault with the list in
  `<ids-file>`, one id per line — what another build said about the same
  vault (`Vigil.Release.chunk_ids/0`). Every id only one side has is listed,
  `-` for one this build no longer derives and `+` for one it derives new.
  Same exit codes. `update.sh` runs it before switching releases and asks
  before a switch that would move an id (docs/compatibility.md).

  Both modes walk the vault with the exclusions `VIGIL_EXCLUDE` names.
  """
  use Mix.Task

  @impl true
  def run(args) do
    # config/runtime.exs is where VIGIL_EXCLUDE becomes the exclusion list, and
    # a Mix task does not evaluate it unless asked: without this the task
    # walked excluded directories on every real run.
    Mix.Task.run("app.config")
    Vigil.Stdio.utf8()

    case args do
      # The vault is this task's argument and the exclusions are the
      # environment's, read here once and handed to the walk below.
      [vault_path] ->
        diff(Path.expand(vault_path), Application.get_env(:vigil, :exclude, []))

      ["--against", ids_file, vault_path] ->
        against(ids_file, Path.expand(vault_path), Application.get_env(:vigil, :exclude, []))

      _ ->
        Mix.raise(
          "Usage: mix vigil.slug_diff <vault-path>\n" <>
            "       mix vigil.slug_diff --against <ids-file> <vault-path>"
        )
    end
  end

  defp against(ids_file, vault_path, exclude) do
    unless File.dir?(vault_path) do
      Mix.raise("Not a directory: #{vault_path}")
    end

    before =
      case File.read(ids_file) do
        {:ok, text} -> text |> String.split("\n", trim: true) |> MapSet.new()
        {:error, reason} -> Mix.raise("Cannot read #{ids_file}: #{:file.format_error(reason)}")
      end

    files =
      vault_path
      |> Vigil.Vault.Layout.over_vault!(exclude)
      |> Vigil.Vault.Layout.note_paths()

    now = vault_path |> Vigil.Vault.Rules.chunk_ids(files) |> MapSet.new()

    gone = before |> MapSet.difference(now) |> Enum.sort()
    new = now |> MapSet.difference(before) |> Enum.sort()

    if gone == [] and new == [] do
      Mix.shell().info("No chunk id changes (#{MapSet.size(now)} ids compared).")
      :ok
    else
      Mix.shell().info("#{length(gone) + length(new)} chunk id change(s):\n")
      Enum.each(gone, &Mix.shell().info("  - #{&1}"))
      Enum.each(new, &Mix.shell().info("  + #{&1}"))
      exit({:shutdown, 1})
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
