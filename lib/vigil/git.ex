defmodule Vigil.Git do
  @moduledoc """
  Git, as a value its callers hold rather than a module they name
  (`docs/design.md`, "Git is reached through a value").

  Two things live here. The **contract** is a struct of six functions — the
  whole of what vigil asks git: `add_commit`, `remove_commit`, `move_commit`
  and `push`, which a write uses, and `pull` and `log_metadata`, which the load
  uses and no write ever asks. The seam is drawn where git is, not where the
  writes are: one around the write effect alone would leave every load reaching
  for a repository, and `log_metadata` answering `%{}` for a directory that is
  not one — a `created_at` of `nil` on every note, arriving as an ordinary
  answer.

  The **production adapter** is the rest of this module: `over_repository/0`
  wires the six questions to the `git` commands underneath it. It is a function
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
    # git pull --ff-only <remote> main. :ok | {:error, reason}.
    :pull,
    # The whole vault's commit metadata: path => %{created_at:, updated_at:,
    # last_author:}. What "creation date = first commit" is read out of
    # (docs/design.md, principle 3).
    :log_metadata,
    # Stage one path and commit it, authored as vigil.
    # {:ok, %{updated_at:, last_author:}} | {:error, reason}.
    :add_commit,
    # git rm one path and commit the removal. :ok | {:error, reason}.
    :remove_commit,
    # git mv, then commit both paths.
    # {:ok, %{updated_at:, last_author:}} | {:error, reason}.
    :move_commit,
    # git push <remote> main. :ok | {:error, reason}.
    :push
  ]

  defstruct @enforce_keys

  @type t :: %__MODULE__{}

  @doc """
  Builds a git adapter from an answer to every one of the six questions.

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
      pull: &pull/2,
      log_metadata: &log_metadata/1,
      add_commit: &add_commit/3,
      remove_commit: &remove_commit/3,
      move_commit: &move_commit/4,
      push: &push/2
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

  @doc "git pull --ff-only <remote> main. Logs and returns {:error, reason} on failure (caller decides)."
  def pull(vault_path, remote) do
    case run(vault_path, ["pull", "--ff-only", remote, "main"], @network_env) do
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
  `git add` + `git commit` for a single file, authored as `vigil <vigil@local>`.
  Returns `{:ok, %{updated_at:, last_author:}}` or `{:error, reason}`.
  """
  def add_commit(vault_path, path, message) do
    with {:ok, _} <- run(vault_path, ["add", "--", path]),
         {:ok, _} <- commit_if_changed(vault_path, path, message) do
      last_commit_meta(vault_path, path)
    end
  end

  # A write whose content is what the file already holds — the same type set
  # again, a skill written back unchanged — has nothing to commit, and `git
  # commit` says so with exit 1. That is not a failure: the note is exactly as
  # asked, and its last commit is its metadata.
  defp commit_if_changed(vault_path, path, message) do
    case run(vault_path, ["diff", "--cached", "--quiet", "--", path]) do
      {:ok, _} -> {:ok, :unchanged}
      {:error, _} -> run(vault_path, @commit_identity ++ ["commit", "-m", message, "--", path])
    end
  end

  @doc "git push <remote> main. Returns :ok | {:error, reason}."
  def push(vault_path, remote) do
    case run(vault_path, ["push", remote, "main"], @network_env) do
      {:ok, _} -> :ok
      {:error, out} -> {:error, out}
    end
  end

  @doc "git rm -- path, then commit, authored as vigil. Returns :ok | {:error, reason}."
  def remove_commit(vault_path, path, message) do
    with {:ok, _} <- run(vault_path, ["rm", "--", path]),
         {:ok, _} <-
           run(vault_path, @commit_identity ++ ["commit", "-m", message, "--", path]) do
      :ok
    end
  end

  @doc """
  `git mv from to`, then commit both paths, authored as vigil.
  Returns `{:ok, %{updated_at:, last_author:}}` or `{:error, reason}`.
  """
  def move_commit(vault_path, from, to, message) do
    with {:ok, _} <- run(vault_path, ["mv", "--", from, to]),
         {:ok, _} <-
           run(vault_path, @commit_identity ++ ["commit", "-m", message, "--", from, to]) do
      last_commit_meta(vault_path, to)
    end
  end

  defp last_commit_meta(vault_path, path) do
    case run(vault_path, ["log", "-1", "--format=%aI%x00%an", "--", path]) do
      {:ok, out} ->
        [iso, author] = out |> String.trim() |> String.split("\0", parts: 2)
        {:ok, dt, _} = DateTime.from_iso8601(iso)
        {:ok, %{updated_at: dt, last_author: author}}

      {:error, out} ->
        {:error, out}
    end
  end

  defp run(vault_path, args, env \\ []) do
    case System.cmd("git", args, cd: vault_path, stderr_to_stdout: true, env: env) do
      {out, 0} -> {:ok, out}
      {out, _code} -> {:error, out}
    end
  end
end
