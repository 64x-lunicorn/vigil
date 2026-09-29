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

  require Logger

  alias Vigil.Git

  @doc """
  Writes `content` to `rel_path` inside `vault_path` and commits it under
  `message`, creating the parent directory if it is missing.

  `git` is the adapter its caller holds (`docs/design.md`, "Git is reached
  through a value") — this module touches the filesystem itself and asks that
  value for the staging and the commit.

  Returns the commit metadata on success — the caller decides what to do
  between the commit and the push. On failure the vault is left as it was.
  """
  @spec write(Git.t(), String.t(), String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, String.t()}
  def write(%Git{} = git, vault_path, rel_path, content, message) do
    abs_path = Path.join(vault_path, rel_path)
    prefix = "git commit failed"

    change(git, vault_path, [rel_path], message, prefix, fn ->
      with :ok <- mkdir_p(Path.dirname(abs_path)),
           :ok <- write_file(abs_path, content) do
        git_step(git.add.(vault_path, [rel_path]), prefix)
      end
    end)
  end

  @doc """
  Removes `rel_path` from the vault and commits the removal under `message`.

  Nothing comes back but the verdict: the file is gone, so there is no note to
  reparse and no metadata a caller could put on one.
  """
  @spec delete(Git.t(), String.t(), String.t(), String.t()) :: :ok | {:error, String.t()}
  def delete(%Git{} = git, vault_path, rel_path, message) do
    prefix = "git rm/commit failed"

    with {:ok, _commit_meta} <-
           change(git, vault_path, [rel_path], message, prefix, fn ->
             git_step(git.remove.(vault_path, [rel_path]), prefix)
           end),
         do: :ok
  end

  @doc """
  Moves `from` to `to` inside the vault and commits both paths under `message`.

  Returns the commit metadata for the note at its new path.
  """
  @spec move(Git.t(), String.t(), String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, String.t()}
  def move(%Git{} = git, vault_path, from, to, message) do
    prefix = "git mv/commit failed"

    change(git, vault_path, [from, to], message, prefix, fn ->
      with :ok <- mkdir_p(Path.dirname(Path.join(vault_path, to))) do
        git_step(git.move.(vault_path, from, to), prefix)
      end
    end)
  end

  # One change to the vault, all of it or none of it (docs/design.md, "A
  # failed commit leaves the vault as it was"). `paths` is every path the
  # change touches; `perform` changes the working tree and stages it, answering
  # `:ok` or a finished sentence, and the commit follows. What the working
  # tree and the staging area hold for those paths is taken first, and put
  # back if anything after it fails — a write, a `git rm`, a `git mv`, the
  # commit itself. A change that did not commit
  # must not stay behind: the next write's commit would sweep it in under its
  # own message.
  #
  # A git failure reads as `prefix: <what git said>`.
  defp change(git, vault_path, paths, message, prefix, perform) do
    tree = snapshot_tree(vault_path, paths)

    with {:ok, index} <- git_step(git.snapshot_index.(vault_path, paths), prefix) do
      with :ok <- perform.(),
           {:ok, commit_meta} <- git_step(git.commit.(vault_path, paths, message), prefix) do
        {:ok, commit_meta}
      else
        {:error, msg} ->
          roll_back(git, vault_path, tree, index)
          {:error, msg}
      end
    end
  end

  # What git answered, with the operation's name in front of it.
  defp git_step({:error, out}, prefix), do: {:error, "#{prefix}: #{out}"}
  defp git_step(ok, _prefix), do: ok

  # Every touched path's content — or that it was not there — and every
  # directory above it that did not exist yet, so a directory the change
  # created goes again with it.
  defp snapshot_tree(vault_path, paths) do
    Enum.map(paths, fn rel_path ->
      abs_path = Path.join(vault_path, rel_path)
      {abs_path, File.read(abs_path), missing_dirs(vault_path, Path.dirname(rel_path))}
    end)
  end

  defp missing_dirs(_vault_path, "."), do: []

  defp missing_dirs(vault_path, rel_dir) do
    abs_dir = Path.join(vault_path, rel_dir)

    if File.dir?(abs_dir),
      do: [],
      else: [abs_dir | missing_dirs(vault_path, Path.dirname(rel_dir))]
  end

  # Best effort, and loud when it falls short: the change has already failed,
  # and a rollback that fails too is not something the caller can act on, but
  # it is something the operator has to know about.
  defp roll_back(git, vault_path, tree, index) do
    Enum.each(tree, fn {abs_path, previous, created_dirs} ->
      restore_file(abs_path, previous)
      Enum.each(created_dirs, &File.rmdir/1)
    end)

    case git.restore_index.(vault_path, index) do
      :ok -> :ok
      {:error, out} -> Logger.error("vigil: could not restore the git index: #{out}")
    end
  end

  # `git rm` takes a directory it empties with it, so the parent may have to
  # come back before the file can.
  defp restore_file(abs_path, {:ok, previous}) do
    with :ok <- mkdir_p(Path.dirname(abs_path)),
         :ok <- write_file(abs_path, previous) do
      :ok
    else
      {:error, msg} -> Logger.error("vigil: could not restore #{abs_path}: #{msg}")
    end
  end

  defp restore_file(abs_path, {:error, :enoent}) do
    case File.rm(abs_path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> Logger.error("vigil: could not remove #{abs_path}: #{fs_error(reason)}")
    end
  end

  # A file that could not be read beforehand is one this change never
  # replaced: the write in front of the commit would have failed the same way.
  defp restore_file(_abs_path, {:error, _reason}), do: :ok

  @doc """
  Pushes the vault's `branch` to `remote`.

  The failure comes back as git wrote it, unwrapped: what was committed
  locally but not pushed is a change, a deletion, a move or a skill, and the
  caller is the one that knows which — so the sentence in front of it is the
  caller's (`docs/design.md`, "The write path").
  """
  @spec push(Git.t(), String.t(), String.t(), String.t()) :: :ok | {:error, String.t()}
  def push(%Git{} = git, vault_path, remote, branch), do: git.push.(vault_path, remote, branch)

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

  # Into a temporary file beside the target, then renamed over it: a crash
  # mid-write leaves the note as it was and a stray dotfile, never a truncated
  # note. The rename is atomic because both names are in one directory.
  defp write_file(path, content) do
    tmp =
      Path.join(
        Path.dirname(path),
        ".#{Path.basename(path)}.#{System.unique_integer([:positive])}.tmp"
      )

    with :ok <- File.write(tmp, content),
         :ok <- File.rename(tmp, path) do
      :ok
    else
      {:error, reason} ->
        File.rm(tmp)
        {:error, "Could not write file #{path}: #{fs_error(reason)}"}
    end
  end
end
