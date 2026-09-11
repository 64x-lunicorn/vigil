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
    Skills
  }

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
  def call(store, :lint, %{} = params), do: request(store, :lint, with_now(params))
  def call(store, :current, %{} = params), do: request(store, :current, with_now(params))
  def call(store, :reload, %{} = params), do: request(store, :reload, params)

  def call(store, :skill_write, %{name: _, content: _} = params),
    do: request(store, :skill_write, params)

  defp request(store, op, params), do: GenServer.call(store, {op, params})

  defp with_now(params), do: Map.put_new_lazy(params, :now, &Clock.now/0)

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
    do: GenServer.call(store, :instructions_domains_text)

  # No fallback for a missing table. It lives with this process, so its absence
  # means the writer is down — and the response is going to fail at the tool
  # call regardless, exactly as it did when the snapshot was a call into a
  # process that was not there. Answering "no events" instead would be worse
  # than failing: Vigil.MCP.Envelope records what it decided against as the
  # session's state, so an empty snapshot would be read as every active event
  # having finished, and the next response would report a phase change that
  # never happened.
  defp published_events(store), do: :ets.lookup_element(store, :events, 2)

  ## GenServer

  @impl true
  def init(opts) do
    # start_link/1 puts the name in, defaulted or supplied, so there is one
    # statement of what it defaults to and this reads it.
    name = Keyword.fetch!(opts, :name)
    vault_path = Keyword.fetch!(opts, :vault_path) |> Path.expand()
    exclude = Keyword.get(opts, :exclude, [])
    git_remote = Keyword.get(opts, :git_remote, "origin")

    # The one default, in the one place that has configuration to build it
    # from (docs/design.md, "Git is reached through a value"). Vigil.Skills
    # has none and is handed this value; a caller that hands one in here is
    # saying which git this vault has, and the repository check goes with the
    # adapter that needs one rather than staying behind as a claim about a
    # vault nobody is going to shell out into.
    git = Keyword.get_lazy(opts, :git, fn -> over_repository!(vault_path) end)

    if :ets.whereis(name) == :undefined do
      :ets.new(name, [:set, :named_table, :public, read_concurrency: true])
    end

    :ets.insert(name, {:vault_path, vault_path})

    state = %{
      table: name,
      vault_path: vault_path,
      exclude: exclude,
      git_remote: git_remote,
      git: git,
      domains: %{},
      index: %Index{}
    }

    {state, pull_result} = do_full_load(state)

    case pull_result do
      :ok -> :ok
      {:error, reason} -> Logger.warning("vigil: initial git pull failed: #{reason}")
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
    {result, new_state} = write(op, params, state)
    {:reply, result, new_state}
  end

  def handle_call({:reload, _params}, _from, state) do
    {state, pull_result} = do_full_load(state)
    {:reply, reload_result(pull_result), state}
  end

  def handle_call({:skill_write, params}, _from, state) do
    {:reply, do_skill_write(params.name, params.content, state), state}
  end

  def handle_call(:instructions_domains_text, _from, state) do
    {:reply, domains_yaml_raw(state.vault_path), state}
  end

  defp reload_result(:ok), do: %{reloaded: true}
  defp reload_result({:error, reason}), do: %{reloaded: true, pull_failed: reason}

  ## Loading

  defp do_full_load(state) do
    pull_result = state.git.pull.(state.vault_path, state.git_remote)

    git_meta = state.git.log_metadata.(state.vault_path)
    domains = load_domains(state.vault_path)

    layout = layout(state)

    log_warnings(Domains.mismatches(domains, layout.domains))

    parsed_files =
      layout
      |> Layout.note_paths()
      |> Enum.map(&load_file(state.vault_path, &1, git_meta))
      |> Enum.reject(&is_nil/1)

    index = Index.build(parsed_files)
    sizes = Index.size(index)

    Logger.info(
      "vigil: #{length(layout.domains)} domains (#{Enum.join(layout.domains, ", ")}), #{sizes.notes} notes, #{sizes.chunks} chunks"
    )

    {put_index(%{state | domains: domains}, index), pull_result}
  end

  defp load_file(vault_path, rel_path, git_meta) do
    abs_path = Path.join(vault_path, rel_path)

    case File.read(abs_path) do
      {:ok, content} ->
        meta = Map.get(git_meta, rel_path, %{created_at: nil, updated_at: nil, last_author: nil})
        {:ok, file} = Parser.parse(rel_path, content, meta)
        file

      {:error, reason} ->
        Logger.warning("cannot read #{rel_path}: #{inspect(reason)}")
        nil
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
  # (Vigil.MCP.Envelope.for_tool/4), passed through rather than read here.
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
    {now, request} = Map.pop(request, :now, Clock.now())

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
  # operations never look at it; every other operation is a transformation of
  # what the note already says.
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
    report_after = observe(action, state)

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

  defp perform({:move, from, to}, message, state),
    do: Commit.move(state.git, state.vault_path, from, to, message)

  # The index after the effect: the note as it now stands on disk, at the path
  # it now has — or gone.
  defp reindex(state, {:write, path, _content}, commit_meta),
    do: put_reparsed(state, path, commit_meta, "write")

  defp reindex(state, {:delete, path}, _commit_meta),
    do: put_index(state, Index.remove(state.index, path))

  defp reindex(state, {:move, from, to}, commit_meta),
    do: move_reparsed(state, from, to, commit_meta)

  # What the action itself puts in the success map. The plan's own report — what
  # only the *operation* knows about its result — is merged on top of it.
  defp reported({:write, path, _content}), do: %{path: path, pushed: true}
  defp reported({:delete, path}), do: %{path: path, deleted: true, pushed: true}
  defp reported({:move, from, to}), do: %{from: from, to: to, pushed: true}

  # The part of a report that is a diff across the effect rather than a fact
  # either side of it could answer alone. The reading is taken here, before,
  # and what comes back finishes the report against the state the effect left
  # behind — two different states, so they are not given one name.
  #
  # A move is the one action with such a report — which references it broke. A
  # source chunk that resolved to the note before and does not show up in the
  # (rebuilt) incoming references of the target afterwards now points nowhere,
  # for example because it named an explicit path instead of a basename.
  defp observe({:move, from, to}, state) do
    resolved_before = Index.backlinks(state.index, from)

    fn after_effect ->
      %{broken_backlinks: resolved_before -- Index.backlinks(after_effect.index, to)}
    end
  end

  defp observe(_action, _state), do: fn _after_effect -> %{} end

  # What a push failure names as committed locally but not pushed: a change, a
  # deletion, a move. The sentence git wrote comes after it (Vigil.Commit).
  defp push_failure({:write, _path, _content}),
    do: "Change saved and committed locally, but push failed"

  defp push_failure({:delete, _path}), do: "Deletion committed locally, but push failed"
  defp push_failure({:move, _from, _to}), do: "Move committed locally, but push failed"

  defp push(state, success, failure_prefix) do
    case Commit.push(state.git, state.vault_path, state.git_remote) do
      :ok -> {{:ok, success}, state}
      {:error, out} -> {{:error, "#{failure_prefix}: #{out}"}, state}
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
      git: state.git
    })
  end
end
