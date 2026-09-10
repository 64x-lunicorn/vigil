defmodule Vigil.Store do
  @moduledoc false
  use GenServer
  require Logger

  alias Vigil.{
    Clock,
    Commit,
    Index,
    Parser,
    Git,
    Skills,
    VaultDiscovery
  }

  alias Vigil.Vault.{Decision, Domains, Facts, Plan, Policy}

  ## Public API

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  # `limit` is required, and matched in the head so a caller that omits it
  # fails in its own process rather than in the single writer's. Vigil.MCP.Tools
  # declares the bound (1..25, default 10) and supplies a value on every call.
  def search(%{limit: _} = params), do: GenServer.call(__MODULE__, {:search, params})
  def read(id, backlinks?), do: GenServer.call(__MODULE__, {:read, id, backlinks?})
  # Depth is bounded where it is declared (Vigil.MCP.Tools, 1..2). Matched here
  # too, so a caller outside that contract fails in its own process rather than
  # reaching the single writer with a depth nothing downstream checks.
  def links(id, direction, depth) when depth in [1, 2],
    do: GenServer.call(__MODULE__, {:links, id, direction, depth})

  def create(params), do: GenServer.call(__MODULE__, {:create, params})
  def append(params), do: GenServer.call(__MODULE__, {:append, params})

  def replace_section(id, content),
    do: GenServer.call(__MODULE__, {:replace_section, id, content})

  def rewrite_note(params), do: GenServer.call(__MODULE__, {:rewrite_note, params})
  def delete_section(id), do: GenServer.call(__MODULE__, {:delete_section, id})
  def update_frontmatter(params), do: GenServer.call(__MODULE__, {:update_frontmatter, params})
  def delete_note(params), do: GenServer.call(__MODULE__, {:delete_note, params})
  def move_note(params), do: GenServer.call(__MODULE__, {:move_note, params})
  def lint(now \\ nil), do: GenServer.call(__MODULE__, {:lint, now})

  def current(now \\ nil), do: GenServer.call(__MODULE__, {:current, now})
  def snapshot(now), do: GenServer.call(__MODULE__, {:snapshot, now})
  def reload(), do: GenServer.call(__MODULE__, :reload)
  def domain_names(), do: GenServer.call(__MODULE__, :domain_names)
  def instructions_domains_text(), do: GenServer.call(__MODULE__, :instructions_domains_text)
  def skill_list(), do: GenServer.call(__MODULE__, :skill_list)
  def skill_read(name), do: GenServer.call(__MODULE__, {:skill_read, name})
  def skill_write(name, content), do: GenServer.call(__MODULE__, {:skill_write, name, content})

  ## GenServer

  @impl true
  def init(opts) do
    vault_path = Keyword.fetch!(opts, :vault_path) |> Path.expand()
    exclude = Keyword.get(opts, :exclude, [])
    git_remote = Keyword.get(opts, :git_remote, "origin")

    unless File.dir?(Path.join(vault_path, ".git")) do
      raise "VIGIL_VAULT_PATH #{vault_path} is not a git repository or does not exist"
    end

    state = %{
      vault_path: vault_path,
      exclude: exclude,
      git_remote: git_remote,
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

  @impl true
  def handle_call({:search, params}, _from, state) do
    {:reply, Index.search(state.index, params), state}
  end

  def handle_call({:read, id, backlinks?}, _from, state) do
    {:reply, Index.read(state.index, id, backlinks?), state}
  end

  def handle_call({:links, id, direction, depth}, _from, state) do
    {:reply, Index.links(state.index, id, direction, depth), state}
  end

  def handle_call({:create, params}, _from, state) do
    {result, new_state} = write(:create, params, state)
    {:reply, result, new_state}
  end

  def handle_call({:append, params}, _from, state) do
    {result, new_state} = write(:append, params, state)
    {:reply, result, new_state}
  end

  def handle_call({:replace_section, id, content}, _from, state) do
    {result, new_state} = write(:replace_section, %{id: id, content: content}, state)
    {:reply, result, new_state}
  end

  def handle_call({:rewrite_note, params}, _from, state) do
    {result, new_state} = write(:rewrite_note, params, state)
    {:reply, result, new_state}
  end

  def handle_call({:delete_section, id}, _from, state) do
    {result, new_state} = write(:delete_section, %{id: id}, state)
    {:reply, result, new_state}
  end

  def handle_call({:update_frontmatter, params}, _from, state) do
    {result, new_state} = write(:update_frontmatter, params, state)
    {:reply, result, new_state}
  end

  def handle_call({:delete_note, params}, _from, state) do
    {result, new_state} = write(:delete_note, params, state)
    {:reply, result, new_state}
  end

  def handle_call({:move_note, params}, _from, state) do
    {result, new_state} = write(:move_note, params, state)
    {:reply, result, new_state}
  end

  def handle_call({:lint, now}, _from, state) do
    {:reply, Index.lint(state.index, now || Clock.now()), state}
  end

  def handle_call({:current, now}, _from, state) do
    {:reply, Index.current(state.index, now || Clock.now()), state}
  end

  def handle_call({:snapshot, now}, _from, state) do
    {:reply, Index.snapshot(state.index, now), state}
  end

  def handle_call(:reload, _from, state) do
    {state, pull_result} = do_full_load(state)
    {:reply, reload_result(pull_result), state}
  end

  def handle_call(:domain_names, _from, state) do
    {:reply, list_domain_names(state), state}
  end

  def handle_call(:instructions_domains_text, _from, state) do
    {:reply, domains_yaml_raw(state.vault_path), state}
  end

  def handle_call(:skill_list, _from, state) do
    {:reply, do_skill_list(state), state}
  end

  def handle_call({:skill_read, name}, _from, state) do
    {:reply, do_skill_read(name, state), state}
  end

  def handle_call({:skill_write, name, content}, _from, state) do
    {:reply, do_skill_write(name, content, state), state}
  end

  defp reload_result(:ok), do: %{reloaded: true}
  defp reload_result({:error, reason}), do: %{reloaded: true, pull_failed: reason}

  ## Loading

  defp do_full_load(state) do
    pull_result = Git.pull(state.vault_path, state.git_remote)

    git_meta = Git.log_metadata(state.vault_path)
    domains = load_domains(state.vault_path)

    domain_dirs = VaultDiscovery.domain_dirs(state.vault_path, state.exclude)

    log_warnings(Domains.mismatches(domains, domain_dirs))

    files =
      domain_dirs
      |> Enum.flat_map(&VaultDiscovery.domain_files(state.vault_path, &1))

    parsed_files =
      files
      |> Enum.map(&load_file(state.vault_path, &1, git_meta))
      |> Enum.reject(&is_nil/1)

    index = Index.build(parsed_files)
    sizes = Index.size(index)

    Logger.info(
      "vigil: #{length(domain_dirs)} domains (#{Enum.join(domain_dirs, ", ")}), #{sizes.notes} notes, #{sizes.chunks} chunks"
    )

    {%{state | domains: domains, index: index}, pull_result}
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

  defp list_domain_names(state), do: VaultDiscovery.domain_dirs(state.vault_path, state.exclude)

  ## Vault facts for Vigil.Vault.Policy

  # Built fresh per write. The function fields are the adapters at the policy's
  # seam: here they read the filesystem and the index, in Vigil.Vault.PolicyTest
  # they are literals. The index answers three of them itself
  # (Vigil.Index.lookups/1), destructured rather than merged so that a lookup
  # the struct has no field for fails here, and Facts.new/1 requires the rest —
  # an unanswered question raises instead of opening the gate it guards.
  defp facts(state) do
    %{
      count_headings: count_headings,
      find_chunk: find_chunk,
      find_section: find_section
    } = Index.lookups(state.index)

    Facts.new(
      vault_path: state.vault_path,
      domains: list_domain_names(state),
      exclude: state.exclude,
      project_dirs: project_dirs(state),
      naming: naming_rules(state),
      today: Clock.today(),
      path_exists?: fn path -> File.exists?(Path.join(state.vault_path, path)) end,
      read_note: fn path -> File.read(Path.join(state.vault_path, path)) end,
      find_backlinks: fn path -> Index.backlinks(state.index, path) end,
      find_similar: fn query, domain ->
        Index.search(state.index, %{query: query, domain: domain, limit: 25})
      end,
      count_headings: count_headings,
      find_chunk: find_chunk,
      find_section: find_section
    )
  end

  defp abs(state, rel_path), do: Path.join(state.vault_path, rel_path)

  defp project_dirs(state) do
    projects = Path.join(state.vault_path, "projects")

    case File.ls(projects) do
      {:ok, entries} -> Enum.filter(entries, &File.dir?(Path.join(projects, &1)))
      {:error, _} -> []
    end
  end

  defp naming_rules(state), do: Domains.naming_rules(state.domains)

  ## The write path
  #
  # Eight operations, one sequence: ask the policy, read the note, shape the
  # write, then perform it. Only the last step is an effect, and only the two
  # middle steps differ between operations — Vigil.Vault.Plan holds the
  # difference, this holds the sequence. Every failure before the effect
  # leaves the state untouched, said once here rather than at each site.

  defp write(op, request, state) do
    with {:ok, resolved} <- Policy.check(op, request, facts(state)),
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
    Commit.mkdir_p(Path.join([state.vault_path, "projects", project]))
  end

  # Where a plan becomes an effect. One order for all three actions
  # (docs/design.md, "The write path"): perform it, commit, reparse into the
  # index, then push. What differs is what the object is — which is why each
  # clause names its own push-failure message — and the plan's own report,
  # merged into the success map.
  defp execute(%Plan{action: {:write, path, content}} = plan, state) do
    case Commit.write(state.vault_path, path, content, plan.message) do
      {:ok, commit_meta} ->
        state = put_reparsed(state, path, commit_meta, "write")

        push(
          state,
          Map.merge(%{path: path, pushed: true}, plan.report),
          "Change saved and committed locally, but push failed"
        )

      {:error, msg} ->
        {{:error, msg}, state}
    end
  end

  defp execute(%Plan{action: {:delete, path}} = plan, state) do
    case Git.remove_commit(state.vault_path, path, plan.message) do
      :ok ->
        state = %{state | index: Index.remove(state.index, path)}

        push(
          state,
          Map.merge(%{path: path, deleted: true, pushed: true}, plan.report),
          "Deletion committed locally, but push failed"
        )

      {:error, out} ->
        {{:error, "git rm/commit failed: #{out}"}, state}
    end
  end

  defp execute(%Plan{action: {:move, from, to}} = plan, state) do
    # Backlink report — a diff of incoming references before and after the
    # move rather than an ad-hoc scan. A source chunk that resolved before and
    # no longer shows up in the (rebuilt) incoming references of the target now
    # points nowhere — for example because it referenced an explicit path
    # instead of a basename.
    backlinks_before = Index.backlinks(state.index, from)

    case Git.move_commit(state.vault_path, from, to, plan.message) do
      {:ok, commit_meta} ->
        state = move_reparsed(state, from, to, commit_meta)
        broken = backlinks_before -- Index.backlinks(state.index, to)

        push(
          state,
          Map.merge(%{from: from, to: to, pushed: true, broken_backlinks: broken}, plan.report),
          "Move committed locally, but push failed"
        )

      {:error, out} ->
        {{:error, "git mv/commit failed: #{out}"}, state}
    end
  end

  defp push(state, success, failure_prefix) do
    case Git.push(state.vault_path, state.git_remote) do
      :ok -> {{:ok, success}, state}
      {:error, out} -> {{:error, "#{failure_prefix}: #{out}"}, state}
    end
  end

  defp put_reparsed(state, path, commit_meta, verb) do
    case reparse(state, path, commit_meta, verb) do
      {:ok, file} -> %{state | index: Index.put(state.index, file)}
      :error -> state
    end
  end

  defp move_reparsed(state, from, to, commit_meta) do
    case reparse(state, to, commit_meta, "move") do
      {:ok, file} -> %{state | index: Index.move(state.index, from, file)}
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
  # standalone module. Store.skill_list/0, skill_read/1, skill_write/2 stay
  # public GenServer calls, not delegated directly — skill writes must
  # still commit and push through the same single-writer mailbox as note
  # writes (docs/design.md, "One writer").

  defp do_skill_list(state), do: Skills.list(state.vault_path)

  defp do_skill_read(name, state), do: Skills.read(name, state.vault_path)

  defp do_skill_write(name, content, state) do
    Skills.write(name, content, %{vault_path: state.vault_path, git_remote: state.git_remote})
  end
end
