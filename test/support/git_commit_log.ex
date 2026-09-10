defmodule Vigil.Git.CommitLog do
  @moduledoc """
  A `Vigil.Git` that remembers instead of shelling out — the second adapter
  `docs/design.md`, "Git is reached through a value", records.

  It keeps the metadata. What it is asked to commit is written down under the
  instant it was handed, authored as `vigil`, and `log_metadata` answers out of
  that record. It reads no clock of its own. The alternative — an adapter
  answering "no metadata" — was rejected: it would put a `created_at` of `nil`
  under every test in the suite, which is a shape production never has.

  This is not a second metadata database. "Creation date = first commit"
  (`docs/design.md`, principle 3) is a claim about where a fact lives; what the
  seam states is narrower — a commit reports the instant and the author it was
  made under. Git satisfies that by being a metadata database, this satisfies
  it by remembering, and `test/vigil/git_test.exs` is what keeps the two from
  drifting apart.

  The working tree is real: `remove_commit` deletes the file and `move_commit`
  renames it, because that is what `git rm` and `git mv` do to a vault, and the
  callers above the seam read the vault back afterwards.

  It lives with the tests, like `Vigil.Vault.AbsentFacts`, because only they
  have a use for it.
  """

  alias Vigil.Git

  # The files a vault already has when the adapter is built were committed by
  # somebody before vigil ever saw them — for `test/fixtures/vault` that is
  # `Vigil.FixtureVault`'s initial commit, whose author and instant these are.
  @initial_at ~U[2026-01-01 09:00:00Z]
  @initial_author "Daniel"

  # What every commit this adapter makes is dated. Fixed, and later than the
  # initial one, so "the write's own commit" and "the commit that was already
  # there" are told apart by their instants.
  @commit_at ~U[2026-06-01 12:00:00Z]

  @doc """
  A `Vigil.Git` over `vault_path`, and the log behind it.

  Options:

    * `remote:` — the remote name `push` and `pull` succeed for, `nil` for a
      vault with none. Anything else answers the error git answers.
    * `at:` — the instant every commit it records is made under.
    * `initial_at:` / `initial_author:` — who committed the files the vault
      already has, and when.
  """
  @spec recording(Path.t(), keyword()) :: {Git.t(), pid()}
  def recording(vault_path, opts \\ []) do
    remote = Keyword.get(opts, :remote, "origin")
    at = Keyword.get(opts, :at, @commit_at)

    initial =
      seed(
        vault_path,
        Keyword.get(opts, :initial_at, @initial_at),
        Keyword.get(opts, :initial_author, @initial_author)
      )

    {:ok, log} = Agent.start_link(fn -> %{metadata: initial, calls: []} end)

    git =
      Git.new(
        pull: fn _vault, name -> remote_result(log, {:pull, name}, remote, name) end,
        push: fn _vault, name -> remote_result(log, {:push, name}, remote, name) end,
        log_metadata: fn _vault -> Agent.get(log, & &1.metadata) end,
        add_commit: fn _vault, path, message ->
          record(log, {:add_commit, path, message})
          {:ok, commit(log, path, at)}
        end,
        remove_commit: fn vault, path, message ->
          record(log, {:remove_commit, path, message})
          remove(vault, path)
        end,
        move_commit: fn vault, from, to, message ->
          record(log, {:move_commit, from, to, message})
          move(vault, from, to, at)
        end
      )

    {git, log}
  end

  @doc "As `recording/2`, for a caller with no interest in what was called."
  @spec new(Path.t(), keyword()) :: Git.t()
  def new(vault_path, opts \\ []), do: recording(vault_path, opts) |> elem(0)

  @doc "What the adapter was asked to do, in the order it was asked."
  @spec calls(pid()) :: [tuple()]
  def calls(log), do: Agent.get(log, &Enum.reverse(&1.calls))

  ## The record

  defp record(log, call), do: Agent.update(log, &%{&1 | calls: [call | &1.calls]})

  # A commit authored as vigil. `created_at` survives one: the first commit a
  # path had is what principle 3 calls its creation date, and every later
  # commit only moves `updated_at`.
  defp commit(log, path, at) do
    meta = %{updated_at: at, last_author: "vigil"}

    Agent.update(log, fn state ->
      entry =
        case state.metadata[path] do
          nil -> %{created_at: at, updated_at: at, last_author: "vigil"}
          existing -> %{existing | updated_at: at, last_author: "vigil"}
        end

      %{state | metadata: Map.put(state.metadata, path, entry)}
    end)

    meta
  end

  # The record is not touched: `git log` keeps the history of a path that was
  # removed, and `log_metadata` reads it back out of exactly that history. A
  # note deleted and written again therefore keeps the creation date it had —
  # under real git and here alike.
  defp remove(vault_path, path) do
    case File.rm(Path.join(vault_path, path)) do
      :ok ->
        :ok

      {:error, reason} ->
        {:error, "fatal: pathspec '#{path}' did not match any files (#{reason})"}
    end
  end

  # A rename is neither an addition nor a modification: git reports it as `R`,
  # and `log_metadata`'s `--diff-filter=AM` drops it. So a moved path has no
  # entry of its own until something writes to it again, and the old path keeps
  # the history it already had — the commit metadata the move *returns* is
  # `git log -1 -- <to>`, which is not diff-filtered and does find it. Faithful
  # to what the repository answers, quirk included; the note's creation date
  # survives a move in `Vigil.Index`, not here.
  defp move(vault_path, from, to, at) do
    abs_to = Path.join(vault_path, to)
    File.mkdir_p!(Path.dirname(abs_to))

    case File.rename(Path.join(vault_path, from), abs_to) do
      :ok ->
        {:ok, %{updated_at: at, last_author: "vigil"}}

      {:error, reason} ->
        {:error, "fatal: renaming '#{from}' failed: #{reason}"}
    end
  end

  defp remote_result(log, call, remote, name) do
    record(log, call)

    if name == remote and not is_nil(remote) do
      :ok
    else
      {:error, "fatal: '#{name}' does not appear to be a git repository"}
    end
  end

  # Everything the vault holds when the adapter is built, as one commit by
  # whoever put it there. Without it every note in every test would carry a
  # `created_at` of `nil`.
  defp seed(vault_path, at, author) do
    Path.join(vault_path, "**")
    |> Path.wildcard(match_dot: false)
    |> Enum.filter(&File.regular?/1)
    |> Map.new(fn abs ->
      {Path.relative_to(abs, vault_path), %{created_at: at, updated_at: at, last_author: author}}
    end)
  end
end
