defmodule Vigil.Commit do
  @moduledoc """
  The write effect: what it takes to make a change to the vault.

  Write a file, delete one, move one, create a directory, push — and the
  wording for a POSIX error. Vigil is the vault's only writer (`docs/design.md`,
  principle 2), and this is the one place that carries a change out. Notes and
  skills both come through here.

  What happens *around* the effect does not. `Vigil.Store` sequences it —
  perform, commit, reparse into the index, push — and that order is stated
  where a plan is executed, not here. The reparse would be wrong for a skill,
  since skills are never notes, and each caller renders its own push failure,
  because the messages name different objects: a change, a deletion, a move, a
  skill.

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

  `git` is the adapter its caller holds (`docs/design.md`, "Git is reached
  through a value") — this module touches the filesystem itself and asks that
  value for the commit.

  Returns the commit metadata on success — the caller decides what to do
  between the commit and the push.
  """
  @spec write(Git.t(), String.t(), String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, String.t()}
  def write(%Git{} = git, vault_path, rel_path, content, message) do
    abs_path = Path.join(vault_path, rel_path)

    with :ok <- mkdir_p(Path.dirname(abs_path)),
         :ok <- write_file(abs_path, content) do
      case git.add_commit.(vault_path, rel_path, message) do
        {:ok, commit_meta} -> {:ok, commit_meta}
        {:error, out} -> {:error, "git commit failed: #{out}"}
      end
    end
  end

  @doc """
  Removes `rel_path` from the vault and commits the removal under `message`.

  Nothing comes back but the verdict: the file is gone, so there is no note to
  reparse and no metadata a caller could put on one.
  """
  @spec delete(Git.t(), String.t(), String.t(), String.t()) :: :ok | {:error, String.t()}
  def delete(%Git{} = git, vault_path, rel_path, message) do
    case git.remove_commit.(vault_path, rel_path, message) do
      :ok -> :ok
      {:error, out} -> {:error, "git rm/commit failed: #{out}"}
    end
  end

  @doc """
  Moves `from` to `to` inside the vault and commits both paths under `message`.

  Returns the commit metadata for the note at its new path.
  """
  @spec move(Git.t(), String.t(), String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, String.t()}
  def move(%Git{} = git, vault_path, from, to, message) do
    case git.move_commit.(vault_path, from, to, message) do
      {:ok, commit_meta} -> {:ok, commit_meta}
      {:error, out} -> {:error, "git mv/commit failed: #{out}"}
    end
  end

  @doc """
  Pushes the vault's commits to `remote`.

  The failure comes back as git wrote it, unwrapped: what was committed
  locally but not pushed is a change, a deletion, a move or a skill, and the
  caller is the one that knows which — so the sentence in front of it is the
  caller's (`docs/design.md`, "The write path").
  """
  @spec push(Git.t(), String.t(), String.t()) :: :ok | {:error, String.t()}
  def push(%Git{} = git, vault_path, remote), do: git.push.(vault_path, remote)

  @doc """
  Creates `path` and every missing parent, or says why it could not.

  `write/5` does this for the file's own directory. It is public for the one
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
