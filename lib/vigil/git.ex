defmodule Vigil.Git do
  @moduledoc """
  Git, as a value its callers hold rather than a module they name
  (`docs/design.md`, "Git is reached through a value").

  Two things live here. The **contract** is a struct of ten functions — the
  whole of what vigil asks git: `add`, `remove`, `move`, `commit`,
  `snapshot_index`, `restore_index` and `push`, which a write uses, `pull`
  and `log_metadata`, which the load uses and no write ever asks, and
  `tracking`, which boot asks once to check the remote and branch settings
  against the clone. Staging and
  committing are separate questions so that a commit can fail *after* its
  staging has happened, and the staging be undone (`Vigil.Commit`,
  `docs/design.md`, "A failed commit leaves the vault as it was"). The seam is drawn where git is, not where the
  writes are: one around the write effect alone would leave every load reaching
  for a repository, and `log_metadata` answering `%{}` for a directory that is
  not one — a `created_at` of `nil` on every note, arriving as an ordinary
  answer.

  The **production adapter** is the rest of this module: `over_repository/0`
  wires the ten questions to the `git` commands underneath it. It is a function
  here, beside the contract it implements, rather than closures assembled by a
  caller — there are two callers, `Vigil.Store` and `Vigil.Skills`, and an
  adapter assembled at the call site would exist twice. `Store` builds it when
  it is not handed one; `Skills` has no default, because it holds no
  configuration it could build one from.

  No field has a default, and the struct is built by `struct!/2` — the same
  shape and the same rule as `Vigil.Vault.Facts`: a question added here and
  left unwired fails at construction rather than answering.

  The second adapter is `Vigil.Git.CommitLog`, which lives with the tests
  because only they have a use for it, and `test/vigil/git_test.exs` is the
  contract both of them are held to.
  """

  require Logger

  @enforce_keys [
    # git pull --ff-only <remote> <branch>. :ok | {:error, reason}.
    :pull,
    # The whole vault's commit metadata: path => %{created_at:, updated_at:,
    # last_author:}. What "creation date = first commit" is read out of
    # (docs/design.md, principle 3).
    :log_metadata,
    # git add -- paths. :ok | {:error, reason}.
    :add,
    # git rm -- paths, from the index and the working tree. :ok | {:error, reason}.
    :remove,
    # git mv -- from to. :ok | {:error, reason}.
    :move,
    # Commit what is staged for paths, authored as vigil.
    # {:ok, %{updated_at:, last_author:}} | {:error, reason}.
    :commit,
    # What the index holds for paths, opaque to the caller.
    # {:ok, snapshot} | {:error, reason}.
    :snapshot_index,
    # Put the index back as a snapshot found it. :ok | {:error, reason}.
    :restore_index,
    # git push <remote> <branch>. :ok | {:error, reason}.
    :push,
    # What the clone's remotes and branches are, for the boot check of
    # VIGIL_GIT_REMOTE and VIGIL_GIT_BRANCH.
    # {:ok, %{head:, remotes:, branches:}} | {:error, reason} — see tracking/1.
    :tracking
  ]

  defstruct @enforce_keys

  @type t :: %__MODULE__{}

  @doc """
  Builds a git adapter from an answer to every one of the ten questions.

  Raises `ArgumentError` when a field is missing or unknown, which is the
  point: an unwired question must fail where the adapter is built, not answer
  something plausible at the moment a write depends on it.
  """
  @spec new(Enumerable.t()) :: t
  def new(fields), do: struct!(__MODULE__, fields)

  @doc """
  The production adapter: every question answered by running `git` in the
  repository it is handed.
  """
  @spec over_repository() :: t
  def over_repository do
    new(
      pull: &pull/3,
      log_metadata: &log_metadata/1,
      add: &add/2,
      remove: &remove/2,
      move: &move/3,
      commit: &commit/3,
      snapshot_index: &snapshot_index/2,
      restore_index: &restore_index/2,
      push: &push/3,
      tracking: &tracking/1
    )
  end

  # Identity AND signing behaviour are forced per commit rather than trusting
  # the ambient git configuration. The service user has no signing key and no
  # agent; a `commit.gpgsign=true` inherited from somewhere (a rebuilt
  # container, a hand-edited ~/.gitconfig, a desktop agent) would otherwise
  # fail every single write with "gpg failed to sign the data".
  # scripts/init.sh additionally sets `commit.gpgsign false` globally and in
  # the vault repo; this is the safeguard that does not depend on
  # configuration being right.
  @commit_identity [
    "-c",
    "user.name=vigil",
    "-c",
    "user.email=vigil@local",
    "-c",
    "commit.gpgsign=false"
  ]

  # The two calls that leave the machine are bounded. Every write waits on the
  # push inside the single writer, so an SSH connection that stalls without
  # closing would otherwise hold every read and write behind it until the
  # kernel gives up — minutes, not seconds. BatchMode and no terminal prompt:
  # nobody is there to answer one. The HTTP pair covers an https remote the
  # same way: under 1 KB/s for 20 s aborts the transfer.
  @network_env [
    {"GIT_TERMINAL_PROMPT", "0"},
    {"GIT_SSH_COMMAND",
     "ssh -o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=5 -o ServerAliveCountMax=3"},
    {"GIT_HTTP_LOW_SPEED_LIMIT", "1000"},
    {"GIT_HTTP_LOW_SPEED_TIME", "20"}
  ]

  @doc "git pull --ff-only <remote> <branch>. Logs and returns {:error, reason} on failure (caller decides)."
  def pull(vault_path, remote, branch) do
    case run(vault_path, ["pull", "--ff-only", remote, branch], @network_env) do
      {:ok, _out} ->
        :ok

      {:error, out} ->
        Logger.warning("git pull failed: #{out}")
        {:error, out}
    end
  end

  @doc """
  One-shot metadata scan for the whole vault: returns a map
  `path => %{created_at:, updated_at:, last_author:}`.

  Paths are read NUL-separated (`-z`), so a name git would otherwise quote —
  every umlaut under the default `core.quotePath=true` — arrives exactly as the
  filesystem spells it. A rename (`R`) carries the old path's entry to the new
  one, so a moved note keeps its creation date across a restart.
  """
  def log_metadata(vault_path) do
    case run(vault_path, [
           "log",
           "--format=%x01%H%x00%aI%x00%an",
           "--name-status",
           "-M",
           "--diff-filter=AMR",
           "-z",
           "--reverse"
         ]) do
      {:ok, out} -> parse_log(out)
      {:error, _out} -> %{}
    end
  end

  # Each commit is `\x01<hash>\0<iso>\0<author>\0\n` followed by its changes,
  # `<status>\0<path>\0` — or `R<score>\0<old>\0<new>\0` for a rename.
  defp parse_log(output) do
    output
    |> String.split("\x01", trim: true)
    |> Enum.reduce(%{}, &parse_commit/2)
  end

  defp parse_commit(record, acc) do
    [_hash, iso, author | changes] = String.split(record, "\0")
    {:ok, at, _} = DateTime.from_iso8601(iso)

    changes
    |> Enum.map(&String.trim_leading(&1, "\n"))
    |> Enum.reject(&(&1 == ""))
    |> apply_changes(acc, at, author)
  end

  defp apply_changes(["R" <> _score, from, to | rest], acc, at, author) do
    {entry, acc} = Map.pop(acc, from)
    apply_changes(rest, Map.put(acc, to, touch(entry, at, author)), at, author)
  end

  defp apply_changes([_status, path | rest], acc, at, author) do
    entry = touch(Map.get(acc, path), at, author)
    apply_changes(rest, Map.put(acc, path, entry), at, author)
  end

  defp apply_changes(_, acc, _at, _author), do: acc

  defp touch(nil, at, author), do: %{created_at: at, updated_at: at, last_author: author}
  defp touch(entry, at, author), do: %{entry | updated_at: at, last_author: author}

  @doc """
  `git add` for the given paths — the working tree's content of each, staged.
  Returns `:ok | {:error, reason}`.
  """
  def add(vault_path, paths) do
    with {:ok, _} <- run(vault_path, ["add", "--" | paths]), do: :ok
  end

  @doc "`git rm` for the given paths, from the staging area and the working tree."
  def remove(vault_path, paths) do
    with {:ok, _} <- run(vault_path, ["rm", "-q", "--" | paths]), do: :ok
  end

  @doc "`git mv from to`, in the staging area and the working tree."
  def move(vault_path, from, to) do
    with {:ok, _} <- run(vault_path, ["mv", "--", from, to]), do: :ok
  end

  @doc """
  Commits what is staged for `paths` under `message`, authored as
  `vigil <vigil@local>`, and answers the metadata of the last commit that
  touched them: `{:ok, %{updated_at:, last_author:}}` or `{:error, reason}`.
  """
  def commit(vault_path, paths, message) do
    with {:ok, _} <- commit_if_changed(vault_path, paths, message) do
      last_commit_meta(vault_path, paths)
    end
  end

  # A write whose content is what the file already holds — the same type set
  # again, a skill written back unchanged — has nothing to commit, and `git
  # commit` says so with exit 1. That is not a failure: the note is exactly as
  # asked, and its last commit is its metadata.
  defp commit_if_changed(vault_path, paths, message) do
    case run(vault_path, ["diff", "--cached", "--quiet", "--" | paths]) do
      {:ok, _} -> {:ok, :unchanged}
      {:error, _} -> run(vault_path, @commit_identity ++ ["commit", "-m", message, "--" | paths])
    end
  end

  @doc """
  What the staging area holds for `paths`, as `restore_index/2` puts it back:
  `{:ok, snapshot}` or `{:error, reason}`. A path the index does not hold is
  part of the snapshot too — restoring it means taking it out again.
  """
  def snapshot_index(vault_path, paths) do
    with {:ok, out} <- run(vault_path, ["ls-files", "--stage", "-z", "--" | paths]) do
      entries =
        out
        |> String.split("\0", trim: true)
        |> Map.new(fn line ->
          [info, path] = String.split(line, "\t", parts: 2)
          [mode, sha, _stage] = String.split(info, " ")
          {path, {mode, sha}}
        end)

      {:ok, Map.new(paths, &{&1, Map.get(entries, &1, :absent)})}
    end
  end

  @doc """
  Puts the staging area back the way `snapshot_index/2` found it, path by
  path, without touching the working tree. `:ok | {:error, reason}`.
  """
  def restore_index(vault_path, snapshot) do
    Enum.reduce_while(snapshot, :ok, fn {path, entry}, :ok ->
      case run(vault_path, update_index(path, entry)) do
        {:ok, _} -> {:cont, :ok}
        {:error, out} -> {:halt, {:error, out}}
      end
    end)
  end

  defp update_index(path, :absent), do: ["update-index", "--force-remove", "--", path]

  defp update_index(path, {mode, sha}),
    do: ["update-index", "--add", "--cacheinfo", "#{mode},#{sha},#{path}"]

  @doc "git push <remote> <branch>. Returns :ok | {:error, reason}."
  def push(vault_path, remote, branch) do
    case run(vault_path, ["push", remote, branch], @network_env) do
      {:ok, _} -> :ok
      {:error, out} -> {:error, out}
    end
  end

  @doc """
  What the clone at `vault_path` has to say about its remotes and branches,
  read locally — nothing here reaches the network.

  `{:ok, %{head: head, remotes: remotes, branches: branches}}`: `head` is the
  checked-out branch (`nil` when `HEAD` is detached), `remotes` every
  configured remote's name, and `branches` every local branch mapped to its
  upstream as `{remote, branch}`, or to `nil` when it has none.
  `{:error, reason}` when `vault_path` is not the top of a git clone — the same
  test `Vigil.Store` puts to it, so that a vault inside another repository is
  not answered for by that repository.
  """
  def tracking(vault_path) do
    with true <- File.exists?(Path.join(vault_path, ".git")),
         {:ok, remotes} <- run(vault_path, ["remote"]),
         {:ok, refs} <-
           run(vault_path, [
             "for-each-ref",
             "--format=%(refname:short)%00%(upstream:remotename)%00%(upstream:remoteref)",
             "refs/heads"
           ]) do
      {:ok,
       %{
         head: head(vault_path),
         remotes: String.split(remotes, "\n", trim: true),
         branches: refs |> String.split("\n", trim: true) |> Map.new(&upstream/1)
       }}
    else
      false -> {:error, "#{vault_path} is not a git clone"}
      {:error, out} -> {:error, out}
    end
  end

  defp head(vault_path) do
    case run(vault_path, ["symbolic-ref", "--quiet", "--short", "HEAD"]) do
      {:ok, out} -> String.trim(out)
      {:error, _} -> nil
    end
  end

  defp upstream(line) do
    case String.split(line, "\0") do
      [branch, remote, "refs/heads/" <> upstream] when remote != "" ->
        {branch, {remote, upstream}}

      [branch | _] ->
        {branch, nil}
    end
  end

  defp last_commit_meta(vault_path, paths) do
    case run(vault_path, ["log", "-1", "--format=%aI%x00%an", "--" | paths]) do
      {:ok, out} ->
        [iso, author] = out |> String.trim() |> String.split("\0", parts: 2)
        {:ok, dt, _} = DateTime.from_iso8601(iso)
        {:ok, %{updated_at: dt, last_author: author}}

      {:error, out} ->
        {:error, out}
    end
  end

  # Every path vigil hands git is a path, never a pattern. Without this a note a
  # human named `*.md` is a pathspec, and `git rm -- bike/*.md` removes every
  # note in the directory it matches.
  @literal_pathspecs {"GIT_LITERAL_PATHSPECS", "1"}

  defp run(vault_path, args, env \\ []) do
    env = [@literal_pathspecs | env]

    case System.cmd("git", args, cd: vault_path, stderr_to_stdout: true, env: env) do
      {out, 0} -> {:ok, out}
      {out, _code} -> {:error, out}
    end
  end
end
