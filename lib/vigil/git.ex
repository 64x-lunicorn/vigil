defmodule Vigil.Git do
  @moduledoc """
  Git, as a value its callers hold rather than a module they name
  (`docs/design.md`, "Git is reached through a value").

  Two things live here. The **contract** is a struct of sixteen functions —
  the whole of what vigil asks git: `add`, `remove`, `move`, `commit`,
  `snapshot_index`, `restore_index` and `push`, which a write uses,
  `log_metadata`, which the load uses and no write ever asks, `history` and
  `show`, which the `history` tool and `read` at a revision ask, `tracking`,
  which boot asks once to check the remote and branch settings against the
  clone, and `divergence`, `fetch`, `fast_forward`, `rebase` and
  `abort_rebase`, which bring the vault up to date — at boot, on `reload`,
  before a write and after a push the remote refused — and tell `status` how
  far apart the vault and its remote are. Staging and
  committing are separate questions so that a commit can fail *after* its
  staging has happened, and the staging be undone (`Vigil.Commit`,
  `docs/design.md`, "A failed commit leaves the vault as it was"). The seam is drawn where git is, not where the
  writes are: one around the write effect alone would leave every load reaching
  for a repository, and `log_metadata` answering `%{}` for a directory that is
  not one — a `created_at` of `nil` on every note, arriving as an ordinary
  answer.

  The **production adapter** is the rest of this module: `over_repository/0`
  wires the sixteen questions to the `git` commands underneath it. It is a function
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
    # The whole vault's commit metadata: path => %{created_at:, updated_at:,
    # last_author:}. What "creation date = first commit" is read out of
    # (docs/design.md, principle 3).
    :log_metadata,
    # The commits that touched one path, newest first, at most `limit`,
    # following renames: [%{commit:, at:, author:, email:, message:, path:}],
    # `path` being what the note was called in that commit.
    # {:ok, commits} | {:error, reason}.
    :history,
    # One path's content as it was at a revision, and the date of the last
    # commit up to that revision that touched it.
    # {:ok, %{commit:, content:, updated_at:}} | {:error, :unknown_revision}
    # | {:error, :not_found}.
    :show,
    # git add -- paths. :ok | {:error, reason}.
    :add,
    # git rm -- paths, from the index and the working tree. :ok | {:error, reason}.
    :remove,
    # git mv -- from to. :ok | {:error, reason}.
    :move,
    # Commit what is staged for paths, authored as vigil — refused on a
    # detached HEAD. {:ok, %{updated_at:, last_author:}} | {:error, reason}.
    :commit,
    # What the index holds for paths, opaque to the caller.
    # {:ok, snapshot} | {:error, reason}.
    :snapshot_index,
    # Put the index back as a snapshot found it. :ok | {:error, reason}.
    :restore_index,
    # git push <remote> <branch>, refused before it is tried while the branch
    # holds commits a force-push took off the remote. :ok | {:error, reason}.
    :push,
    # What the clone's remotes and branches are, for the boot check of
    # VIGIL_GIT_REMOTE and VIGIL_GIT_BRANCH, and whether a rebase was left in
    # progress. {:ok, %{head:, remotes:, branches:, rebasing:}} |
    # {:error, reason} — see tracking/1.
    :tracking,
    # How many commits the branch holds that <remote>/<branch> lacks, and the
    # other way round, as the clone last saw the remote — read locally — and
    # how many of the first the remote once held and a force-push took away.
    # {:ok, %{ahead:, behind:, rewritten:}} | {:error, reason}.
    :divergence,
    # git fetch <remote> <branch>, into <remote>/<branch>. Touches neither the
    # branch nor the working tree. :ok | {:error, reason}.
    :fetch,
    # git merge --ff-only <remote>/<branch>: adopts what the last fetch
    # brought, or refuses. :ok | {:error, reason}.
    :fast_forward,
    # git rebase --onto <remote>/<branch> <fork point>: vigil's own unpushed
    # commits — never what a force-push took off the remote — replayed on
    # top of what the last fetch brought, never a merge. :ok |
    # {:conflict, paths} — the rebase stopped, and is left for abort_rebase —
    # | {:error, reason}.
    :rebase,
    # git rebase --abort: the branch and the working tree back as they were
    # before the rebase. :ok | {:error, reason}.
    :abort_rebase
  ]

  defstruct @enforce_keys

  @type t :: %__MODULE__{}

  @doc """
  Builds a git adapter from an answer to every one of the sixteen questions.

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
      log_metadata: &log_metadata/1,
      history: &history/3,
      show: &show/3,
      add: &add/2,
      remove: &remove/2,
      move: &move/3,
      commit: &commit/3,
      snapshot_index: &snapshot_index/2,
      restore_index: &restore_index/2,
      push: &push/3,
      tracking: &tracking/1,
      divergence: &divergence/3,
      fetch: &fetch/3,
      fast_forward: &fast_forward/3,
      rebase: &rebase/3,
      abort_rebase: &abort_rebase/1
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

  # No hook in the vault's clone runs for anything vigil does to it: a
  # `pre-commit`, `pre-push` or `reference-transaction` hook a human installed
  # for their own work is not vigil's to satisfy, and one that fails would
  # fail every write, the fetch before it and the push after it. Every call
  # that commits, moves a ref or talks to the remote carries this.
  @no_hooks ["-c", "core.hooksPath=/dev/null"]

  # The three calls that leave the machine are bounded. Every write waits on the
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
  The commits that touched `path`, newest first and at most `limit` of them,
  followed across renames (`git log --follow`): `{:ok, [%{commit:, at:,
  author:, email:, message:, path:}]}`, where `path` is what the note was
  called in that commit and `message` is the commit's subject. A path git
  has never seen answers `{:ok, []}`.

  Read NUL-separated like `log_metadata/1`, so a path git would quote arrives
  as the filesystem spells it.
  """
  def history(vault_path, path, limit) do
    with {:ok, out} <-
           run(vault_path, [
             "log",
             "--follow",
             "-M",
             "-z",
             "--name-status",
             "--format=%x01%H%x00%aI%x00%an%x00%ae%x00%s",
             "-n",
             Integer.to_string(limit),
             "--",
             path
           ]) do
      {:ok, out |> String.split("\x01", trim: true) |> Enum.map(&history_entry(&1, path))}
    end
  end

  # `<hash>\0<iso>\0<name>\0<email>\0<subject>\0\n` and then the commit's
  # changes to the followed path — `<status>\0<path>\0`, or
  # `R<score>\0<old>\0<new>\0` — whose last path is the name it had then. A
  # merge lists none, and is reported under the name it was followed to.
  defp history_entry(record, followed) do
    [hash, iso, name, email, subject | changes] = String.split(record, "\0")
    {:ok, at, _} = DateTime.from_iso8601(iso)

    paths =
      changes
      |> Enum.map(&String.trim_leading(&1, "\n"))
      |> Enum.reject(&(&1 == ""))
      |> Enum.drop(1)

    %{
      commit: hash,
      at: at,
      author: name,
      email: email,
      message: subject,
      path: List.last(paths, followed)
    }
  end

  @doc """
  `path` as it was at `rev`: `{:ok, %{commit:, content:, updated_at:}}`, the
  commit `rev` names in full, the file's bytes there, and the date of the
  last commit up to it that touched the path.

  The revision is verified before anything is read: whatever `rev` is, it is
  handed to `git rev-parse --verify --end-of-options` and peeled to a commit,
  so it cannot be an option and cannot name a tree or a blob. A revision
  starting with `-` is not tried at all. `{:error, :unknown_revision}` for
  anything that does not name a commit, `{:error, :not_found}` for a path the
  commit does not hold.
  """
  def show(vault_path, rev, path) do
    with {:ok, sha} <- verify_revision(vault_path, rev),
         {:ok, updated_at} <- last_touched(vault_path, sha, path),
         {:ok, content} <- blob(vault_path, sha, path) do
      {:ok, %{commit: sha, content: content, updated_at: updated_at}}
    end
  end

  defp verify_revision(_vault_path, "-" <> _), do: {:error, :unknown_revision}
  defp verify_revision(_vault_path, ""), do: {:error, :unknown_revision}

  defp verify_revision(vault_path, rev) do
    case run(vault_path, [
           "rev-parse",
           "--verify",
           "--quiet",
           "--end-of-options",
           rev <> "^{commit}"
         ]) do
      {:ok, out} -> {:ok, String.trim(out)}
      {:error, _} -> {:error, :unknown_revision}
    end
  end

  defp last_touched(vault_path, sha, path) do
    case run(vault_path, ["log", "-1", "--format=%aI", sha, "--", path]) do
      {:ok, out} ->
        case DateTime.from_iso8601(String.trim(out)) do
          {:ok, at, _} -> {:ok, at}
          {:error, _} -> {:error, :not_found}
        end

      {:error, _} ->
        {:error, :not_found}
    end
  end

  defp blob(vault_path, sha, path) do
    case run(vault_path, ["cat-file", "blob", "#{sha}:#{path}"]) do
      {:ok, content} -> {:ok, content}
      {:error, _} -> {:error, :not_found}
    end
  end

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

  Refused on a detached HEAD — a rebase that stopped and was never aborted,
  a checkout by hand: a commit there is on no branch, the push that follows
  names the branch and finds it up to date, and the write would be reported
  pushed while it never leaves the host.
  """
  def commit(vault_path, paths, message) do
    with :ok <- on_a_branch(vault_path),
         {:ok, _} <- commit_if_changed(vault_path, paths, message) do
      last_commit_meta(vault_path, paths)
    end
  end

  defp on_a_branch(vault_path) do
    case checked_out(vault_path) do
      nil -> {:error, "HEAD is detached: vigil commits only onto a checked-out branch"}
      _branch -> :ok
    end
  end

  # A write whose content is what the file already holds — the same type set
  # again, a skill written back unchanged — has nothing to commit, and `git
  # commit` says so with exit 1. That is not a failure: the note is exactly as
  # asked, and its last commit is its metadata.
  defp commit_if_changed(vault_path, paths, message) do
    case run(vault_path, ["diff", "--cached", "--quiet", "--" | paths]) do
      {:ok, _} ->
        {:ok, :unchanged}

      {:error, _} ->
        run(vault_path, @no_hooks ++ @commit_identity ++ ["commit", "-m", message, "--" | paths])
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

  # Unsigned like every commit vigil makes: a `push.gpgSign` inherited from
  # the ambient configuration asks for a signature the service user has no
  # key for, and most remotes do not accept signed pushes anyway.
  @push_config @no_hooks ++ ["-c", "push.gpgSign=false"]

  @doc """
  git push <remote> <branch>. Returns :ok | {:error, reason}.

  Refused before anything leaves the machine while the branch holds commits a
  force-push took off the remote (`divergence/3`'s `rewritten`): the remote
  is then an ancestor of the branch, so git would take the push as a
  fast-forward and put back what a human removed.
  """
  def push(vault_path, remote, branch) do
    with :ok <- nothing_rewritten(vault_path, remote, branch),
         {:ok, _} <- run(vault_path, @push_config ++ ["push", remote, branch], @network_env),
         do: :ok
  end

  defp nothing_rewritten(vault_path, remote, branch) do
    case rewritten(vault_path, remote, branch) do
      0 ->
        :ok

      count ->
        {:error,
         "the remote's history was rewritten: #{count} commit(s) this vault holds were " <>
           "taken off #{remote}/#{branch} by a force-push, and pushing would put them back"}
    end
  end

  @doc """
  How far `branch` and `remote`'s copy of it are apart, as the clone last saw
  the remote: `{:ok, %{ahead: ahead, behind: behind, rewritten: rewritten}}`,
  where `ahead` counts the commits only the branch holds — committed, not
  pushed — `behind` the ones only the remote-tracking branch holds, and
  `rewritten` those of `ahead` that the remote once held and a force-push
  took away. Read locally; `behind` and `rewritten` are as fresh as the last
  fetch. `{:error, reason}` when either ref is missing.
  """
  def divergence(vault_path, remote, branch) do
    range = "refs/heads/#{branch}...#{tracking_ref(remote, branch)}"

    with {:ok, out} <- run(vault_path, ["rev-list", "--left-right", "--count", range]) do
      [ahead, behind] = out |> String.trim() |> String.split()

      {:ok,
       %{
         ahead: String.to_integer(ahead),
         behind: String.to_integer(behind),
         rewritten: rewritten(vault_path, remote, branch)
       }}
    end
  end

  # Where the branch forked from the remote-tracking branch, by that ref's
  # reflog: the newest commit of the branch the remote-tracking branch ever
  # pointed at — every fetch and every push vigil makes moves it, and records
  # where it was (`git merge-base --fork-point`, what `git pull --rebase`
  # asks). What lies after it is the branch's own, never pushed; what lies
  # before it and not on the remote-tracking branch any more, a force-push
  # took away. `:none` when the reflog does not reach back that far — the
  # remote-tracking branch is then taken as the fork point, which is what a
  # plain `git rebase` does.
  defp fork_point(vault_path, remote, branch) do
    case run(vault_path, [
           "merge-base",
           "--fork-point",
           tracking_ref(remote, branch),
           "refs/heads/#{branch}"
         ]) do
      {:ok, out} -> {:ok, String.trim(out)}
      {:error, _} -> :none
    end
  end

  defp rewritten(vault_path, remote, branch) do
    with {:ok, fork} <- fork_point(vault_path, remote, branch),
         {:ok, out} <-
           run(vault_path, ["rev-list", "--count", "#{tracking_ref(remote, branch)}..#{fork}"]) do
      out |> String.trim() |> String.to_integer()
    else
      _ -> 0
    end
  end

  @doc """
  `git fetch` of `branch` from `remote` into its remote-tracking branch, and
  nothing else: the branch and the working tree stay as they are. Forced
  (`+`), so the remote-tracking branch says what the remote holds even after a
  force-push there — whether that can be adopted is `fast_forward/3`'s to
  refuse. Bounded like `push`. `:ok | {:error, reason}`.
  """
  def fetch(vault_path, remote, branch) do
    refspec = "+refs/heads/#{branch}:#{tracking_ref(remote, branch)}"

    case run(
           vault_path,
           @no_hooks ++ ["fetch", "--quiet", "--no-tags", remote, refspec],
           @network_env
         ) do
      {:ok, _} -> :ok
      {:error, out} -> {:error, out}
    end
  end

  @doc """
  `git merge --ff-only` onto what the last `fetch/3` brought: the checked-out
  branch moves forward to `remote`'s, or git refuses and nothing moves. Never
  a merge commit (`docs/design.md`, principle 2). `:ok | {:error, reason}`.
  """
  def fast_forward(vault_path, remote, branch) do
    with {:ok, _} <-
           run(
             vault_path,
             @no_hooks ++ ["merge", "--ff-only", "--quiet", tracking_ref(remote, branch)]
           ),
         do: :ok
  end

  defp tracking_ref(remote, branch), do: "refs/remotes/#{remote}/#{branch}"

  # A rebase answers nobody: no hook runs (@no_hooks — a `pre-rebase` or
  # `post-rewrite` hook in the vault's clone included), no editor opens, and
  # the commits it rewrites are committed as vigil and unsigned, like every
  # commit vigil makes. `--no-autosquash` and `--no-update-refs` keep an
  # ambient `rebase.*` setting from turning it into something else.
  @rebase_config @no_hooks ++ @commit_identity
  @rebase_env [{"GIT_EDITOR", "true"}, {"GIT_SEQUENCE_EDITOR", "true"}]

  @doc """
  `git rebase` of the checked-out branch onto what the last `fetch/3` brought
  from `remote`: the branch's own commits — vigil's, committed and never
  pushed, the ones after the fork point — are replayed on top of `remote`'s,
  whatever that history holds, merge commits included. Never a merge
  (`docs/design.md`, principle 2). Commits the branch holds that the remote
  once held and a force-push took away (`divergence/3`'s `rewritten`) are
  not replayed: they leave the branch as they left the remote.

  `:ok` when nothing was left to replay or every commit applied.
  `{:conflict, paths}` when a commit does not apply: the rebase has stopped,
  the paths are the ones git could not resolve, and it is the caller's to
  `abort_rebase/1` — nothing here decides that on its behalf.
  `{:error, reason}` for any other refusal, a rebase that did not start.
  """
  def rebase(vault_path, remote, branch) do
    onto = tracking_ref(remote, branch)

    upstream =
      case fork_point(vault_path, remote, branch) do
        {:ok, fork} -> fork
        :none -> onto
      end

    args =
      @rebase_config ++
        ["rebase", "--quiet", "--no-autosquash", "--no-autostash", "--no-update-refs"] ++
        ["--onto", onto, upstream]

    case run(vault_path, args, @rebase_env) do
      {:ok, _} ->
        :ok

      {:error, out} ->
        case unmerged_paths(vault_path) do
          [] -> {:error, out}
          paths -> {:conflict, paths}
        end
    end
  end

  defp unmerged_paths(vault_path) do
    case run(vault_path, ["diff", "--name-only", "--diff-filter=U", "-z"]) do
      {:ok, out} -> out |> String.split("\0", trim: true) |> Enum.uniq()
      {:error, _} -> []
    end
  end

  @doc """
  `git rebase --abort`: the branch, the index and the working tree back to
  where they stood before `rebase/3` began. `{:error, reason}` when no rebase
  is in progress.
  """
  def abort_rebase(vault_path) do
    with {:ok, _} <- run(vault_path, @rebase_config ++ ["rebase", "--abort"], @rebase_env),
         do: :ok
  end

  @doc """
  What the clone at `vault_path` has to say about its remotes and branches,
  read locally — nothing here reaches the network.

  `{:ok, %{head: head, remotes: remotes, branches: branches, rebasing:
  rebasing}}`: `head` is the checked-out branch (`nil` when `HEAD` is
  detached), `remotes` every configured remote's name, `branches` every local
  branch mapped to its upstream as `{remote, branch}`, or to `nil` when it has
  none, and `rebasing` whether a rebase is in progress — one vigil left
  behind when it stopped in the middle of it. While one is, `HEAD` is
  detached and `head` is the branch being rebased: the one aborting it puts
  `HEAD` back on.
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
      rebasing = rebasing(vault_path)

      {:ok,
       %{
         head: checked_out(vault_path) || rebasing_branch(rebasing),
         remotes: String.split(remotes, "\n", trim: true),
         branches: refs |> String.split("\n", trim: true) |> Map.new(&upstream/1),
         rebasing: rebasing != nil
       }}
    else
      false -> {:error, "#{vault_path} is not a git clone"}
      {:error, out} -> {:error, out}
    end
  end

  defp checked_out(vault_path) do
    case run(vault_path, ["symbolic-ref", "--quiet", "--short", "HEAD"]) do
      {:ok, out} -> String.trim(out)
      {:error, _} -> nil
    end
  end

  # The state directory of a rebase in progress — `rebase-merge` for the
  # backend vigil's rebase uses, `rebase-apply` for the one a human's `git
  # rebase --apply` or `git am` leaves — or nil. Asked of git rather than
  # joined onto `.git`, which is a file in a worktree.
  defp rebasing(vault_path) do
    Enum.find_value(["rebase-merge", "rebase-apply"], fn dir ->
      case run(vault_path, ["rev-parse", "--git-path", dir]) do
        {:ok, out} ->
          path = Path.expand(String.trim(out), vault_path)
          if File.dir?(path), do: path

        {:error, _} ->
          nil
      end
    end)
  end

  # Sobelow: a file inside the clone's own git directory, named by git.
  # sobelow_skip ["Traversal.FileModule"]
  defp rebasing_branch(nil), do: nil

  defp rebasing_branch(dir) do
    case File.read(Path.join(dir, "head-name")) do
      {:ok, "refs/heads/" <> name} -> String.trim(name)
      _ -> nil
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
