defmodule Vigil.Store do
  @moduledoc false
  use GenServer
  require Logger

  alias Vigil.{
    Clock,
    Commit,
    Events,
    Index,
    Parser,
    Git,
    RequestLog,
    Skills
  }

  alias Vigil.Settings
  alias Vigil.Vault.{Decision, Domains, Facts, Layout, Plan, Policy}

  # The name a writer registers under, and — the same atom — the name of the
  # table it publishes through. Production registers under it and hands in no
  # name of its own: every caller that names no writer reaches this one. A
  # caller that supplies a name gets a writer of its own, which is what lets
  # the vault-backed test files run in parallel — one writer per file, rather
  # than one for the whole suite to queue behind.
  #
  # The atom is stated here and asked for through `default_name/0` where a
  # caller needs it as its own default (`Vigil.MCP.Tools`), so the name a
  # writer is found under is one fact rather than one per caller.
  #
  # What the table is for: readers that must not queue behind the writer. It is
  # written from inside it — at init for the vault path, on every index change
  # for the event notes — which is what makes a public table safe to read
  # anywhere else.
  @default_name __MODULE__

  ## Public API

  @doc """
  The name production registers a writer under, for a caller that defaults to
  it rather than restating it.
  """
  @spec default_name() :: atom()
  def default_name, do: @default_name

  def start_link(opts) do
    name = Keyword.get(opts, :name, @default_name)
    GenServer.start_link(__MODULE__, Keyword.put(opts, :name, name), name: name)
  end

  # Every tool-facing call has one shape: the operation, and a map of that
  # operation's parameters. What differs between two tools is the map, not the
  # function, so a parameter added to a tool is a change to Vigil.MCP.Tools'
  # table and to the handler that reads it — not to a client function, a
  # message shape and a `handle_call` clause as well.
  #
  # There is a head per operation and no catch-all, because the head is where
  # a broken contract belongs (docs/design.md, "The write path"): it matches
  # what its operation cannot do without, so a `search` without a `limit`, a
  # `links` without a depth, a `read` without an id fail in the caller's own
  # process rather than reaching the single writer.
  # A head matching a bare map has nothing of its own to state: `lint`,
  # `current` and `reload` declare no parameter, and the six
  # writes state their contracts in Vigil.Vault.Policy, the one gate every
  # write goes through. Vigil.MCP.Tools declares every bound and default (`limit` 1..25
  # default 10, `depth` 1..2 default 1, `backlinks` default false) and
  # supplies a value on every call, so nothing here restates one.
  def call(store \\ @default_name, op, params)

  def call(store, :search, %{limit: _} = params), do: request(store, :search, params)
  def call(store, :read, %{id: _, backlinks: _} = params), do: request(store, :read, params)

  def call(store, :links, %{id: _, direction: _, depth: _} = params),
    do: request(store, :links, params)

  def call(store, :create, %{} = params), do: request(store, :create, params)
  def call(store, :append, %{} = params), do: request(store, :append, params)

  def call(store, :replace_section, %{id: _, content: _} = params),
    do: request(store, :replace_section, params)

  def call(store, :rewrite_note, %{} = params), do: request(store, :rewrite_note, params)
  def call(store, :delete_section, %{id: _} = params), do: request(store, :delete_section, params)

  def call(store, :update_frontmatter, %{} = params),
    do: request(store, :update_frontmatter, params)

  def call(store, :delete_note, %{} = params), do: request(store, :delete_note, params)
  def call(store, :move_note, %{} = params), do: request(store, :move_note, params)
  # The two rows that resolve an instant. Vigil.MCP.Tools puts the response's
  # envelope instant into the params of every row declaring `now:`, so in
  # production nothing is resolved here; the fallback covers a caller with no
  # envelope to share one, which is a test pinning a moment. It is resolved in
  # the caller's process rather than behind the writer's mailbox for the
  # reason bd7e842 removed the other one: a clock read on the far side of the
  # writer can land in a different minute than the response it belongs to.
  def call(store, :lint, %{} = params), do: request(store, :lint, with_now(store, params))
  def call(store, :current, %{} = params), do: request(store, :current, with_now(store, params))
  def call(store, :reload, %{} = params), do: request(store, :reload, params)

  def call(store, :skill_write, %{name: _, content: _} = params),
    do: request(store, :skill_write, params)

  # Longer than anything the writer can be busy with: a write is bounded by
  # its push, and Vigil.Git bounds the network calls well inside this. The
  # default 5 s let a caller give up on a write that then completed anyway —
  # the client saw an error, retried, and the content landed twice.
  @call_timeout 120_000

  defp request(store, op, params), do: GenServer.call(store, {op, params}, @call_timeout)

  defp with_now(store, params),
    do: Map.put_new_lazy(params, :now, fn -> Clock.now(published_tz(store)) end)

  # The five the index answers. Each names the Vigil.Index function that
  # answers it, which is what lets one `handle_call` clause cover all of them.
  @read_ops [:search, :read, :links, :lint, :current]

  # The eight that go through the write path (docs/design.md, "The write
  # path"): Vigil.Vault.Policy and Vigil.Vault.Plan already take the operation
  # as an argument, so one `handle_call` clause covers all of them.
  @write_ops [
    :create,
    :append,
    :replace_section,
    :rewrite_note,
    :delete_section,
    :update_frontmatter,
    :delete_note,
    :move_note
  ]

  # Not tool-facing: the time envelope Vigil.MCP.Envelope attaches to every
  # tool result, and the raw _domains.yml text the same server puts into its
  # `initialize` response.
  #
  # The snapshot is computed in the caller, out of the event notes this module
  # publishes on every index change — the same reason Vigil.MCP.Envelope's own
  # table is public. A response already costs one call into this writer, the
  # tool's own; the envelope that goes on top of it must not cost a second,
  # which for a write tool would land after the write.
  def snapshot(store \\ @default_name, now), do: Events.snapshot(published_events(store), now)

  # Where the vault is, for the two callers that need it without the mailbox:
  # `skill_list` and `skill_read` are answered in the caller's process
  # (Vigil.MCP.Tools), because a skill read is the mandatory bootstrap before
  # every write and must not queue behind the push of the write before it.
  # Written once at init and never again — this process is bound to one vault
  # for its whole life.
  def vault_path(store \\ @default_name), do: :ets.lookup_element(store, :vault_path, 2)

  def instructions_domains_text(store \\ @default_name),
    do: GenServer.call(store, :instructions_domains_text, @call_timeout)

  # No fallback for a missing table. It lives with this process, so its absence
  # means the writer is down — and the response is going to fail at the tool
  # call regardless, exactly as it did when the snapshot was a call into a
  # process that was not there. Answering "no events" instead would be worse
  # than failing: Vigil.MCP.Envelope records what it decided against as the
  # session's state, so an empty snapshot would be read as every active event
  # having finished, and the next response would report a phase change that
  # never happened.
  defp published_events(store), do: :ets.lookup_element(store, :events, 2)

  # The vault's timezone, published beside its path so a caller resolving its
  # own instant reads the deployment the writer was built with rather than the
  # application environment. Written once at init and never again — and kept
  # only here, not in the state as well: the writer reads it back out of its
  # own table, so there is one copy of the fact and nothing that could hold a
  # second one that has drifted.
  defp published_tz(store), do: :ets.lookup_element(store, :tz, 2)

  ## GenServer

  @impl true
  def init(opts) do
    # start_link/1 puts the name in, defaulted or supplied, so there is one
    # statement of what it defaults to and this reads it.
    name = Keyword.fetch!(opts, :name)
    vault_path = Keyword.fetch!(opts, :vault_path) |> Path.expand()
    exclude = Keyword.get(opts, :exclude, [])
    git_remote = Keyword.get(opts, :git_remote, "origin")
    git_branch = Keyword.get(opts, :git_branch, "main")

    # The one default, in the one place that has configuration to build it
    # from (docs/design.md, "Git is reached through a value"). Vigil.Skills
    # has none and is handed this value; a caller that hands one in here is
    # saying which git this vault has, and the repository check goes with the
    # adapter that needs one rather than staying behind as a claim about a
    # vault nobody is going to shell out into.
    git = Keyword.get_lazy(opts, :git, fn -> over_repository!(vault_path) end)

    # What the deployment says about itself, resolved once where the tree is
    # built and handed in. Only the timezone is this writer's business, and
    # only for a write that arrived without an instant of its own.
    settings = Keyword.get_lazy(opts, :settings, &Settings.from_env/0)

    if :ets.whereis(name) == :undefined do
      :ets.new(name, [:set, :named_table, :public, read_concurrency: true])
    end

    :ets.insert(name, {:vault_path, vault_path})
    :ets.insert(name, {:tz, settings.tz})

    state = %{
      table: name,
      vault_path: vault_path,
      exclude: exclude,
      git_remote: git_remote,
      git_branch: git_branch,
      git: git,
      domains: %{},
      index: %Index{},
      requests: RequestLog.new(),
      # The last push this writer made: nil until the first one.
      last_push: nil
    }

    {state, pull_result} = do_full_load(state)

    case pull_result do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("vigil: initial update from the remote failed: #{reason}")
    end

    {:ok, state}
  end

  defp over_repository!(vault_path) do
    unless File.dir?(Path.join(vault_path, ".git")) do
      raise "VIGIL_VAULT_PATH #{vault_path} is not a git repository or does not exist"
    end

    Git.over_repository()
  end

  # One message shape for all of them: {operation, params}. The five reads and
  # the eight writes share one clause each, because in both groups the
  # operation is the only difference: Vigil.Index names each read's answer,
  # and Vigil.Vault.Policy and Vigil.Vault.Plan already take the write as an
  # argument.
  #
  # A read makes no decision here: the params map is handed on exactly as the
  # tool table describes it, so a parameter added to a read tool is a change
  # to the table and to the index function that reads it, and to nothing in
  # between. The operation *is* the name of that function, which is what
  # collapses the five clauses into one — and what the compiler cannot check.
  # The dispatch coverage in Vigil.MCP.ServerTest drives every declared tool
  # end to end, which is where a row whose `call:` no longer names an index
  # function fails (docs/design.md, "MCP tool schemas are authoritative").
  @impl true
  def handle_call({op, params}, _from, state) when op in @read_ops do
    {:reply, apply(Index, op, [state.index, params]), state}
  end

  def handle_call({op, params}, _from, state) when op in @write_ops do
    {result, new_state} =
      once(op, params, state, &in_step(&1, &2, fn params, state -> write(op, params, state) end))

    {:reply, result, new_state}
  end

  def handle_call({:reload, _params}, _from, state) do
    {state, pull_result} = do_full_load(state)
    {:reply, reload_result(pull_result), state}
  end

  def handle_call({:skill_write, params}, _from, state) do
    {result, new_state} =
      once(:skill_write, params, state, fn params, state ->
        in_step(params, state, fn params, state ->
          {do_skill_write(params.name, params.content, state), state}
        end)
      end)

    {:reply, result, new_state}
  end

  def handle_call({:status, _params}, _from, state) do
    {ahead, behind} =
      case state.git.divergence.(state.vault_path, state.git_remote, state.git_branch) do
        {:ok, %{ahead: ahead, behind: behind}} -> {ahead, behind}
        {:error, _reason} -> {nil, nil}
      end

    {:reply, %{ahead: ahead, behind: behind, last_push: state.last_push}, state}
  end

  def handle_call(:instructions_domains_text, _from, state) do
    {:reply, domains_yaml_raw(state.vault_path), state}
  end

  defp reload_result(:ok), do: %{reloaded: true}
  defp reload_result({:error, reason}), do: %{reloaded: true, pull_failed: reason}

  ## A retried write is applied once
  #
  # A write can outlive the client's call timeout and still complete here; the
  # client sees an error and retries (docs/design.md, "A retried write is
  # applied once"). A write that names itself with a `request_id` is performed
  # once: a repeat answers the first write's result with `already_applied:
  # true` and writes nothing. The same id for a different write is refused
  # rather than answered with a result that is not its own.
  #
  # `request_id` is popped here, like `now`, so what the write path is handed
  # is the request the operation declares. The fingerprint leaves `now` out
  # too: a retry's envelope is decided at its own instant, and that does not
  # make it another write. Only a success is remembered — a refused or failed
  # write changed nothing, and its corrected retry must be free to run.
  #
  # Checking and performing happen in one `handle_call`, inside the single
  # writer, so a retry that arrives while the first call is still running
  # queues behind it and finds its id.
  defp once(op, params, state, perform) do
    case Map.pop(params, :request_id) do
      {nil, params} ->
        perform.(params, state)

      {id, params} ->
        fingerprint = {op, Map.delete(params, :now)}
        now = System.monotonic_time(:millisecond)

        case RequestLog.lookup(state.requests, id, fingerprint, now) do
          {:applied, {:ok, result}} ->
            {{:ok, Map.put(result, :already_applied, true)}, state}

          :conflict ->
            {{:error,
              "request_id #{id} was already used for a different write. " <>
                "Use a new request_id for every distinct write."}, state}

          :unknown ->
            {result, state} = perform.(params, state)
            {result, remember(state, id, fingerprint, result, now)}
        end
    end
  end

  defp remember(state, id, fingerprint, {:ok, _} = result, now),
    do: %{state | requests: RequestLog.remember(state.requests, id, fingerprint, result, now)}

  defp remember(state, _id, _fingerprint, _result, _now), do: state

  ## Staying in step with the remote
  #
  # How many times a push the remote refused is rebased and tried again before
  # the write gives up and says so. Each round is a fetch, a rebase and a push;
  # a remote that moves this often between two of them is being written to by
  # something that should be looked at.
  @push_retries 3

  # docs/design.md, "The server stays in step with the remote". A human who
  # pushes and never calls `reload` used to make the next push fail: vigil
  # committed on top of a history the remote had already moved past. So every
  # write — the eight note writes and `skill_write` — is performed on a vault
  # brought up to date first, a push the remote refuses because it moved in
  # the meantime is rebased and tried again, and the push it ends with is
  # noted for `status`.
  defp in_step(params, state, perform) do
    before = state.index
    state = bring_up_to_date(state)
    {result, state} = perform.(params, state)
    result = changed_under(result, params, before, state.index)
    {result, state} = push_again(result, state, @push_retries)
    {result, note_push(state, result)}
  end

  # The one place that decides whether the vault adopts what the remote holds,
  # and how: asked before every write, and — through update/1 — by the load at
  # boot and on `reload`.
  #
  # If the remote moved, the vault is brought on top of it and the index
  # rebuilt, so the write is decided against the vault as it now stands and
  # lands on top of what the human pushed. Anything else — a fetch that fails,
  # a rebase that conflicts — is logged and changes nothing: the write goes
  # ahead on the vault as it was, and its push says what is in the way.
  defp bring_up_to_date(state) do
    case update(state) do
      :moved ->
        load(state)

      :in_step ->
        state

      {_error_or_conflict, reason} ->
        Logger.warning("vigil: could not bring the vault up to date: #{reason}")
        state
    end
  end

  # What the remote holds, adopted — with no index rebuilt, which is the
  # caller's: the load builds one regardless, a write only when something
  # moved. `:moved | :in_step | {:conflict, reason} | {:error, reason}`.
  #
  # With no unpushed commits of its own the vault fast-forwards. With some, it
  # rebases them onto the remote — vigil's own single-file commits replayed on
  # top of whatever was pushed, merge commits included (principle 2). A rebase
  # that conflicts is aborted at once: vigil's commits stay local, nothing on
  # the remote is overwritten, and which paths are in the way is the answer.
  defp update(state) do
    %{git: git, vault_path: vault_path, git_remote: remote, git_branch: branch} = state

    with :ok <- git.fetch.(vault_path, remote, branch),
         {:ok, %{behind: behind} = divergence} when behind > 0 <- divergence(state),
         :ok <- adopt(git, vault_path, remote, branch, divergence) do
      Logger.info("vigil: adopted #{behind} commit(s) from #{remote}/#{branch}")
      :moved
    else
      {:ok, %{behind: 0}} -> :in_step
      {:conflict, reason} -> {:conflict, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  defp adopt(git, vault_path, remote, branch, %{ahead: 0}),
    do: git.fast_forward.(vault_path, remote, branch)

  defp adopt(git, vault_path, remote, branch, _unpushed) do
    case git.rebase.(vault_path, remote, branch) do
      {:conflict, paths} ->
        git.abort_rebase.(vault_path)
        {:conflict, conflict(paths, remote, branch)}

      {:error, reason} ->
        # A rebase that failed for any other reason may still have begun;
        # aborting one that did not is refused, and harmless.
        git.abort_rebase.(vault_path)
        {:error, reason}

      :ok ->
        :ok
    end
  end

  defp conflict(paths, remote, branch) do
    "Rebasing vigil's unpushed commits onto #{remote}/#{branch} conflicts in " <>
      "#{Enum.join(paths, ", ")}. The rebase was aborted: vigil's commits stay local, " <>
      "nothing on the remote was overwritten, and a human has to resolve the conflict"
  end

  defp divergence(state),
    do: state.git.divergence.(state.vault_path, state.git_remote, state.git_branch)

  # A push that failed because the remote moved between the update and the
  # push is rebased onto it and tried again, a bounded number of times. Which
  # failure it was is not read out of git's words: the vault fetches, and a
  # remote that holds nothing new means the push failed for some other reason
  # — an unreachable remote, a refusal — which a rebase cannot help.
  #
  # A conflict or the limit, whichever stops the retries, is added to the push
  # error the write already carries, after git's own reason.
  defp push_again({:ok, %{pushed: false} = report}, state, 0) do
    {{:ok,
      more_push_error(
        report,
        "Rebased onto #{state.git_remote}/#{state.git_branch} and pushed again " <>
          "#{@push_retries} times, and the remote had moved on every time. " <>
          "The commit stays local and goes out with the next push that succeeds"
      )}, state}
  end

  defp push_again({:ok, %{pushed: false} = report} = result, state, retries) do
    case update(state) do
      :moved ->
        state = load(state)

        case Commit.push(state.git, state.vault_path, state.git_remote, state.git_branch) do
          :ok -> {{:ok, report |> Map.put(:pushed, true) |> Map.delete(:push_error)}, state}
          {:error, _reason} -> push_again(result, state, retries - 1)
        end

      {:conflict, reason} ->
        {{:ok, more_push_error(report, reason)}, state}

      _in_step_or_error ->
        {result, state}
    end
  end

  defp push_again(result, state, _retries), do: {result, state}

  defp more_push_error(report, sentence),
    do: %{report | push_error: "#{String.trim_trailing(report.push_error)}. #{sentence}."}

  # A section id that resolved before the update and does not after it names
  # a section the remote changed underneath the caller: what it read is gone.
  # "Not found" would be true and would not say what to do about it.
  defp changed_under({:error, "Not found: " <> id} = result, %{id: id}, before, now)
       when before != now do
    if Index.find_chunk(before, id) != nil and Index.find_chunk(now, id) == nil do
      {:error,
       "#{id} no longer resolves: the note changed on the remote since it was read. " <>
         "Read it again before editing it."}
    else
      result
    end
  end

  defp changed_under(result, _params, _before, _now), do: result

  # A write that got as far as its push says so in its result, as `pushed:`
  # and `push_error:` — a note write and a skill write alike. A write refused
  # or failed before it leaves the last push as it was.
  defp note_push(state, {:ok, %{pushed: pushed} = result}) do
    at = DateTime.utc_now() |> DateTime.truncate(:second)

    last_push =
      if pushed,
        do: %{pushed: true, at: at},
        else: %{pushed: false, at: at, error: result.push_error}

    %{state | last_push: last_push}
  end

  defp note_push(state, _result), do: state

  ## Status

  # How long `status/2` waits for the writer before it says the writer does not
  # answer. A write in progress holds the writer until its push is done, so a
  # healthy writer can take a while; one that takes longer than this is what
  # the answer is for.
  @status_timeout 5_000

  @doc """
  Whether this writer is serving, and how it stands with the remote — what
  the `status` tool and `/healthz` report (docs/design.md, "The server stays
  in step with the remote").

  Asked in the caller's process: whether the index is loaded is read from the
  writer's table, and the writer is asked the rest with a timeout of its own,
  so a writer that does not answer is reported rather than waited on.
  `ahead` and `behind` are `nil` when the writer does not answer or the clone
  cannot count them; `behind` is as fresh as the last fetch.
  """
  @spec status(atom(), timeout()) :: map()
  def status(store \\ @default_name, timeout \\ @status_timeout) do
    index_loaded = index_loaded?(store)

    sync =
      try do
        {:ok, GenServer.call(store, {:status, %{}}, timeout)}
      catch
        :exit, _reason -> :no_answer
      end

    case sync do
      {:ok, sync} ->
        Map.merge(sync, %{index_loaded: index_loaded, writer_answers: true, healthy: index_loaded})

      :no_answer ->
        %{
          index_loaded: index_loaded,
          writer_answers: false,
          healthy: false,
          ahead: nil,
          behind: nil,
          last_push: nil
        }
    end
  end

  # The event notes are published by put_index/2, which every load goes
  # through, into a table that lives and dies with the writer: present means
  # an index was built, absent means the writer is down or still loading.
  defp index_loaded?(store) do
    :ets.whereis(store) != :undefined and :ets.member(store, :events)
  rescue
    ArgumentError -> false
  end

  ## Loading

  # At boot and on `reload`: the vault brought up to date the way a write
  # brings it (update/1), unpushed commits of vigil's own rebased rather than
  # refused, and then read. What stopped the update — an unreachable remote, a
  # conflict — is what `reload` reports as `pull_failed`; the vault is read
  # regardless, as it stands.
  defp do_full_load(state) do
    pull_result =
      case update(state) do
        {_error_or_conflict, reason} -> {:error, reason}
        _moved_or_in_step -> :ok
      end

    {load(state), pull_result}
  end

  # The vault as it now stands on disk, read into a new index: at boot and on
  # `reload`, and whenever an update before or after a write moved it.
  defp load(state) do
    git_meta = state.git.log_metadata.(state.vault_path)
    domains = load_domains(state.vault_path)

    layout = layout(state)

    log_warnings(Domains.mismatches(domains, layout.domains))

    loaded =
      layout
      |> Layout.note_paths()
      |> Enum.map(&load_file(state.vault_path, &1, git_meta))

    parsed_files = for {:ok, file} <- loaded, do: file
    invalid_utf8 = for {:invalid_utf8, path} <- loaded, do: path

    index = Index.build(parsed_files, invalid_utf8)
    sizes = Index.size(index)

    Logger.info(
      "vigil: #{length(layout.domains)} domains (#{Enum.join(layout.domains, ", ")}), #{sizes.notes} notes, #{sizes.chunks} chunks"
    )

    put_index(%{state | domains: domains}, index)
  end

  # One file that cannot be read or is not UTF-8 costs that file, never the
  # load: a raise here is a restart loop at boot (docs/design.md, "A note that
  # is not UTF-8 is skipped"). The skipped path is kept for `lint`.
  defp load_file(vault_path, rel_path, git_meta) do
    abs_path = Path.join(vault_path, rel_path)

    with {:ok, content} <- File.read(abs_path),
         meta =
           Map.get(git_meta, rel_path, %{created_at: nil, updated_at: nil, last_author: nil}),
         {:ok, file} <- Parser.parse(rel_path, content, meta) do
      {:ok, file}
    else
      {:error, :invalid_utf8} ->
        Logger.warning("skipping #{rel_path}: not valid UTF-8")
        {:invalid_utf8, rel_path}

      {:error, reason} ->
        Logger.warning("cannot read #{rel_path}: #{inspect(reason)}")
        :unreadable
    end
  end

  # Reading the file is this module's job; understanding it is
  # Vigil.Vault.Domains'. A broken or missing file costs at most the naming
  # rules — the vault still loads (docs/design.md, "_domains.yml is a
  # description, not configuration").
  #
  # First of two readers of _domains.yml, and deliberately the slower one: what
  # this parses feeds the write policy, so it is refreshed at startup and on
  # `reload` only and never shifts underneath a write. domains_yaml_raw/1 reads
  # the same file per MCP `initialize`; that divergence is the decision recorded
  # in docs/design.md, "_domains.yml is a description, not configuration", not
  # an oversight.
  defp load_domains(vault_path) do
    path = Path.join(vault_path, "_domains.yml")

    case File.read(path) do
      {:ok, content} ->
        {domains, warnings} = Domains.parse(content)
        log_warnings(warnings)
        domains

      {:error, :enoent} ->
        Logger.warning("_domains.yml is missing")
        %{}

      {:error, reason} ->
        Logger.warning("cannot read _domains.yml: #{Commit.fs_error(reason)}")
        %{}
    end
  end

  defp log_warnings(warnings) do
    Enum.each(warnings, fn warning -> Logger.warning(Domains.format(warning)) end)
  end

  # Second reader of _domains.yml, with its own freshness policy on purpose: the
  # raw text goes into the MCP `instructions` and is re-read from disk on every
  # `initialize`, so an edited file reaches the next session without a `reload`
  # (docs/design.md, "_domains.yml is a description, not configuration"). An
  # absent file is already warned about at load, so only a file that exists and
  # still cannot be read is worth a warning here.
  defp domains_yaml_raw(vault_path) do
    path = Path.join(vault_path, "_domains.yml")

    case File.read(path) do
      {:ok, content} ->
        content

      {:error, reason} ->
        if File.exists?(path) do
          Logger.warning("cannot read _domains.yml: #{Commit.fs_error(reason)}")
        end

        ""
    end
  end

  ## Vault facts for Vigil.Vault.Policy

  # Built fresh per write, and built by Vigil.Vault.Facts — the module that
  # defines the seam names both of its answer sets, so what the production one
  # claims is checkable without a git repository or a running writer. What is
  # this module's is gathering the plain facts: the vault's layout, and what
  # _domains.yml says about naming.
  #
  # The layout is read from disk per write rather than carried in the state,
  # and deliberately: a project directory a write creates has to be there for
  # the next write's gate, and a domain added on disk is writable without a
  # reload. The load builds one of its own, out of the same function.
  #
  # `now` is the instant the write's own response's envelope was decided at
  # (Vigil.MCP.Envelope.for_tool/5), passed through rather than read here.
  defp facts(state, now) do
    Facts.over_vault(
      state.index,
      %{layout: layout(state), naming: naming_rules(state)},
      now
    )
  end

  defp layout(state), do: Layout.over_vault(state.vault_path, state.exclude)

  defp abs(state, rel_path), do: Path.join(state.vault_path, rel_path)

  defp naming_rules(state), do: Domains.naming_rules(state.domains)

  ## The write path
  #
  # Eight operations, one sequence: ask the policy, read the note, shape the
  # write, then perform it. Only the last step is an effect, and only the two
  # middle steps differ between operations — Vigil.Vault.Plan holds the
  # difference, this holds the sequence. Every failure before the effect
  # leaves the state untouched, said once here rather than at each site.

  # `now` travels under the same key Vigil.MCP.Tools puts every declared
  # instant under, but it is not one of the operation's declared parameters
  # (docs/design.md, "The write path") — it is popped back out here so what
  # Vigil.Vault.Policy and Vigil.Vault.Plan are handed is exactly the
  # request the tool table describes, unchanged. A caller with no envelope
  # to share (a test pinning a moment aside) gets the writer's own clock.
  defp write(op, request, state) do
    {now, request} = Map.pop(request, :now, Clock.now(published_tz(state.table)))

    with {:ok, resolved} <- Policy.check(op, request, facts(state, now)),
         :ok <- ensure_directories(op, resolved, state),
         {:ok, current} <- current_content(op, resolved, state),
         {:ok, plan} <- Plan.build(op, resolved, request, current) do
      execute(plan, state)
    else
      {:error, msg} -> {{:error, msg}, state}
    end
  end

  # The policy decides that a project directory may be created; creating it is
  # this module's job, and only `:create` can ask for one. Vigil.Commit would
  # mkdir_p the parent anyway, but doing it here keeps a filesystem failure
  # attributable to the directory.
  defp ensure_directories(:create, %Decision.Create{} = decision, state),
    do: create_project_dir(state, decision.create_project_dir)

  defp ensure_directories(_op, _decision, _state), do: :ok

  # A create has no current content by definition, and the two git-level
  # operations never look at their own note; every other operation is a
  # transformation of what the note already says. A move that updates links
  # reads the notes that link to it instead, each with what the index says
  # its links have to become.
  defp current_content(:move_note, %Decision.MoveNote{update_links: true} = move, state) do
    state.index
    |> Index.relinks(move.from, move.to)
    |> Enum.reduce_while({:ok, []}, fn {path, relinks}, {:ok, acc} ->
      case read_existing_file(abs(state, path)) do
        {:ok, content} -> {:cont, {:ok, [{path, content, relinks} | acc]}}
        error -> {:halt, error}
      end
    end)
  end

  defp current_content(op, _resolved, _state) when op in [:create, :delete_note, :move_note],
    do: {:ok, nil}

  defp current_content(_op, resolved, state),
    do: read_existing_file(abs(state, resolved.path))

  defp create_project_dir(_state, nil), do: :ok

  defp create_project_dir(state, project) do
    Commit.mkdir_p(Path.join(state.vault_path, Layout.project_dir(project)))
  end

  # Where a plan becomes an effect. Every effect is Vigil.Commit's — the write,
  # the delete, the move and the push — and the order they run in is this
  # module's, stated here once for all three actions (docs/design.md, "The
  # write path"): perform the action, commit, reparse into the index, then
  # push.
  #
  # The order is all three actions'; what differs is answered per action, one
  # small function per question: which effect to ask Vigil.Commit for, what the
  # index does with what comes back, what the report says, and what object a
  # push failure names. Including the part of a report that can only be
  # *observed across* the effect — the question is taken before it and answered
  # against the index it left behind, so that no action has to be a special
  # case of the sequence.
  defp execute(%Plan{action: action} = plan, state) do
    report_after = observe(plan, state)

    case perform(action, plan.message, state) do
      {:ok, commit_meta} ->
        state = reindex(state, action, commit_meta)
        report = Map.merge(reported(action), report_after.(state))

        push(state, Map.merge(report, plan.report), push_failure(action))

      {:error, msg} ->
        {{:error, msg}, state}
    end
  end

  # The action, performed and committed — one call each, because that is the
  # shape of Vigil.Commit: the file is written and added, or removed, or
  # renamed, under the plan's message. The write and the move come back with
  # the commit's metadata, which the reparse needs; a delete has no note left
  # to put metadata on.
  defp perform({:write, path, content}, message, state),
    do: Commit.write(state.git, state.vault_path, path, content, message)

  defp perform({:delete, path}, message, state) do
    with :ok <- Commit.delete(state.git, state.vault_path, path, message), do: {:ok, nil}
  end

  defp perform({:move, from, to, rewrites}, message, state),
    do: Commit.move(state.git, state.vault_path, from, to, message, rewrites)

  # The index after the effect: the note as it now stands on disk, at the path
  # it now has — or gone. A move reparses every note whose links it rewrote as
  # well; the moved note's own rewrite is already what stands at `to`.
  defp reindex(state, {:write, path, _content}, commit_meta),
    do: put_reparsed(state, path, commit_meta, "write")

  defp reindex(state, {:delete, path}, _commit_meta),
    do: put_index(state, Index.remove(state.index, path))

  defp reindex(state, {:move, from, to, rewrites}, commit_meta) do
    rewrites
    |> Enum.map(&elem(&1, 0))
    |> Enum.reject(&(&1 == to))
    |> Enum.reduce(
      move_reparsed(state, from, to, commit_meta),
      &put_reparsed(&2, &1, commit_meta, "move")
    )
  end

  # What the action itself puts in the success map. The plan's own report — what
  # only the *operation* knows about its result — is merged on top of it.
  defp reported({:write, path, _content}), do: %{path: path, pushed: true}
  defp reported({:delete, path}), do: %{path: path, deleted: true, pushed: true}
  defp reported({:move, from, to, _rewrites}), do: %{from: from, to: to, pushed: true}

  # The part of a report that is a diff across the effect rather than a fact
  # either side of it could answer alone. The reading is taken here, before,
  # and what comes back finishes the report against the state the effect left
  # behind — two different states, so they are not given one name.
  #
  # A move is the one action with such a report — which references it broke. A
  # source chunk that resolved to the note before and does not show up in the
  # (rebuilt) incoming references of the target afterwards now points nowhere,
  # for example because it named an explicit path instead of a basename. A
  # source inside the moved note has moved with it, and is looked for under
  # its new id.
  defp observe(%Plan{action: {:move, from, to, _rewrites}}, state) do
    resolved_before = Index.backlinks(state.index, from)

    fn after_effect ->
      resolved_after = Index.backlinks(after_effect.index, to)

      %{
        broken_backlinks:
          Enum.reject(resolved_before, &(moved_id(&1, from, to) in resolved_after))
      }
    end
  end

  # A rewrite can drop or rename a section another note links into, and says
  # which links it broke (docs/design.md, "The write path"): an inbound link
  # into one of the note's sections before that no longer resolves after.
  defp observe(%Plan{action: {:write, path, _content}, observe: :broken_chunk_links}, state) do
    before = Index.inbound_chunk_links(state.index, path)

    fn after_effect ->
      %{
        broken_chunk_links:
          Enum.reject(before, &(&1.from in Index.backlinks(after_effect.index, &1.to)))
      }
    end
  end

  defp observe(_plan, _state), do: fn _after_effect -> %{} end

  defp moved_id(from, from, to), do: to
  defp moved_id(id, from, to), do: String.replace_prefix(id, from <> "#", to <> "#")

  # What a push failure names as committed locally but not pushed: a change, a
  # deletion, a move. The sentence git wrote comes after it (Vigil.Commit), and
  # the whole of it travels as `push_error` on a success.
  defp push_failure({:write, _path, _content}),
    do: "Change saved and committed locally, but push failed"

  defp push_failure({:delete, _path}), do: "Deletion committed locally, but push failed"
  defp push_failure({:move, _from, _to, _rewrites}), do: "Move committed locally, but push failed"

  # A failed push is not a failed write. The change is on disk, committed and
  # in the index, so the answer is a success that says it was not pushed —
  # reported as an error, it invited the client to retry, and an `append`
  # retried is an `append` twice. The commit goes out with the next push that
  # succeeds, or with the safety-net cron.
  defp push(state, success, failure_prefix) do
    case Commit.push(state.git, state.vault_path, state.git_remote, state.git_branch) do
      :ok ->
        {{:ok, success}, state}

      {:error, out} ->
        Logger.warning("vigil: #{failure_prefix}: #{out}")

        {{:ok, %{success | pushed: false} |> Map.put(:push_error, "#{failure_prefix}: #{out}")},
         state}
    end
  end

  # The one place the index is replaced, so the published event notes cannot
  # fall behind it: every path that changes the index — the full load and each
  # of the three write outcomes — goes through here. Publishing inside the
  # writer is what makes the table safe to read anywhere else.
  defp put_index(state, index) do
    :ets.insert(state.table, {:events, Index.event_notes(index)})
    %{state | index: index}
  end

  defp put_reparsed(state, path, commit_meta, verb) do
    case reparse(state, path, commit_meta, verb) do
      {:ok, file} -> put_index(state, Index.put(state.index, file))
      :error -> state
    end
  end

  defp move_reparsed(state, from, to, commit_meta) do
    case reparse(state, to, commit_meta, "move") do
      {:ok, file} -> put_index(state, Index.move(state.index, from, file))
      :error -> state
    end
  end

  # Used by the write paths that read a note's current content before
  # transforming it — every operation but create, delete_note and move_note.
  # A read failure here happens before anything is written, so it is
  # reported back to the caller as an ordinary error tuple rather than
  # crashing the GenServer.
  defp read_existing_file(path) do
    case File.read(path) do
      {:ok, content} -> {:ok, content}
      {:error, reason} -> {:error, "Could not read file #{path}: #{Commit.fs_error(reason)}"}
    end
  end

  # Used by reparse/4: the write or move itself has already succeeded and been
  # committed by the time it runs. A read failure here must not crash
  # the GenServer and take down unrelated calls — it only means the index
  # stays stale for `rel_path` until the next reload, so the failure is logged
  # rather than propagated.
  defp read_for_reparse(vault_path, rel_path, verb) do
    case File.read(Path.join(vault_path, rel_path)) do
      {:ok, content} ->
        {:ok, content}

      {:error, reason} ->
        Logger.warning(
          "vigil: could not reparse #{rel_path} after #{verb}: #{Commit.fs_error(reason)}"
        )

        :error
    end
  end

  # The file as it now stands on disk, reparsed. `created_at` is deliberately
  # not computed here: "creation date = first commit" (docs/design.md,
  # principle 3) is the index's invariant, and it preserves the value it
  # already holds for the note (Vigil.Index.put/2, Vigil.Index.move/3). What
  # this hands over is the write's own commit metadata.
  defp reparse(state, rel_path, commit_meta, verb) do
    case read_for_reparse(state.vault_path, rel_path, verb) do
      {:ok, content} ->
        meta = %{
          created_at: commit_meta.updated_at,
          updated_at: commit_meta.updated_at,
          last_author: commit_meta.last_author
        }

        Parser.parse(rel_path, content, meta)

      :error ->
        :error
    end
  end

  ## Skills
  #
  # skills/ is a separate concern from notes (docs/design.md, "skills/ — one
  # repository, two systems"); the subsystem itself lives in Vigil.Skills, a
  # standalone module. Only :skill_write is a GenServer call, because
  # principle 2 — one writer — is about writes: a skill write commits and
  # pushes through the same mailbox as a note write, in order with it. The two
  # skill *reads* never enter it (Vigil.MCP.Tools answers them against
  # vault_path/0), so the bootstrap read every write begins with does not
  # queue behind the push of the write before it.

  defp do_skill_write(name, content, state) do
    Skills.write(name, content, %{
      vault_path: state.vault_path,
      git_remote: state.git_remote,
      git_branch: state.git_branch,
      git: state.git
    })
  end
end
