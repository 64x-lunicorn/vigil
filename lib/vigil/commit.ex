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

  @push_failed [:vigil, :push, :failed]

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
  Moves `from` to `to` inside the vault and commits it under `message`,
  together with `rewrites` — `{path, content}` pairs written after the move,
  in the same commit. `move_note`'s `update_links` is what hands some over: the
  notes whose links it rewrote, and `to` itself when the note links to itself.
  The move and every rewrite are one change: a failure anywhere leaves every
  one of those files as it was.

  Returns the commit metadata for the note at its new path.
  """
  @spec move(Git.t(), String.t(), String.t(), String.t(), String.t(), [{String.t(), String.t()}]) ::
          {:ok, map()} | {:error, String.t()}
  def move(%Git{} = git, vault_path, from, to, message, rewrites \\ []) do
    prefix = "git mv/commit failed"
    rewritten = Enum.map(rewrites, &elem(&1, 0))

    change(git, vault_path, Enum.uniq([from, to | rewritten]), message, prefix, fn ->
      with :ok <- mkdir_p(Path.dirname(Path.join(vault_path, to))),
           :ok <- git_step(git.move.(vault_path, from, to), prefix),
           :ok <- write_all(vault_path, rewrites) do
        stage(git, vault_path, rewritten, prefix)
      end
    end)
  end

  defp write_all(vault_path, rewrites) do
    Enum.reduce_while(rewrites, :ok, fn {rel_path, content}, :ok ->
      case write_file(Path.join(vault_path, rel_path), content) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp stage(_git, _vault_path, [], _prefix), do: :ok
  defp stage(git, vault_path, paths, prefix), do: git_step(git.add.(vault_path, paths), prefix)

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
  # Sobelow: rel_path passed Vigil.Slug.safe_path/1 before the store handed it
  # down.
  # sobelow_skip ["Traversal.FileModule"]
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

  # Sobelow: abs_path is one snapshot_tree/2 built from a safe_path-checked
  # path.
  # sobelow_skip ["Traversal.FileModule"]
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

  Every failure is also a telemetry event, `#{inspect(@push_failed)}`, with
  the vault path, the remote, the branch and git's reason as metadata: a push
  that fails is the one outcome of a write that leaves the vault and its
  remote apart, and an operator watching for it should not have to read logs.
  """
  @spec push(Git.t(), String.t(), String.t(), String.t()) :: :ok | {:error, String.t()}
  def push(%Git{} = git, vault_path, remote, branch) do
    case git.push.(vault_path, remote, branch) do
      :ok ->
        :ok

      {:error, reason} ->
        :telemetry.execute(@push_failed, %{count: 1}, %{
          vault_path: vault_path,
          remote: remote,
          branch: branch,
          reason: reason
        })

        {:error, reason}
    end
  end

  @doc """
  Creates `path` and every missing parent, or says why it could not.

  `write/5` does this for the file's own directory. It is public for the one
  caller that creates a directory as an act of its own — `create`'s
  `create_dirs`, where a failure has to be attributable to the directory
  rather than to the file.
  """
  @spec mkdir_p(String.t()) :: :ok | {:error, String.t()}
  # Sobelow: callers join the vault root with a safe_path-checked path.
  # sobelow_skip ["Traversal.FileModule"]
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
  #
  # Atomic is not durable: without a sync the rename can reach the disk
  # before the data does, and a power cut in between leaves an empty note
  # under the name. So the temporary file is synced before it is renamed, and
  # the directory after, so the rename itself is on disk when the commit
  # follows. The directory's sync is best effort — not every filesystem
  # answers one, and the note is already in place when it is asked.
  #
  # A new file has the mode the umask gives it, so the temporary file takes
  # the replaced note's mode first: a note its owner kept private stays
  # private. (`temp_file?/1` is what the load sweeps a crash's leftovers by;
  # the name built here and that pattern are the same statement.)
  # Sobelow: path is the vault root joined with a safe_path-checked path.
  # sobelow_skip ["Traversal.FileModule"]
  defp write_file(path, content) do
    tmp =
      Path.join(
        Path.dirname(path),
        ".#{Path.basename(path)}.#{System.unique_integer([:positive])}.tmp"
      )

    with :ok <- write_synced(tmp, content, mode(path)),
         :ok <- File.rename(tmp, path) do
      sync_directory(Path.dirname(path))
    else
      {:error, reason} ->
        File.rm(tmp)
        {:error, "Could not write file #{path}: #{fs_error(reason)}"}
    end
  end

  # Sobelow: tmp is write_file/2's, beside a safe_path-checked path.
  # sobelow_skip ["Traversal.FileModule"]
  defp write_synced(tmp, content, mode) do
    with {:ok, fd} <- :file.open(tmp, [:write, :raw, :binary, :exclusive]) do
      result =
        with :ok <- :file.write(fd, content),
             :ok <- keep_mode(tmp, mode),
             do: :file.sync(fd)

      :file.close(fd)
      result
    end
  end

  defp mode(path) do
    case File.stat(path) do
      {:ok, %File.Stat{mode: mode}} -> Bitwise.band(mode, 0o7777)
      {:error, _} -> nil
    end
  end

  defp keep_mode(_tmp, nil), do: :ok
  defp keep_mode(tmp, mode), do: File.chmod(tmp, mode)

  defp sync_directory(dir) do
    with {:ok, fd} <- :file.open(dir, [:read, :raw, :directory]) do
      :file.sync(fd)
      :file.close(fd)
    end

    :ok
  end

  @doc """
  Whether `name` — a file name, not a path — is one `write/5` gives the
  temporary file a note is written to before it is renamed into place:
  `.<note>.md.<n>.tmp`. A crash between the two leaves one behind, and the
  load removes it (`Vigil.Store`); nothing else is ever that name, since a
  dot-prefixed name is no note and no path vigil writes.
  """
  @spec temp_file?(String.t()) :: boolean()
  def temp_file?(name), do: Regex.match?(~r/\A\.[^\/]+\.md\.[0-9]+\.tmp\z/, name)
end
