defmodule Vigil.Store do
  @moduledoc false
  use GenServer
  require Logger

  alias Vigil.{
    Clock,
    Index,
    Markdown,
    Parser,
    Git,
    Skills,
    VaultDiscovery
  }

  alias Vigil.Vault.{Facts, Policy}

  ## Public API

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def search(params), do: GenServer.call(__MODULE__, {:search, params})
  def read(id, backlinks?), do: GenServer.call(__MODULE__, {:read, id, backlinks?})
  def links(id, direction, depth), do: GenServer.call(__MODULE__, {:links, id, direction, depth})
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
      domains_desc: %{},
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
    {result, new_state} = do_create(params, state)
    {:reply, result, new_state}
  end

  def handle_call({:append, params}, _from, state) do
    {result, new_state} = do_append(params, state)
    {:reply, result, new_state}
  end

  def handle_call({:replace_section, id, content}, _from, state) do
    {result, new_state} = do_replace_section(id, content, state)
    {:reply, result, new_state}
  end

  def handle_call({:rewrite_note, params}, _from, state) do
    {result, new_state} = do_rewrite_note(params, state)
    {:reply, result, new_state}
  end

  def handle_call({:delete_section, id}, _from, state) do
    {result, new_state} = do_delete_section(id, state)
    {:reply, result, new_state}
  end

  def handle_call({:update_frontmatter, params}, _from, state) do
    {result, new_state} = do_update_frontmatter(params, state)
    {:reply, result, new_state}
  end

  def handle_call({:delete_note, params}, _from, state) do
    {result, new_state} = do_delete_note(params, state)
    {:reply, result, new_state}
  end

  def handle_call({:move_note, params}, _from, state) do
    {result, new_state} = do_move_note(params, state)
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
    domains_desc = load_domains_yml(state.vault_path)

    domain_dirs = VaultDiscovery.domain_dirs(state.vault_path, state.exclude)

    warn_domain_mismatches(domain_dirs, domains_desc)

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

    {%{state | domains_desc: domains_desc, index: index}, pull_result}
  end

  defp warn_domain_mismatches(domain_dirs, domains_desc) do
    for key <- Map.keys(domains_desc), key not in domain_dirs do
      Logger.warning("_domains.yml: key '#{key}' has no matching directory")
    end

    for dir <- domain_dirs, not Map.has_key?(domains_desc, dir) do
      Logger.warning("domain '#{dir}' has no entry in _domains.yml")
    end
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

  defp load_domains_yml(vault_path) do
    path = Path.join(vault_path, "_domains.yml")

    if File.exists?(path) do
      case YamlElixir.read_from_file(path) do
        {:ok, map} when is_map(map) ->
          Map.new(map, fn {domain, value} -> {domain, parse_domain_entry(domain, value)} end)

        {:error, reason} ->
          Logger.warning("_domains.yml unparsbar: #{inspect(reason)}")
          %{}
      end
    else
      Logger.warning("_domains.yml fehlt")
      %{}
    end
  end

  # A domain entry is either a plain description string (the common case)
  # or a map with `description`/`naming`. Normalized internally to
  # `%{description:, naming:}` either way.
  defp parse_domain_entry(_domain, value) when is_binary(value) do
    %{description: value, naming: nil}
  end

  defp parse_domain_entry(domain, value) when is_map(value) do
    %{
      description: Map.get(value, "beschreibung"),
      naming: parse_naming(domain, Map.get(value, "naming"))
    }
  end

  defp parse_domain_entry(_domain, _value), do: %{description: nil, naming: nil}

  defp parse_naming(_domain, nil), do: nil

  defp parse_naming(domain, naming) when is_map(naming) do
    case compile_naming_pattern(domain, Map.get(naming, "pattern")) do
      nil ->
        nil

      pattern ->
        %{
          pattern: pattern,
          scope: parse_naming_scope(Map.get(naming, "scope")),
          hint: Map.get(naming, "hint", Map.get(naming, "hinweis", "")),
          suggestion:
            parse_naming_suggestion(Map.get(naming, "suggestion", Map.get(naming, "vorschlag"))),
          max_depth: Map.get(naming, "max_depth")
        }
    end
  end

  defp parse_naming(_domain, _value), do: nil

  # A broken naming configuration must not block writing — the rule is
  # ignored, the write is not.
  defp compile_naming_pattern(_domain, nil), do: nil

  defp compile_naming_pattern(domain, raw) do
    case Regex.compile(raw, "u") do
      {:ok, regex} ->
        regex

      {:error, reason} ->
        Logger.warning(
          "_domains.yml: naming.pattern for '#{domain}' is not a valid regex (#{inspect(reason)}), ignoring it"
        )

        nil
    end
  end

  defp parse_naming_scope("relpath"), do: :relpath
  defp parse_naming_scope(_), do: :filename

  defp parse_naming_suggestion("date"), do: :date
  defp parse_naming_suggestion(_), do: :slug

  defp domains_yaml_raw(vault_path) do
    path = Path.join(vault_path, "_domains.yml")

    case File.read(path) do
      {:ok, content} ->
        content

      {:error, reason} ->
        if File.exists?(path) do
          Logger.warning("cannot read _domains.yml: #{fs_error(reason)}")
        end

        ""
    end
  end

  defp list_domain_names(state), do: VaultDiscovery.domain_dirs(state.vault_path, state.exclude)

  ## Vault facts for Vigil.Vault.Policy

  # Built fresh per write. The three function fields are the adapters at the
  # policy's seam: in production they read the filesystem and the index, in
  # Vigil.Vault.PolicyTest they are literals.
  defp facts(state, opts \\ []) do
    %Facts{
      vault_path: state.vault_path,
      domains: list_domain_names(state),
      exclude: state.exclude,
      project_dirs: project_dirs(state),
      naming: naming_rules(state),
      today: Clock.today(),
      heading_count: Keyword.get(opts, :heading_count, 0),
      backlinks: Keyword.get(opts, :backlinks, []),
      chunk: Keyword.get(opts, :chunk),
      path_exists?: fn path -> File.exists?(Path.join(state.vault_path, path)) end,
      read_note: fn path -> File.read(Path.join(state.vault_path, path)) end,
      find_similar: fn query, domain ->
        Index.search(state.index, %{query: query, domain: domain, limit: 25})
      end
    }
  end

  defp abs(state, rel_path), do: Path.join(state.vault_path, rel_path)

  defp project_dirs(state) do
    projects = Path.join(state.vault_path, "projects")

    case File.ls(projects) do
      {:ok, entries} -> Enum.filter(entries, &File.dir?(Path.join(projects, &1)))
      {:error, _} -> []
    end
  end

  defp naming_rules(state) do
    for {domain, desc} <- state.domains_desc,
        naming = Map.get(desc, :naming),
        naming != nil,
        into: %{},
        do: {domain, naming}
  end

  # The policy decides that a project directory may be created; creating it is
  # this module's job. write_and_commit/5 would mkdir_p the parent anyway, but
  # doing it here keeps a filesystem failure attributable to the directory.
  defp create_project_dir(_state, nil), do: :ok

  defp create_project_dir(state, project) do
    safe_mkdir_p(Path.join([state.vault_path, "projects", project]))
  end

  ## create

  defp do_create(params, state) do
    content = Map.fetch!(params, :content)

    with {:ok, resolved} <- Policy.check(:create, params, facts(state)),
         :ok <- create_project_dir(state, resolved.create_project_dir) do
      frontmatter = build_frontmatter(resolved.type, resolved.starts, resolved.ends)
      full_content = normalize_trailing_newline(frontmatter <> content)

      {result, new_state} =
        write_and_commit(
          state,
          resolved.path,
          abs(state, resolved.path),
          full_content,
          "create: #{resolved.path} — #{first_line(content)}"
        )

      result =
        case {result, resolved.normalized_from} do
          {{:ok, ok_map}, nil} -> {:ok, ok_map}
          {{:ok, ok_map}, from} -> {:ok, Map.put(ok_map, :path_normalized_from, from)}
          {other, _} -> other
        end

      {result, new_state}
    else
      {:error, msg} -> {{:error, msg}, state}
    end
  end

  defp build_frontmatter(type, starts, ends) do
    lines = ["---", "type: #{type}"]

    lines =
      if type == :event do
        lines ++ ["starts: #{DateTime.to_iso8601(starts)}", "ends: #{DateTime.to_iso8601(ends)}"]
      else
        lines
      end

    Enum.join(lines ++ ["---", ""], "\n")
  end

  defp first_line(content) do
    content
    |> String.split("\n")
    |> Enum.find(&(String.trim(&1) != ""))
    |> to_string()
    |> String.slice(0, 50)
  end

  defp normalize_trailing_newline(content) do
    String.trim_trailing(content, "\n") <> "\n"
  end

  ## append

  defp do_append(params, state) do
    heading = Map.get(params, :heading)
    content = Map.fetch!(params, :content)

    with {:ok, %{path: path}} <- Policy.check(:append, params, facts(state)),
         abs_path = abs(state, path),
         {:ok, original} <- read_existing_file(abs_path) do
      orig_lines = Markdown.split_lines(original)

      new_lines = insert_append(state.index, path, orig_lines, heading, content)
      new_content = Enum.join(new_lines, "\n") <> "\n"

      write_and_commit(
        state,
        path,
        abs_path,
        new_content,
        "append: #{path} — #{first_line(content)}"
      )
    else
      {:error, msg} -> {{:error, msg}, state}
    end
  end

  defp insert_append(_index, _path, orig_lines, nil, content) do
    orig_lines ++ [""] ++ Markdown.split_lines(content)
  end

  defp insert_append(index, path, orig_lines, heading, content) do
    target_slug = Parser.slug(heading)
    existing = Index.chunk_by_heading(index, path, target_slug)

    case existing do
      nil ->
        orig_lines ++ ["", "## #{heading}"] ++ Markdown.split_lines(content)

      chunk ->
        prefix = Enum.slice(orig_lines, 0, chunk.body_end_line)

        suffix =
          Enum.slice(orig_lines, chunk.body_end_line, length(orig_lines) - chunk.body_end_line)

        prefix ++ Markdown.split_lines(content) ++ suffix
    end
  end

  ## replace_section

  defp do_replace_section(id, content, state) do
    rec = Index.chunk(state.index, id)

    with {:ok, %{path: path}} <-
           Policy.check(:replace_section, %{id: id, content: content}, facts(state, chunk: rec)) do
      # The heading line stays; only the body under it is replaced.
      splice_chunk(
        state,
        path,
        rec,
        rec.heading_line,
        Markdown.split_lines(content),
        "replace_section: #{id}"
      )
    else
      {:error, msg} -> {{:error, msg}, state}
    end
  end

  ## rewrite_note

  defp do_rewrite_note(params, state) do
    content = Map.fetch!(params, :content)
    heading_count = Index.heading_count(state.index, Map.fetch!(params, :path))

    with {:ok, %{path: path}} <-
           Policy.check(:rewrite_note, params, facts(state, heading_count: heading_count)),
         abs_path = abs(state, path),
         {:ok, original} <- read_existing_file(abs_path) do
      case Markdown.split_frontmatter(original) do
        {:ok, frontmatter, _old_body} ->
          new_content = normalize_trailing_newline(frontmatter <> content)
          write_and_commit(state, path, abs_path, new_content, "rewrite_note: #{path}")

        {:error, msg} ->
          {{:error, msg}, state}
      end
    else
      {:error, msg} -> {{:error, msg}, state}
    end
  end

  ## delete_section

  defp do_delete_section(id, state) do
    rec = Index.chunk(state.index, id)

    with {:ok, %{path: path}} <-
           Policy.check(:delete_section, %{id: id}, facts(state, chunk: rec)) do
      # The heading line goes with the body it heads.
      splice_chunk(state, path, rec, rec.heading_line - 1, [], "delete_section: #{id}")
    else
      {:error, msg} -> {{:error, msg}, state}
    end
  end

  # Rewrites the file around one chunk: every line before `keep_lines`, then
  # `replacement`, then everything from the chunk's end onwards. The line
  # numbers come from the index, which is authoritative because vigil is the
  # only writer (docs/design.md, "One writer").
  defp splice_chunk(state, path, rec, keep_lines, replacement, message) do
    abs_path = abs(state, path)

    case read_existing_file(abs_path) do
      {:ok, original} ->
        orig_lines = Markdown.split_lines(original)

        prefix = Enum.slice(orig_lines, 0, keep_lines)
        suffix = Enum.slice(orig_lines, rec.body_end_line, length(orig_lines) - rec.body_end_line)

        new_content = Enum.join(prefix ++ replacement ++ suffix, "\n") <> "\n"
        write_and_commit(state, path, abs_path, new_content, message)

      {:error, msg} ->
        {{:error, msg}, state}
    end
  end

  ## update_frontmatter

  defp do_update_frontmatter(params, state) do
    with {:ok, resolved} <- Policy.check(:update_frontmatter, params, facts(state)),
         path = resolved.path,
         abs_path = abs(state, path),
         {:ok, original} <- read_existing_file(abs_path) do
      case Markdown.split_frontmatter(original) do
        {:ok, _old_frontmatter, body} ->
          new_frontmatter = build_frontmatter(resolved.type, resolved.starts, resolved.ends)
          new_content = normalize_trailing_newline(new_frontmatter <> body)
          write_and_commit(state, path, abs_path, new_content, "update_frontmatter: #{path}")

        {:error, msg} ->
          {{:error, msg}, state}
      end
    else
      {:error, msg} -> {{:error, msg}, state}
    end
  end

  ## delete

  defp do_delete_note(params, state) do
    backlinks = Index.backlinks(state.index, Map.fetch!(params, :path))

    with {:ok, %{path: path}} <-
           Policy.check(:delete_note, params, facts(state, backlinks: backlinks)) do
      case Git.remove_commit(state.vault_path, path, "delete: #{path}") do
        :ok ->
          case Git.push(state.vault_path, state.git_remote) do
            :ok ->
              new_index = Index.remove(state.index, path)
              new_state = %{state | index: new_index}

              result =
                {:ok, %{path: path, deleted: true, pushed: true, broken_backlinks: backlinks}}

              {result, new_state}

            {:error, out} ->
              {{:error, "Deletion committed locally, but push failed: #{out}"}, state}
          end

        {:error, out} ->
          {{:error, "git rm/commit failed: #{out}"}, state}
      end
    else
      {:error, msg} -> {{:error, msg}, state}
    end
  end

  ## move_note

  defp do_move_note(params, state) do
    with {:ok, resolved} <- Policy.check(:move_note, params, facts(state)) do
      do_move_note_to(state, resolved.from, resolved.to)
    else
      {:error, msg} -> {{:error, msg}, state}
    end
  end

  defp do_move_note_to(state, normalized_from, normalized_to) do
    backlinks_before = Index.backlinks(state.index, normalized_from)
    commit_message = "move: #{normalized_from} -> #{normalized_to}"

    case Git.move_commit(state.vault_path, normalized_from, normalized_to, commit_message) do
      {:ok, commit_meta} ->
        case Git.push(state.vault_path, state.git_remote) do
          :ok ->
            new_index = reparse_moved_file(state, normalized_from, normalized_to, commit_meta)
            new_state = %{state | index: new_index}
            # Backlink report — a diff of incoming references before and
            # after the move rather than an ad-hoc scan. A source chunk that
            # resolved before and no longer shows up in the (rebuilt)
            # incoming references of the target now points nowhere — for
            # example because it referenced an explicit path instead of a
            # basename.
            backlinks_after = Index.backlinks(new_index, normalized_to)

            result =
              {:ok,
               %{
                 from: normalized_from,
                 to: normalized_to,
                 pushed: true,
                 broken_backlinks: backlinks_before -- backlinks_after
               }}

            {result, new_state}

          {:error, out} ->
            {{:error, "Move committed locally, but push failed: #{out}"}, state}
        end

      {:error, out} ->
        {{:error, "git mv/commit failed: #{out}"}, state}
    end
  end

  defp reparse_moved_file(state, from, to, commit_meta) do
    existing_created_at =
      case Index.note(state.index, from) do
        %Index.Note{created_at: created_at} -> created_at
        nil -> nil
      end

    created_at = existing_created_at || commit_meta.updated_at

    case read_for_reparse(state.vault_path, to, "move") do
      {:ok, content} ->
        meta = %{
          created_at: created_at,
          updated_at: commit_meta.updated_at,
          last_author: commit_meta.last_author
        }

        {:ok, file} = Parser.parse(to, content, meta)

        state.index |> Index.remove(from) |> Index.put(file)

      :error ->
        state.index
    end
  end

  ## shared write path

  defp write_and_commit(state, rel_path, abs_path, full_content, message) do
    with :ok <- safe_mkdir_p(Path.dirname(abs_path)),
         :ok <- safe_write(abs_path, full_content) do
      case Git.add_commit(state.vault_path, rel_path, message) do
        {:ok, commit_meta} ->
          new_state = %{state | index: reparse_file(state, rel_path, commit_meta)}

          case Git.push(new_state.vault_path, new_state.git_remote) do
            :ok ->
              {{:ok, %{path: rel_path, pushed: true}}, new_state}

            {:error, out} ->
              {{:error, "Change saved and committed locally, but push failed: #{out}"}, new_state}
          end

        {:error, out} ->
          {{:error, "git commit failed: #{out}"}, state}
      end
    else
      {:error, msg} -> {{:error, msg}, state}
    end
  end

  defp safe_mkdir_p(path) do
    case File.mkdir_p(path) do
      :ok ->
        :ok

      {:error, reason} ->
        {:error, "Could not create directory #{path}: #{fs_error(reason)}"}
    end
  end

  defp safe_write(path, content) do
    case File.write(path, content) do
      :ok ->
        :ok

      {:error, reason} ->
        {:error, "Could not write file #{path}: #{fs_error(reason)}"}
    end
  end

  defp fs_error(:eacces), do: "no write permission"
  defp fs_error(:enospc), do: "out of disk space"
  defp fs_error(:eisdir), do: "target path is a directory"
  defp fs_error(:enotdir), do: "a path component is not a directory"
  defp fs_error(:erofs), do: "filesystem is read-only"
  defp fs_error(reason), do: inspect(reason)

  # Used by the write paths that read a note's current content before
  # transforming it (append, rewrite_note, splice_chunk, update_frontmatter).
  # A read failure here happens before anything is written, so it is
  # reported back to the caller as an ordinary error tuple rather than
  # crashing the GenServer.
  defp read_existing_file(path) do
    case File.read(path) do
      {:ok, content} -> {:ok, content}
      {:error, reason} -> {:error, "Could not read file #{path}: #{fs_error(reason)}"}
    end
  end

  # Used by reparse_file/reparse_moved_file: the write or move itself has
  # already succeeded (and been committed/pushed) by the time these run. A
  # read failure here must not crash the GenServer and take down unrelated
  # calls — it only means the index stays stale for `rel_path` until the
  # next reload, so the failure is logged rather than propagated.
  defp read_for_reparse(vault_path, rel_path, verb) do
    case File.read(Path.join(vault_path, rel_path)) do
      {:ok, content} ->
        {:ok, content}

      {:error, reason} ->
        Logger.warning("vigil: could not reparse #{rel_path} after #{verb}: #{fs_error(reason)}")
        :error
    end
  end

  defp reparse_file(state, rel_path, commit_meta) do
    existing_created_at =
      case Index.note(state.index, rel_path) do
        %Index.Note{created_at: created_at} -> created_at
        nil -> nil
      end

    created_at = existing_created_at || commit_meta.updated_at

    case read_for_reparse(state.vault_path, rel_path, "write") do
      {:ok, content} ->
        meta = %{
          created_at: created_at,
          updated_at: commit_meta.updated_at,
          last_author: commit_meta.last_author
        }

        {:ok, file} = Parser.parse(rel_path, content, meta)

        Index.put(state.index, file)

      :error ->
        state.index
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
