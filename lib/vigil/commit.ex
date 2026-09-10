defmodule Vigil.Commit do
  @moduledoc """
  The write effect: create the directory, write the file, commit it.

  Vigil is the vault's only writer (`docs/design.md`, principle 2), and this is
  the one place that carries the write out. Notes and skills both come through
  here; what happens around it does not. `Vigil.Store` reparses the written
  file into the index between commit and push, which would be wrong for a
  skill — skills are never notes — and push stays with each caller, because the
  two push-failure messages describe different objects and legitimately differ.

  Deliberately not under `Vigil.Vault.*`. The same precedent already applies to
  `Vigil.Markdown`, which owns the trailing-newline rule precisely because
  skills need it too and must not depend on a note-shaped module.

  **A failed write never takes the server down** (`docs/design.md`, "The write
  path"). Every filesystem failure here is an error tuple carrying a sentence
  the caller can hand back, never a raise: one failed write must not cost read
  access to everything else.
  """

  alias Vigil.Git

  @doc """
  Writes `content` to `rel_path` inside `vault_path` and commits it under
  `message`, creating the parent directory if it is missing.

  Returns the commit metadata on success — the caller decides what to do
  between the commit and the push.
  """
  @spec write(String.t(), String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, String.t()}
  def write(vault_path, rel_path, content, message) do
    abs_path = Path.join(vault_path, rel_path)

    with :ok <- mkdir_p(Path.dirname(abs_path)),
         :ok <- write_file(abs_path, content) do
      case Git.add_commit(vault_path, rel_path, message) do
        {:ok, commit_meta} -> {:ok, commit_meta}
        {:error, out} -> {:error, "git commit failed: #{out}"}
      end
    end
  end

  @doc """
  Creates `path` and every missing parent, or says why it could not.

  `write/4` does this for the file's own directory. It is public for the one
  caller that creates a directory as an act of its own — `create`'s
  `create_dirs`, where a failure has to be attributable to the directory
  rather than to the file.
  """
  @spec mkdir_p(String.t()) :: :ok | {:error, String.t()}
  def mkdir_p(path) do
    case File.mkdir_p(path) do
      :ok -> :ok
      {:error, reason} -> {:error, "Could not create directory #{path}: #{fs_error(reason)}"}
    end
  end

  @doc """
  A POSIX error atom as a sentence a caller can hand back.

  Public because reads fail the same way writes do, and one wording table is
  the point.
  """
  @spec fs_error(atom()) :: String.t()
  def fs_error(:eacces), do: "no write permission"
  def fs_error(:enospc), do: "out of disk space"
  def fs_error(:eisdir), do: "target path is a directory"
  def fs_error(:enotdir), do: "a path component is not a directory"
  def fs_error(:erofs), do: "filesystem is read-only"
  def fs_error(reason), do: inspect(reason)

  defp write_file(path, content) do
    case File.write(path, content) do
      :ok -> :ok
      {:error, reason} -> {:error, "Could not write file #{path}: #{fs_error(reason)}"}
    end
  end
end
