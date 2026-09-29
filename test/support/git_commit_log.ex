defmodule Vigil.Git.CommitLog do
  @moduledoc """
  A `Vigil.Git` that remembers instead of shelling out — the second adapter
  `docs/design.md`, "Git is reached through a value", records.

  It keeps the metadata. What it is asked to commit is written down under the
  instant it was handed, authored as `vigil`, and `log_metadata` answers out of
  that record. So is what each commit changed — the content of every path it
  added, which it removed and which it renamed — and `history` and `show`
  answer out of that, following a rename the way `git log --follow` does. It reads no clock of its own. The alternative — an adapter
  answering "no metadata" — was rejected: it would put a `created_at` of `nil`
  under every test in the suite, which is a shape production never has.

  This is not a second metadata database. "Creation date = first commit"
  (`docs/design.md`, principle 3) is a claim about where a fact lives; what the
  seam states is narrower — a commit reports the instant and the author it was
  made under. Git satisfies that by being a metadata database, this satisfies
  it by remembering, and `test/vigil/git_test.exs` is what keeps the two from
  drifting apart.

  The remote is a record too. What `push_from_elsewhere/4` puts there is a
  commit another clone pushed: `fetch` brings it into view, `divergence`
  counts it as behind, `fast_forward` writes it into the working tree, and
  `push` is refused while the remote holds anything the vault lacks — which is
  what git does with a push that is not a fast-forward. `rebase` puts the
  vault's unpushed commits on top of what was fetched, and stops at a
  conflict when a fetched commit touches a path one of them touched — a
  whole-file notion of a conflict, coarser than git's line-wise one, and the
  same answer for the one case the contract suite pins: both sides changed
  the same note. A stopped rebase stays stopped until `abort_rebase`.

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
  @initial_email "daniel@local"
  @initial_message "fixtures: initial vault"

  # What every commit this adapter makes is dated. Fixed, and later than the
  # initial one, so "the write's own commit" and "the commit that was already
  # there" are told apart by their instants.
  @commit_at ~U[2026-06-01 12:00:00Z]

  # What a commit another clone pushed is dated: between the two above, so a
  # file adopted from the remote is told apart from both.
  @elsewhere_at ~U[2026-03-01 08:00:00Z]

  @doc """
  A `Vigil.Git` over `vault_path`, and the log behind it.

  Three options. `remote:` and `branch:` — the remote name and the branch
  `push`, `fetch` and `rebase` succeed for, `"origin"` and `"main"` unless given; a
  `remote:` of `nil` is a vault with none configured. Anything else answers
  the error git answers, which is how a test provokes a push failure.
  `tracking:` — what `tracking` answers; by default a clone with that one
  remote and that one branch checked out, tracking its namesake there.
  """
  @spec recording(Path.t(), keyword()) :: {Git.t(), pid()}
  def recording(vault_path, opts \\ []) do
    remote = Keyword.get(opts, :remote, "origin")
    branch = Keyword.get(opts, :branch, "main")
    tracking = Keyword.get_lazy(opts, :tracking, fn -> tracking(remote, branch) end)
    at = @commit_at

    {:ok, log} =
      Agent.start_link(fn ->
        %{
          metadata: seed(vault_path),
          # Every commit, oldest first, with what it changed.
          commits: [initial_commit(vault_path)],
          staged: [],
          calls: [],
          # Committed here and not pushed: the paths of each commit.
          unpushed: [],
          # The paths a stopped rebase could not apply, until it is aborted.
          rebasing: nil,
          # Pushed from elsewhere, not fetched yet; fetched, not adopted yet.
          remote_only: [],
          fetched: []
        }
      end)

    ours = {remote, branch}

    git =
      Git.new(
        push: fn _vault, name, ref ->
          with :ok <- remote_result(log, {:push, name, ref}, ours, {name, ref}), do: push(log)
        end,
        divergence: fn _vault, name, ref ->
          with :ok <- remote_known(ours, {name, ref}) do
            {:ok, Agent.get(log, &%{ahead: length(&1.unpushed), behind: length(&1.fetched)})}
          end
        end,
        fetch: fn _vault, name, ref ->
          with :ok <- remote_result(log, {:fetch, name, ref}, ours, {name, ref}), do: fetch(log)
        end,
        fast_forward: fn vault, name, ref ->
          with :ok <- remote_result(log, {:fast_forward, name, ref}, ours, {name, ref}),
               do: fast_forward(log, vault)
        end,
        rebase: fn vault, name, ref ->
          with :ok <- remote_result(log, {:rebase, name, ref}, ours, {name, ref}),
               do: rebase(log, vault)
        end,
        abort_rebase: fn _vault ->
          record(log, :abort_rebase)
          abort_rebase(log)
        end,
        tracking: fn _vault -> tracking end,
        log_metadata: fn _vault -> Agent.get(log, & &1.metadata) end,
        history: fn _vault, path, limit ->
          {:ok, Agent.get(log, &history(&1.commits, path, limit))}
        end,
        show: fn _vault, rev, path -> Agent.get(log, &show(&1.commits, rev, path)) end,
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
        commit: fn vault, paths, message ->
          record(log, {:commit, paths, message})
          {:ok, commit(log, vault, paths, message, at)}
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

  @doc """
  A commit another clone pushed to the remote: `path` holding `content`,
  authored by `author`. The vault sees it after a `fetch`, and holds it after
  a `fast_forward` or a `rebase`.
  """
  @spec push_from_elsewhere(pid(), String.t(), String.t(), String.t()) :: :ok
  def push_from_elsewhere(log, path, content, author \\ "Daniel") do
    commit = %{path: path, content: content, author: author}
    Agent.update(log, &%{&1 | remote_only: &1.remote_only ++ [commit]})
  end

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
  defp commit(log, vault_path, paths, message, at) do
    Agent.update(log, fn state ->
      metadata = Enum.reduce(state.staged, state.metadata, &apply_staged(&1, &2, at))
      changes = Enum.flat_map(state.staged, &change(&1, vault_path))

      %{
        state
        | metadata: metadata,
          staged: [],
          unpushed: state.unpushed ++ [paths],
          commits: record_commit(state.commits, changes, "vigil", "vigil@local", message, at)
      }
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

  # What a staged change leaves in the history: the content an added path
  # holds now, a removal, or a rename carrying the content it arrived with.
  defp change({:add, path}, vault_path), do: [{:put, path, read(vault_path, path)}]
  defp change({:remove, path}, _vault_path), do: [{:remove, path}]

  defp change({:rename, from, to}, vault_path),
    do: [{:rename, from, to}, {:put, to, read(vault_path, to)}]

  defp read(vault_path, path), do: File.read!(Path.join(vault_path, path))

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

  ## The remote

  defp fetch(log) do
    Agent.update(log, &%{&1 | fetched: &1.fetched ++ &1.remote_only, remote_only: []})
  end

  # What git does: nothing to adopt is not an error, a branch with commits of
  # its own cannot be fast-forwarded, and otherwise every fetched commit lands
  # in the working tree and in the metadata, under its own author.
  defp fast_forward(log, vault_path) do
    Agent.get_and_update(log, fn
      %{fetched: []} = state ->
        {:ok, state}

      %{unpushed: [_ | _]} = state ->
        {{:error, "fatal: Not possible to fast-forward, aborting."}, state}

      state ->
        metadata = Enum.reduce(state.fetched, state.metadata, &adopt(&1, &2, vault_path))
        commits = adopt_commits(state.commits, state.fetched)
        {:ok, %{state | metadata: metadata, commits: commits, fetched: []}}
    end)
  end

  # What git does, file by file: with nothing fetched there is nothing to
  # replay onto; a fetched commit touching a path an unpushed one touched
  # stops the rebase at a conflict, the working tree left as it was; and
  # otherwise every fetched commit lands under the vault's own, which keep
  # their metadata — a rebase keeps a commit's author and its date.
  defp rebase(log, vault_path) do
    Agent.get_and_update(log, fn
      %{rebasing: paths} = state when is_list(paths) ->
        {{:error, "fatal: It seems that there is already a rebase-merge directory"}, state}

      %{fetched: []} = state ->
        {:ok, state}

      state ->
        ours = state.unpushed |> List.flatten() |> MapSet.new()

        case state.fetched |> Enum.map(& &1.path) |> Enum.filter(&(&1 in ours)) |> Enum.uniq() do
          [] ->
            metadata = Enum.reduce(state.fetched, state.metadata, &adopt(&1, &2, vault_path))
            commits = adopt_commits(state.commits, state.fetched)
            {:ok, %{state | metadata: metadata, commits: commits, fetched: []}}

          conflicting ->
            {{:conflict, conflicting}, %{state | rebasing: conflicting}}
        end
    end)
  end

  defp abort_rebase(log) do
    Agent.get_and_update(log, fn
      %{rebasing: nil} = state -> {{:error, "fatal: No rebase in progress?"}, state}
      state -> {:ok, %{state | rebasing: nil}}
    end)
  end

  defp adopt(%{path: path, content: content, author: author}, metadata, vault_path) do
    abs = Path.join(vault_path, path)
    File.mkdir_p!(Path.dirname(abs))
    File.write!(abs, content)

    entry =
      case metadata[path] do
        nil -> %{created_at: @elsewhere_at, updated_at: @elsewhere_at, last_author: author}
        entry -> %{entry | updated_at: @elsewhere_at, last_author: author}
      end

    Map.put(metadata, path, entry)
  end

  defp adopt_commits(commits, fetched) do
    Enum.reduce(fetched, commits, fn %{path: path, content: content, author: author}, commits ->
      email = "#{String.downcase(author)}@local"

      record_commit(
        commits,
        [{:put, path, content}],
        author,
        email,
        "update: #{path}",
        @elsewhere_at
      )
    end)
  end

  ## The history

  # A commit is recorded only when it changes something, as git makes none
  # for content the file already holds (`Vigil.Git.commit/3`).
  defp record_commit(commits, changes, author, email, message, at) do
    case Enum.reject(changes, &unchanged?(&1, commits)) do
      [] ->
        commits

      changes ->
        sha = sha(length(commits))

        commits ++
          [
            %{
              commit: sha,
              at: at,
              author: author,
              email: email,
              message: message,
              changes: changes
            }
          ]
    end
  end

  defp unchanged?({:put, path, content}, commits), do: content_at(commits, path) == {:ok, content}
  defp unchanged?(_change, _commits), do: false

  # A commit id is forty hex digits, like git's, and a different one for every
  # commit this adapter records.
  defp sha(n), do: :crypto.hash(:sha, "commit #{n}") |> Base.encode16(case: :lower)

  # Newest first, following the path back across every rename that led to it
  # — what `git log --follow` does.
  defp history(commits, path, limit) do
    commits
    |> Enum.reverse()
    |> Enum.reduce({path, []}, fn commit, {name, acc} ->
      case touches(commit, name) do
        nil -> {name, acc}
        previous -> {previous, [entry(commit, name) | acc]}
      end
    end)
    |> elem(1)
    |> Enum.reverse()
    |> Enum.take(limit)
  end

  # The name a path had before `commit`, when the commit touched it; nil when
  # it did not.
  defp touches(commit, name) do
    Enum.find_value(commit.changes, fn
      {:rename, from, ^name} -> from
      {:put, ^name, _} -> name
      {:remove, ^name} -> name
      _ -> nil
    end)
  end

  defp entry(commit, name), do: commit |> Map.delete(:changes) |> Map.put(:path, name)

  defp show(_commits, "-" <> _, _path), do: {:error, :unknown_revision}

  defp show(commits, rev, path) do
    case Enum.split_while(commits, &(&1.commit != rev)) do
      {_, []} ->
        {:error, :unknown_revision}

      {before, [commit | _]} ->
        upto = before ++ [commit]

        with {:ok, content} <- content_at(upto, path) do
          [%{at: at} | _] = history(upto, path, 1)
          {:ok, %{commit: commit.commit, content: content, updated_at: at}}
        end
    end
  end

  # What `path` holds after the last of `commits`.
  defp content_at(commits, path) do
    Enum.reduce(commits, {:error, :not_found}, fn commit, acc ->
      Enum.reduce(commit.changes, acc, fn
        {:put, ^path, content}, _ -> {:ok, content}
        {:remove, ^path}, _ -> {:error, :not_found}
        {:rename, ^path, _to}, _ -> {:error, :not_found}
        _, acc -> acc
      end)
    end)
  end

  # A push that is not a fast-forward is refused, as git refuses it.
  defp push(log) do
    Agent.get_and_update(log, fn
      %{remote_only: [], fetched: []} = state ->
        {:ok, %{state | unpushed: []}}

      state ->
        {{:error, "! [rejected] (fetch first): the remote contains work the vault does not have"},
         state}
    end)
  end

  defp remote_result(log, call, ours, theirs) do
    record(log, call)
    remote_known(ours, theirs)
  end

  defp remote_known({remote, branch}, {name, ref}) do
    cond do
      name != remote or is_nil(remote) ->
        {:error, "fatal: '#{name}' does not appear to be a git repository"}

      ref != branch ->
        {:error, "error: src refspec #{ref} does not match any"}

      true ->
        :ok
    end
  end

  defp tracking(nil, branch), do: {:ok, %{head: branch, remotes: [], branches: %{branch => nil}}}

  defp tracking(remote, branch),
    do: {:ok, %{head: branch, remotes: [remote], branches: %{branch => {remote, branch}}}}

  # Everything the vault holds when the adapter is built, as one commit by
  # whoever put it there. Without it every note in every test would carry a
  # `created_at` of `nil`.
  defp initial_commit(vault_path) do
    %{
      commit: sha(0),
      at: @initial_at,
      author: @initial_author,
      email: @initial_email,
      message: @initial_message,
      changes: for(path <- files(vault_path), do: {:put, path, read(vault_path, path)})
    }
  end

  defp files(vault_path) do
    Path.join(vault_path, "**")
    |> Path.wildcard(match_dot: false)
    |> Enum.filter(&File.regular?/1)
    |> Enum.map(&Path.relative_to(&1, vault_path))
  end

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
