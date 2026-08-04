defmodule Vigil.FixtureVault do
  @moduledoc "Builds a throwaway git-backed copy of test/fixtures/vault for tests."

  @source Path.expand("../fixtures/vault", __DIR__)

  @doc """
  Copies the fixture vault into a fresh temp dir, git-inits it on branch `main`
  with a fixed author/date, and optionally adds a bare remote (`remote: true`)
  so writes can be pushed.

  Returns the vault path (and the remote path, if requested).
  """
  def build(opts \\ []) do
    tmp = Path.join(System.tmp_dir!(), "vigil_test_#{System.unique_integer([:positive])}")
    File.cp_r!(@source, tmp)

    git!(tmp, ["init", "-q"])
    git!(tmp, ["symbolic-ref", "HEAD", "refs/heads/main"])
    git!(tmp, ["config", "user.name", "Daniel"])
    git!(tmp, ["config", "user.email", "daniel@local"])
    # Repo-level, not just for the initial commit: Vigil.Git's own
    # add_commit/move_commit/remove_commit inherit the caller's global git
    # config, and Daniel's global config signs commits via a 1Password
    # SSH-agent. That agent is flaky/unavailable in a plain test run and has
    # no bearing on what's under test here — production disables signing for
    # the same reason (the vigil service user has no such agent either).
    git!(tmp, ["config", "commit.gpgsign", "false"])
    git!(tmp, ["add", "-A"])

    git!(
      tmp,
      ["commit", "-q", "-m", "fixtures: initial vault"],
      env: [
        {"GIT_AUTHOR_DATE", "2026-01-01T10:00:00+01:00"},
        {"GIT_COMMITTER_DATE", "2026-01-01T10:00:00+01:00"}
      ]
    )

    if Keyword.get(opts, :remote, false) do
      remote = tmp <> "_remote.git"
      # -b main explicit: a bare init without it follows the machine's global
      # init.defaultBranch, which isn't guaranteed to be "main" (e.g. plain
      # Debian ships "master"). Vigil.Git always operates against "main".
      git!(nil, ["init", "-q", "--bare", "-b", "main", remote])
      git!(tmp, ["remote", "add", "origin", remote])
      git!(tmp, ["push", "-q", "-u", "origin", "main"])
      {tmp, remote}
    else
      tmp
    end
  end

  def cleanup(path) when is_binary(path) do
    File.rm_rf(path)
    File.rm_rf(path <> "_remote.git")
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
