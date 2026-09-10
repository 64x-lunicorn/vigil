defmodule Vigil.GitRepo do
  @moduledoc """
  Turns a directory into the git repository the contract suite needs.

  `test/vigil/git_test.exs` is the only caller, and that is the point: it is
  the only file in the suite that touches a repository (docs/design.md, "Git is
  reached through a value"). Everything else asks `Vigil.Git.CommitLog`.

  What the initial commit is authored by and dated at is what
  `Vigil.Git.CommitLog` seeds a vault's existing files with, and the contract
  suite asserts the same answer from both — which is what keeps the two
  statements from drifting apart.
  """

  @author "Daniel"
  @email "daniel@local"
  @at "2026-01-01T10:00:00+01:00"

  @doc """
  `git init` on `path`, on branch `main`, with everything in it committed as
  `#{@author}` at `#{@at}`.

  With `remote: true` it also creates a bare remote beside the vault, adds it
  as `origin` and pushes to it; the remote's path comes back, `nil` otherwise.
  """
  def init(path, opts \\ []) do
    git!(path, ["init", "-q"])
    git!(path, ["symbolic-ref", "HEAD", "refs/heads/main"])
    git!(path, ["config", "user.name", @author])
    git!(path, ["config", "user.email", @email])
    # Repo-level, not just for the initial commit: Vigil.Git's own
    # add_commit/move_commit/remove_commit inherit the caller's global git
    # config, and Daniel's global config signs commits via a 1Password
    # SSH-agent. That agent is flaky/unavailable in a plain test run and has
    # no bearing on what's under test here — production disables signing for
    # the same reason (the vigil service user has no such agent either).
    git!(path, ["config", "commit.gpgsign", "false"])
    git!(path, ["add", "-A"])

    git!(path, ["commit", "-q", "--allow-empty", "-m", "fixtures: initial vault"],
      env: [{"GIT_AUTHOR_DATE", @at}, {"GIT_COMMITTER_DATE", @at}]
    )

    if Keyword.get(opts, :remote, false), do: add_remote(path)
  end

  defp add_remote(path) do
    remote = path <> "_remote.git"
    # -b main explicit: a bare init without it follows the machine's global
    # init.defaultBranch, which isn't guaranteed to be "main" (e.g. plain
    # Debian ships "master"). Vigil.Git always operates against "main".
    git!(nil, ["init", "-q", "--bare", "-b", "main", remote])
    git!(path, ["remote", "add", "origin", remote])
    git!(path, ["push", "-q", "-u", "origin", "main"])
    remote
  end

  defp git!(cwd, args, opts \\ []) do
    env = Keyword.get(opts, :env, [])
    base = [stderr_to_stdout: true]
    base = if cwd, do: base ++ [cd: cwd], else: base
    base = if env != [], do: base ++ [env: env], else: base

    case System.cmd("git", args, base) do
      {out, 0} -> out
      {out, code} -> raise "git #{Enum.join(args, " ")} failed (#{code}): #{out}"
    end
  end
end
