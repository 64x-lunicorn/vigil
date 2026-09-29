defmodule Vigil.Git.CommitLog do
  @moduledoc """
  A `Vigil.Git` that remembers instead of shelling out — the second adapter
  `docs/design.md`, "Git is reached through a value", records.

  It keeps the history. What it is asked to commit is written down under the
  instant it was handed, authored as `vigil`, with what the commit changed —
  the content of every path it added, which it removed and which it renamed —
  and `log_metadata`, `history` and `show` answer out of that record, following
  a rename the way `git log --follow` does. A commit that changes nothing is
  not made, as git makes none. It reads no clock of its own. The alternative —
  an adapter answering "no metadata" — was rejected: it would put a
  `created_at` of `nil` under every test in the suite, which is a shape
  production never has.

  This is not a second metadata database. "Creation date = first commit"
  (`docs/design.md`, principle 3) is a claim about where a fact lives; what the
  seam states is narrower — a commit reports the instant and the author it was
  made under. Git satisfies that by being a metadata database, this satisfies
  it by remembering, and `test/vigil/git_test.exs` is what keeps the two from
  drifting apart.

  The remote is a record too. What `push_from_elsewhere/4` puts there is a
  commit another clone pushed, and `drop_from_elsewhere/2` is a force-push
  there that took commits away: `fetch` brings either into view,
  `divergence` counts them as behind or as `rewritten`, `fast_forward` writes
  what was pushed into the working tree, and `push` is refused while the
  remote holds anything the vault lacks — which is what git does with a push
  that is not a fast-forward — or while the vault holds what the remote had
  taken away. `rebase` replays the vault's own unpushed commits on top of
  what was fetched, drops what the remote took away, and stops at a conflict.
  A stopped rebase stays stopped until `abort_rebase`.

  **Where it is coarser than git.** A conflict here is a whole-file notion:
  any path one of the vault's own commits touched that a fetched or a dropped
  commit touched too. Git's is line-wise, so two edits to different parts of
  one note rebase cleanly under git and conflict here; and a replayed commit
  that only depends on what a dropped commit brought — without touching the
  same path — conflicts under git and applies here. The contract suite pins
  the one case both agree on, both sides changing the same note, and a test
  that needs anything finer belongs in the repository-only part of it.

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
  `tracking:` — what `tracking` answers, fixed; by default a clone with that
  one remote and that one branch checked out (unless `detach/1` detached
  HEAD), tracking its namesake there, and whether a rebase is in progress.
  """
  @spec recording(Path.t(), keyword()) :: {Git.t(), pid()}
  def recording(vault_path, opts \\ []) do
    remote = Keyword.get(opts, :remote, "origin")
    branch = Keyword.get(opts, :branch, "main")
    at = @commit_at

    {:ok, log} =
      Agent.start_link(fn ->
        %{
          # The branch's history, oldest first, each commit with what it
          # changed. `log_metadata` is read out of it, as git reads it out of
          # its own.
          commits: [initial_commit(vault_path)],
          # How many of `commits`, from the first, the remote-tracking branch
          # holds — and how many it has ever held, which is more than that
          # once a force-push elsewhere took some of them away. What lies
          # beyond `fork` is the vault's own: committed here, never pushed.
          base: 1,
          fork: 1,
          staged: [],
          calls: [],
          # The paths a stopped rebase could not apply, until it is aborted.
          rebasing: nil,
          detached: false,
          # Pushed from elsewhere, not fetched yet; fetched, not adopted yet;
          # and how many commits a force-push elsewhere took off the end of
          # the remote, not fetched yet.
          remote_only: [],
          fetched: [],
          remote_drop: 0
        }
      end)

    ours = {remote, branch}

    tracking =
      case Keyword.fetch(opts, :tracking) do
        {:ok, answer} -> fn -> answer end
        :error -> fn -> Agent.get(log, &tracking(&1, remote, branch)) end
      end

    git =
      Git.new(
        push: fn _vault, name, ref ->
          with :ok <- remote_result(log, {:push, name, ref}, ours, {name, ref}), do: push(log)
        end,
        divergence: fn _vault, name, ref ->
          with :ok <- remote_known(ours, {name, ref}), do: {:ok, Agent.get(log, &divergence/1)}
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
        tracking: fn _vault -> tracking.() end,
        log_metadata: fn _vault -> Agent.get(log, &metadata(&1.commits)) end,
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
          commit(log, vault, paths, message, at)
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

  @doc """
  A force-push from another clone that took the last `count` commits off the
  remote — `git reset --hard HEAD~<count>` and `git push --force` there. The
  vault sees it after a `fetch`. A `push_from_elsewhere/4` after it lands on
  top of what is left.
  """
  @spec drop_from_elsewhere(pid(), pos_integer()) :: :ok
  def drop_from_elsewhere(log, count) do
    Agent.update(log, fn %{remote_only: []} = state ->
      %{state | remote_drop: state.remote_drop + count}
    end)
  end

  @doc "`git checkout --detach`: HEAD on the branch's commit, no branch checked out."
  @spec detach(pid()) :: :ok
  def detach(log), do: Agent.update(log, &%{&1 | detached: true})

  ## The record

  defp record(log, call), do: Agent.update(log, &%{&1 | calls: [call | &1.calls]})

  # The staging area is the list of what `add`, `remove` and `move` did, in
  # order, and nothing reaches the record until it is committed — which is
  # what makes a restored index observable here: a change staged and never
  # committed would otherwise be swept into the next commit's metadata.
  defp stage(log, changes) do
    Agent.update(log, &%{&1 | staged: &1.staged ++ changes})
  end

  # A commit authored as vigil, of everything staged — or, when nothing staged
  # changes anything, none at all, as `Vigil.Git.commit/3` makes none. Either
  # way the answer is the last commit that touched the paths, which is what
  # git answers. A detached HEAD is refused before anything is committed.
  defp commit(log, vault_path, paths, message, at) do
    Agent.get_and_update(log, fn
      %{detached: true} = state ->
        {{:error, "HEAD is detached: vigil commits only onto a checked-out branch"}, state}

      state ->
        changes = Enum.flat_map(state.staged, &change(&1, vault_path))
        commits = record_commit(state.commits, changes, "vigil", "vigil@local", message, at)
        {{:ok, last_touching(commits, paths)}, %{state | staged: [], commits: commits}}
    end)
  end

  defp last_touching(commits, paths) do
    commit =
      commits
      |> Enum.reverse()
      |> Enum.find(fn commit -> Enum.any?(paths, &(&1 in changed_paths([commit]))) end)

    %{updated_at: commit.at, last_author: commit.author}
  end

  # What `git log` makes of the history: the first commit a path had is what
  # principle 3 calls its creation date, every later one only moves
  # `updated_at`. A removal leaves the record as it was — `log_metadata`
  # reads additions, modifications and renames only — so a note deleted and
  # written again keeps the creation date it had. A rename carries the old
  # path's record to the new one.
  defp metadata(commits) do
    Enum.reduce(commits, %{}, fn commit, metadata ->
      Enum.reduce(commit.changes, metadata, &metadata_change(&1, &2, commit))
    end)
  end

  defp metadata_change({:put, path, _content}, metadata, commit),
    do: Map.put(metadata, path, touch(metadata[path], commit))

  defp metadata_change({:remove, _path}, metadata, _commit), do: metadata

  defp metadata_change({:rename, from, to}, metadata, commit) do
    {entry, metadata} = Map.pop(metadata, from)
    Map.put(metadata, to, touch(entry, commit))
  end

  defp touch(nil, commit),
    do: %{created_at: commit.at, updated_at: commit.at, last_author: commit.author}

  defp touch(entry, commit), do: %{entry | updated_at: commit.at, last_author: commit.author}

  # What a staged change leaves in the history: the content an added path
  # holds now, a removal, or a rename carrying the content it arrived with.
  defp change({:add, path}, vault_path), do: [{:put, path, read(vault_path, path)}]
  defp change({:remove, path}, _vault_path), do: [{:remove, path}]

  defp change({:rename, from, to}, vault_path),
    do: [{:rename, from, to}, {:put, to, read(vault_path, to)}]

  defp read(vault_path, path), do: File.read!(Path.join(vault_path, path))

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

  # What `git rev-list --left-right --count` and `git merge-base --fork-point`
  # say: the commits only the branch holds, the ones only the remote-tracking
  # branch holds, and of the first, the ones the remote once held and a
  # force-push took away.
  defp divergence(state) do
    %{
      ahead: length(state.commits) - state.base,
      behind: length(state.fetched),
      rewritten: state.fork - state.base
    }
  end

  # A forced fetch: the remote-tracking branch says what the remote holds,
  # even when a force-push there took commits away. What it took is counted
  # off the end of what was fetched first, and then off the vault's own
  # history; `fork` remembers how far the remote-tracking branch once went.
  defp fetch(log) do
    Agent.update(log, fn state ->
      {base, fetched} = drop_remote(state.base, state.fetched, state.remote_drop)

      %{
        state
        | base: base,
          fetched: fetched ++ state.remote_only,
          remote_only: [],
          remote_drop: 0
      }
    end)
  end

  defp drop_remote(base, fetched, count) when count <= length(fetched),
    do: {base, Enum.drop(fetched, -count)}

  defp drop_remote(base, fetched, count), do: {base - (count - length(fetched)), []}

  # What git does: nothing to adopt is not an error, a branch with commits of
  # its own cannot be fast-forwarded, and otherwise every fetched commit lands
  # in the working tree and in the history, under its own author.
  defp fast_forward(log, vault_path) do
    Agent.get_and_update(log, fn
      %{fetched: []} = state ->
        {:ok, state}

      %{commits: commits, base: base} = state when length(commits) > base ->
        {{:error, "fatal: Not possible to fast-forward, aborting."}, state}

      state ->
        commits = adopt_commits(state.commits, state.fetched)
        write_tree(vault_path, commits, changed_paths(state.fetched))

        {:ok,
         %{state | commits: commits, base: length(commits), fork: length(commits), fetched: []}}
    end)
  end

  # What `Vigil.Git.rebase/3` does, file by file. The vault's own commits —
  # the ones beyond `fork`, which the remote never held — are replayed on top
  # of what was fetched; the ones a force-push took off the remote are
  # dropped rather than replayed, and the working tree loses what they
  # brought. With nothing fetched and nothing dropped there is nothing to do.
  # A path one of the vault's own commits touched that a fetched or a dropped
  # commit touched too stops the rebase at a conflict, the working tree left
  # as it was — a whole-file notion of a conflict (see the moduledoc).
  defp rebase(log, vault_path) do
    Agent.get_and_update(log, fn
      %{rebasing: paths} = state when is_list(paths) ->
        {{:error, "fatal: It seems that there is already a rebase-merge directory"}, state}

      %{fetched: [], base: same, fork: same} = state ->
        {:ok, state}

      state ->
        {kept, rest} = Enum.split(state.commits, state.base)
        {dropped, own} = Enum.split(rest, state.fork - state.base)
        theirs = Enum.uniq(changed_paths(state.fetched) ++ changed_paths(dropped))
        ours = MapSet.new(changed_paths(own))

        case Enum.filter(theirs, &(&1 in ours)) do
          [] ->
            onto = adopt_commits(kept, state.fetched)
            commits = onto ++ own
            write_tree(vault_path, commits, theirs)

            {:ok,
             %{state | commits: commits, base: length(onto), fork: length(onto), fetched: []}}

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

  # Every path a list of commits touched — fetched ones, which are one path
  # each, or recorded ones, with their changes.
  defp changed_paths(commits) do
    Enum.flat_map(commits, fn
      %{changes: changes} ->
        Enum.flat_map(changes, fn
          {:put, path, _content} -> [path]
          {:remove, path} -> [path]
          {:rename, from, to} -> [from, to]
        end)

      %{path: path} ->
        [path]
    end)
  end

  # The working tree brought to what `commits` say about `paths`: the content
  # each holds after the last of them, or no file at all.
  defp write_tree(vault_path, commits, paths) do
    Enum.each(paths, fn path ->
      abs = Path.join(vault_path, path)

      case content_at(commits, path) do
        {:ok, content} ->
          File.mkdir_p!(Path.dirname(abs))
          File.write!(abs, content)

        {:error, :not_found} ->
          File.rm(abs)
      end
    end)
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
        sha = sha(System.unique_integer([:positive]))

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
  # commit this adapter records — a rebase that drops or replays commits
  # never hands one out twice.
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

  # A push that is not a fast-forward is refused, as git refuses it; and one
  # that would put back what a force-push elsewhere took off the remote is
  # refused before it is tried, as `Vigil.Git.push/3` refuses it.
  defp push(log) do
    Agent.get_and_update(log, fn
      %{fork: fork, base: base} = state when fork > base ->
        {{:error,
          "the remote's history was rewritten: #{fork - base} commit(s) the vault holds were taken off it"},
         state}

      %{remote_only: [], fetched: []} = state ->
        pushed = length(state.commits)
        {:ok, %{state | base: pushed, fork: pushed, remote_drop: 0}}

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

  # A clone with the one remote and the one branch, tracking its namesake
  # there; HEAD on it unless detached — and, like `Vigil.Git.tracking/1`, on
  # it while a rebase of it is in progress.
  defp tracking(state, remote, branch) do
    head = if state.detached, do: nil, else: branch
    rebasing = state.rebasing != nil

    case remote do
      nil ->
        {:ok, %{head: head, remotes: [], branches: %{branch => nil}, rebasing: rebasing}}

      remote ->
        {:ok,
         %{
           head: head,
           remotes: [remote],
           branches: %{branch => {remote, branch}},
           rebasing: rebasing
         }}
    end
  end

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
end
