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

  The working tree is real: `remove` deletes the file and `move` renames it,
  because that is what `git rm` and `git mv` do to a vault, and the callers
  above the seam read the vault back afterwards. The staging area is a list of
  what was staged and not yet committed, and `snapshot_index` and
  `restore_index` hand it out and put it back.

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

  One option, `remote:` — the remote name `push` and `pull` succeed for, `nil`
  for a vault with none configured. Anything else answers the error git
  answers, which is how a test provokes a push failure.
  """
  @spec recording(Path.t(), keyword()) :: {Git.t(), pid()}
  def recording(vault_path, opts \\ []) do
    remote = Keyword.get(opts, :remote, "origin")
    at = @commit_at

    {:ok, log} =
      Agent.start_link(fn -> %{metadata: seed(vault_path), staged: [], calls: []} end)

    git =
      Git.new(
        pull: fn _vault, name -> remote_result(log, {:pull, name}, remote, name) end,
        push: fn _vault, name -> remote_result(log, {:push, name}, remote, name) end,
        log_metadata: fn _vault -> Agent.get(log, & &1.metadata) end,
        add: fn _vault, paths ->
          record(log, {:add, paths})
          stage(log, Enum.map(paths, &{:add, &1}))
        end,
        remove: fn vault, paths ->
          record(log, {:remove, paths})
          remove(log, vault, paths)
        end,
        move: fn vault, from, to ->
          record(log, {:move, from, to})
          move(log, vault, from, to)
        end,
        commit: fn _vault, paths, message ->
          record(log, {:commit, paths, message})
          {:ok, commit(log, at)}
        end,
        snapshot_index: fn _vault, _paths -> {:ok, Agent.get(log, & &1.staged)} end,
        restore_index: fn _vault, staged ->
          record(log, :restore_index)
          Agent.update(log, &%{&1 | staged: staged})
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

  # The staging area is the list of what `add`, `remove` and `move` did, in
  # order, and nothing reaches the record until it is committed — which is
  # what makes a restored index observable here: a change staged and never
  # committed would otherwise be swept into the next commit's metadata.
  defp stage(log, changes) do
    Agent.update(log, &%{&1 | staged: &1.staged ++ changes})
  end

  # A commit authored as vigil, of everything staged. `created_at` survives
  # one: the first commit a path had is what principle 3 calls its creation
  # date, and every later commit only moves `updated_at`.
  defp commit(log, at) do
    Agent.update(log, fn state ->
      metadata = Enum.reduce(state.staged, state.metadata, &apply_staged(&1, &2, at))
      %{state | metadata: metadata, staged: []}
    end)

    %{updated_at: at, last_author: "vigil"}
  end

  defp apply_staged({:add, path}, metadata, at),
    do: Map.put(metadata, path, touch(metadata[path], at))

  # The record is not touched: `git log` keeps the history of a path that was
  # removed, and `log_metadata` reads it back out of exactly that history. A
  # note deleted and written again therefore keeps the creation date it had —
  # under real git and here alike.
  defp apply_staged({:remove, _path}, metadata, _at), do: metadata

  # A rename carries the old path's record to the new one, dated by the move:
  # `log_metadata` follows `R` entries, so a moved note keeps the creation date
  # it had, and the old path no longer answers.
  defp apply_staged({:rename, from, to}, metadata, at) do
    {entry, metadata} = Map.pop(metadata, from)
    Map.put(metadata, to, touch(entry, at))
  end

  defp touch(nil, at), do: %{created_at: at, updated_at: at, last_author: "vigil"}
  defp touch(entry, at), do: %{entry | updated_at: at, last_author: "vigil"}

  defp remove(log, vault_path, paths) do
    Enum.reduce_while(paths, :ok, fn path, :ok ->
      case File.rm(Path.join(vault_path, path)) do
        :ok ->
          stage(log, [{:remove, path}])
          {:cont, :ok}

        {:error, reason} ->
          {:halt, {:error, "fatal: pathspec '#{path}' did not match any files (#{reason})"}}
      end
    end)
  end

  defp move(log, vault_path, from, to) do
    abs_to = Path.join(vault_path, to)
    File.mkdir_p!(Path.dirname(abs_to))

    case File.rename(Path.join(vault_path, from), abs_to) do
      :ok -> stage(log, [{:rename, from, to}])
      {:error, reason} -> {:error, "fatal: renaming '#{from}' failed: #{reason}"}
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
  defp seed(vault_path) do
    Path.join(vault_path, "**")
    |> Path.wildcard(match_dot: false)
    |> Enum.filter(&File.regular?/1)
    |> Map.new(fn abs ->
      {Path.relative_to(abs, vault_path),
       %{created_at: @initial_at, updated_at: @initial_at, last_author: @initial_author}}
    end)
  end
end
