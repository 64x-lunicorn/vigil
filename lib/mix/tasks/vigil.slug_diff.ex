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

  @h1_re ~r/^\#\s+(.+?)\s*$/
  @heading_re ~r/^(\#{2,4})\s+(.+?)\s*$/

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

    files = discover_files(vault_path)
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
    basename = Path.basename(rel_path, ".md")

    file_diff =
      case {Vigil.Slug.legacy_slugify(basename), Vigil.Slug.slugify(basename)} do
        {old, {:ok, new}} when old != new -> [{"file", rel_path, old, new}]
        {old, {:error, _}} -> [{"file", rel_path, old, :error}]
        _ -> []
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
    |> String.split("\n")
    |> Enum.filter(fn line ->
      Regex.match?(@heading_re, line) and not Regex.match?(@h1_re, line)
    end)
    |> Enum.flat_map(fn line ->
      [_, _, text] = Regex.run(@heading_re, line)
      text = String.trim(text)

      case {Vigil.Slug.legacy_slugify(text), Vigil.Slug.slugify(text)} do
        {old, {:ok, new}} when old != new -> [{"heading #{rel_path}", text, old, new}]
        {old, {:error, _}} -> [{"heading #{rel_path}", text, old, :error}]
        _ -> []
      end
    end)
  end

  defp discover_files(vault_path), do: Vigil.VaultDiscovery.discover_files(vault_path)
end
