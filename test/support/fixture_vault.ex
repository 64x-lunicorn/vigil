defmodule Vigil.FixtureVault do
  @moduledoc """
  A throwaway copy of `test/fixtures/vault`. Files, and nothing else.

  It used to git-init the copy, configure four things, commit, and optionally
  add a bare remote and push to it — once per test, in the setup of every
  vault-backed file, which is where the bulk of the suite's runtime went.
  Those tests reach git through `Vigil.Git.CommitLog` now (docs/design.md,
  "Git is reached through a value"); they assert something about vigil and
  merely used to travel through git to do it.

  `test/vigil/git_test.exs` is the one file that still needs a repository, and
  it builds one with `Vigil.GitRepo`.
  """

  @source Path.expand("../fixtures/vault", __DIR__)

  @doc "Copies the fixture vault into a fresh temp dir and returns its path."
  def build do
    tmp = Path.join(System.tmp_dir!(), "vigil_test_#{System.unique_integer([:positive])}")
    File.cp_r!(@source, tmp)
    tmp
  end

  def cleanup(path) when is_binary(path) do
    File.rm_rf(path)
    File.rm_rf(path <> "_remote.git")
  end
end
