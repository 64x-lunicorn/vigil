defmodule Vigil.Store do
  @moduledoc false
  use GenServer
  require Logger

  alias Vigil.{Parser, Git, Search, SkillKey, Slug}

  @chunks_table :vigil_chunks
  @files_table :vigil_files
  # Separate out/in tables rather than one. :links_out holds, per source
  # chunk, the resolved (or ambiguous/broken) targets; :links_in holds, per
  # target (note path AND, where present, full chunk id), the source chunk
  # ids — only for links that resolved successfully.
  @links_out_table :vigil_links_out
  @links_in_table :vigil_links_in

  @heading_re ~r/^(\#{2,4})\s+(.+?)\s*$/

  @overlong_note_chunk_threshold 40
  @stale_decision_days 180
  @sentence_heading_length_threshold 60

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
  def active_event_ids(now), do: GenServer.call(__MODULE__, {:active_event_ids, now})
  def file_title(path), do: GenServer.call(__MODULE__, {:file_title, path})
  def near_summary(now), do: GenServer.call(__MODULE__, {:near_summary, now})
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

    ensure_tables()

    state = %{vault_path: vault_path, exclude: exclude, git_remote: git_remote, domains_desc: %{}}
    {state, pull_result} = do_full_load(state)

    case pull_result do
      :ok -> :ok
      {:error, reason} -> Logger.warning("vigil: initialer git pull fehlgeschlagen: #{reason}")
    end

    {:ok, state}
  end

  defp ensure_tables do
    for {name, type} <- [
          {@chunks_table, :set},
          {@files_table, :set},
          {@links_out_table, :bag},
          {@links_in_table, :bag}
        ] do
      if :ets.whereis(name) == :undefined do
        :ets.new(name, [type, :named_table, :private])
      end
    end
  end

  @impl true
  def handle_call({:search, params}, _from, state) do
    {:reply, do_search(params, state), state}
  end

  def handle_call({:read, id, backlinks?}, _from, state) do
    {:reply, do_read(id, backlinks?, state), state}
  end

  def handle_call({:links, id, direction, depth}, _from, state) do
    {:reply, do_links(id, direction, depth), state}
  end

  def handle_call({:create, params}, _from, state) do
    {:reply, do_create(params, state), state}
  end

  def handle_call({:append, params}, _from, state) do
    {:reply, do_append(params, state), state}
  end

  def handle_call({:replace_section, id, content}, _from, state) do
    {:reply, do_replace_section(id, content, state), state}
  end

  def handle_call({:rewrite_note, params}, _from, state) do
    {:reply, do_rewrite_note(params, state), state}
  end

  def handle_call({:delete_section, id}, _from, state) do
    {:reply, do_delete_section(id, state), state}
  end

  def handle_call({:update_frontmatter, params}, _from, state) do
    {:reply, do_update_frontmatter(params, state), state}
  end

  def handle_call({:delete_note, params}, _from, state) do
    {:reply, do_delete_note(params, state), state}
  end

  def handle_call({:move_note, params}, _from, state) do
    {:reply, do_move_note(params, state), state}
  end

  def handle_call({:lint, now}, _from, state) do
    {:reply, do_lint(now || DateTime.now!(tz())), state}
  end

  def handle_call({:current, now}, _from, state) do
    {:reply, do_current(now || DateTime.now!(tz())), state}
  end

  def handle_call({:active_event_ids, now}, _from, state) do
    {:reply, do_active_event_ids(now), state}
  end

  def handle_call({:near_summary, now}, _from, state) do
    {:reply, do_near_summary(now), state}
  end

  def handle_call({:file_title, path}, _from, state) do
    title =
      case :ets.lookup(@files_table, path) do
        [{_, file}] -> file.title
        [] -> path
      end

    {:reply, title, state}
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

  defp tz, do: Application.get_env(:vigil, :tz, "Europe/Berlin")

  defp reload_result(:ok), do: %{reloaded: true}
  defp reload_result({:error, reason}), do: %{reloaded: true, pull_failed: reason}

  ## Loading

  defp do_full_load(state) do
    pull_result = Git.pull(state.vault_path, state.git_remote)

    git_meta = Git.log_metadata(state.vault_path)
    domains_desc = load_domains_yml(state.vault_path)

    :ets.delete_all_objects(@chunks_table)
    :ets.delete_all_objects(@files_table)

    domain_dirs = discover_domain_dirs(state.vault_path, state.exclude)

    warn_domain_mismatches(domain_dirs, domains_desc)

    files =
      domain_dirs
      |> Enum.flat_map(&list_domain_files(state.vault_path, &1))

    Enum.each(files, fn rel_path ->
      load_file(state.vault_path, rel_path, git_meta)
    end)

    rebuild_links_index()

    note_count = :ets.info(@files_table, :size)
    chunk_count = :ets.info(@chunks_table, :size)

    Logger.info(
      "vigil: #{length(domain_dirs)} domains (#{Enum.join(domain_dirs, ", ")}), #{note_count} notes, #{chunk_count} chunks"
    )

    {%{state | domains_desc: domains_desc}, pull_result}
  end

  defp discover_domain_dirs(vault_path, exclude) do
    case File.ls(vault_path) do
      {:ok, entries} ->
        entries
        |> Enum.filter(fn name -> File.dir?(Path.join(vault_path, name)) end)
        |> Enum.reject(fn name ->
          name == "skills" or name in exclude or String.starts_with?(name, ".") or
            String.starts_with?(name, "_")
        end)
        |> Enum.sort()

      {:error, _} ->
        []
    end
  end

  defp warn_domain_mismatches(domain_dirs, domains_desc) do
    for key <- Map.keys(domains_desc), key not in domain_dirs do
      Logger.warning("_domains.yml: key '#{key}' has no matching directory")
    end

    for dir <- domain_dirs, not Map.has_key?(domains_desc, dir) do
      Logger.warning("domain '#{dir}' has no entry in _domains.yml")
    end
  end

  defp list_domain_files(vault_path, "projects" = domain) do
    Path.wildcard(Path.join([vault_path, domain, "*", "*.md"]))
    |> Enum.map(&Path.relative_to(&1, vault_path))
  end

  defp list_domain_files(vault_path, domain) do
    Path.wildcard(Path.join([vault_path, domain, "*.md"]))
    |> Enum.map(&Path.relative_to(&1, vault_path))
  end

  defp load_file(vault_path, rel_path, git_meta) do
    abs_path = Path.join(vault_path, rel_path)

    case File.read(abs_path) do
      {:ok, content} ->
        meta = Map.get(git_meta, rel_path, %{created_at: nil, updated_at: nil, last_author: nil})
        {:ok, file} = Parser.parse(rel_path, content, meta)
        index_file(file)

      {:error, reason} ->
        Logger.warning("cannot read #{rel_path}: #{inspect(reason)}")
    end
  end

  defp index_file(file) do
    domain = domain_of(file.path)
    chunk_ids = Enum.map(file.chunks, & &1.id)

    :ets.insert(
      @files_table,
      {file.path,
       %{
         path: file.path,
         domain: domain,
         title: file.title,
         type: file.type,
         starts: file.starts,
         ends: file.ends,
         created_at: file.created_at,
         updated_at: file.updated_at,
         chunk_ids: chunk_ids
       }}
    )

    Enum.each(file.chunks, fn chunk ->
      record = %{
        id: chunk.id,
        path: chunk.path,
        domain: domain,
        heading: chunk.heading,
        heading_path: chunk.heading_path,
        heading_line: chunk.heading_line,
        body_start_line: chunk.body_start_line,
        body_end_line: chunk.body_end_line,
        file_title: file.title,
        type: chunk.type,
        starts: chunk.starts,
        ends: chunk.ends,
        body: chunk.body,
        body_downcased: chunk.body_downcased,
        # Raw and unresolved — Vigil.Parser.extract_links/1 only sees this
        # one file, not the rest of the vault. Resolution (same-folder →
        # domain → vault-wide, ambiguous/broken) is rebuild_links_index/0's job.
        raw_links: chunk.links,
        created_at: chunk.created_at,
        updated_at: chunk.updated_at
      }

      :ets.insert(@chunks_table, {chunk.id, record})
    end)
  end

  defp domain_of(path), do: path |> String.split("/") |> hd()

  ## Link-Index (AP15)
  #
  # Rebuilt in full on every load and every single-file reparse (write, move,
  # delete) instead of being maintained incrementally. At the vault sizes
  # vigil targets this is cheap, and it structurally rules out the "ghost
  # entry after delete/rename" class of bug that incremental maintenance
  # across two tables would invite.

  defp rebuild_links_index do
    :ets.delete_all_objects(@links_out_table)
    :ets.delete_all_objects(@links_in_table)

    all_files = :ets.tab2list(@files_table) |> Enum.map(fn {_path, f} -> f end)
    all_chunks = :ets.tab2list(@chunks_table) |> Enum.map(fn {_id, c} -> c end)
    index = build_resolution_index(all_files)

    Enum.each(all_chunks, fn chunk ->
      Enum.each(chunk.raw_links, fn raw_link ->
        resolved = resolve_link(raw_link, chunk.path, index)
        :ets.insert(@links_out_table, {chunk.id, resolved})
        record_incoming(chunk.id, resolved)
      end)
    end)
  end

  # Built once per rebuild rather than once per link. `slugify/1` is
  # expensive (NFC, transliteration, several regex passes). Without this
  # index every link would re-slugify every filename — O(links × files) — and
  # since the index is rebuilt on EVERY write, that would be the hottest path
  # in the server. Measured: ~14 ms per link at 1000 files, i.e. ~14 s per
  # write at 1000 links, far beyond GenServer.call's 5 s timeout. With the
  # index: one O(files) slugify pass, then map lookups.
  defp build_resolution_index(all_files) do
    %{
      paths: MapSet.new(all_files, & &1.path),
      by_slug:
        Enum.group_by(all_files, fn f ->
          case Slug.slugify(Path.basename(f.path, ".md")) do
            {:ok, s} -> s
            {:error, _} -> nil
          end
        end)
        |> Map.delete(nil)
    }
  end

  defp record_incoming(source_chunk_id, %{status: :ok, target_note: note, target_chunk: nil}) do
    :ets.insert(@links_in_table, {note, source_chunk_id})
  end

  defp record_incoming(source_chunk_id, %{status: :ok, target_note: note, target_chunk: chunk_id}) do
    :ets.insert(@links_in_table, {note, source_chunk_id})
    :ets.insert(@links_in_table, {chunk_id, source_chunk_id})
  end

  defp record_incoming(_source_chunk_id, _resolved), do: :ok

  # resolve_link(%{raw:, fragment:}, quell_pfad, alle_dateien)
  #   → %{raw:, fragment:, status: :ok | :ambiguous | :broken, target_note:,
  #        target_chunk:, candidates:}
  # If raw contains a "/" it is treated as a vault-relative path, otherwise
  # as a basename resolved through the cascade same folder → same domain →
  # vault-wide.
  defp resolve_link(%{raw: raw, fragment: fragment}, source_path, index) do
    base = %{raw: raw, fragment: fragment, candidates: []}

    case resolve_target_note(raw, source_path, index) do
      {:ok, note_path} ->
        resolve_fragment(base, note_path, fragment)

      {:ambiguous, candidates} ->
        Map.merge(base, %{
          status: :ambiguous,
          target_note: nil,
          target_chunk: nil,
          candidates: candidates
        })

      :broken ->
        Map.merge(base, %{status: :broken, target_note: nil, target_chunk: nil})
    end
  end

  defp resolve_target_note(raw, source_path, index) do
    if String.contains?(raw, "/") do
      target_path = ensure_md_extension(raw)

      if MapSet.member?(index.paths, target_path) do
        {:ok, target_path}
      else
        :broken
      end
    else
      resolve_basename(raw, source_path, index)
    end
  end

  # Same folder first, then same domain, then vault-wide — each stage only
  # if the previous one came up empty. If a stage finds more than one match
  # the result is ambiguous with exactly those candidates, not with those of
  # later stages.
  defp resolve_basename(raw, source_path, index) do
    case Slug.slugify(raw) do
      {:ok, target_slug} ->
        candidates = Map.get(index.by_slug, target_slug, [])

        source_dir = Path.dirname(source_path)
        source_domain = domain_of(source_path)

        same_folder = Enum.filter(candidates, &(Path.dirname(&1.path) == source_dir))
        same_domain = Enum.filter(candidates, &(&1.domain == source_domain))

        cond do
          same_folder != [] -> pick_candidate(same_folder)
          same_domain != [] -> pick_candidate(same_domain)
          true -> pick_candidate(candidates)
        end

      {:error, _} ->
        :broken
    end
  end

  defp pick_candidate([]), do: :broken
  defp pick_candidate([one]), do: {:ok, one.path}
  defp pick_candidate(many), do: {:ambiguous, Enum.map(many, & &1.path)}

  defp ensure_md_extension(path) do
    if String.ends_with?(path, ".md"), do: path, else: path <> ".md"
  end

  defp resolve_fragment(base, note_path, nil) do
    Map.merge(base, %{status: :ok, target_note: note_path, target_chunk: nil})
  end

  defp resolve_fragment(base, note_path, fragment) do
    case Slug.slugify(fragment) do
      {:ok, fragment_slug} ->
        chunk_id = "#{note_path}##{fragment_slug}"

        if :ets.member(@chunks_table, chunk_id) do
          Map.merge(base, %{status: :ok, target_note: note_path, target_chunk: chunk_id})
        else
          Map.merge(base, %{status: :broken, target_note: nil, target_chunk: nil})
        end

      {:error, _} ->
        Map.merge(base, %{status: :broken, target_note: nil, target_chunk: nil})
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

  defp domain_naming(state, domain) do
    state.domains_desc
    |> Map.get(domain, %{})
    |> Map.get(:naming)
  end

  defp domains_yaml_raw(vault_path) do
    path = Path.join(vault_path, "_domains.yml")
    if File.exists?(path), do: File.read!(path), else: ""
  end

  defp list_domain_names(state), do: discover_domain_dirs(state.vault_path, state.exclude)

  ## Search

  defp do_search(params, _state) do
    query = Map.fetch!(params, :query)
    domain = Map.get(params, :domain)
    type_filter = Map.get(params, :type)
    prefer = Map.get(params, :prefer)
    limit = Map.get(params, :limit, 10)

    items =
      :ets.tab2list(@chunks_table)
      |> Enum.map(fn {_id, rec} -> rec end)
      |> Enum.filter(fn rec ->
        domain_ok =
          case domain do
            nil -> rec.domain != "journal"
            d -> rec.domain == d
          end

        type_ok = type_filter == nil or rec.type == type_filter
        domain_ok and type_ok
      end)
      |> Enum.map(fn rec ->
        %{
          id: rec.id,
          file_title: rec.file_title,
          heading_path: rec.heading_path,
          type: rec.type,
          body: rec.body,
          body_downcased: rec.body_downcased,
          updated_at: rec.updated_at
        }
      end)

    items
    |> Search.run(query, %{limit: limit, prefer: prefer})
    |> Enum.map(&attach_hub/1)
  end

  # The hub of a note, when exactly one other note links to it. Linked from
  # several notes means the hub is ambiguous, and the field is omitted rather
  # than guessed.
  defp attach_hub(result) do
    note_path = result.id |> String.split("#", parts: 2) |> hd()

    source_notes =
      note_path
      |> backlinks_for()
      |> Enum.map(fn source_chunk_id ->
        source_chunk_id |> String.split("#", parts: 2) |> hd()
      end)
      |> Enum.uniq()
      |> Enum.reject(&(&1 == note_path))

    case source_notes do
      [hub] -> Map.put(result, :hub, hub)
      _ -> result
    end
  end

  ## Read

  defp do_read(id, backlinks?, state) do
    path_part = id |> String.split("#", parts: 2) |> hd()

    with :ok <- basic_path_sanity(path_part) do
      if String.contains?(id, "#") do
        [_, heading_slug] = String.split(id, "#", parts: 2)

        lookup_lenient(@chunks_table, id, fn ->
          with {:ok, normalized_path, true} <- Slug.normalize_path(path_part) do
            "#{normalized_path}##{heading_slug}"
          else
            _ -> nil
          end
        end)
        |> case do
          {:ok, rec} -> {:ok, chunk_result(rec, backlinks?)}
          :not_found -> {:error, "Nicht gefunden: #{id}"}
        end
      else
        lookup_lenient(@files_table, id, fn ->
          with {:ok, normalized_path, true} <- Slug.normalize_path(id) do
            normalized_path
          else
            _ -> nil
          end
        end)
        |> case do
          {:ok, file} -> {:ok, file_result(file, backlinks?, state)}
          :not_found -> {:error, "Nicht gefunden: #{id}"}
        end
      end
    else
      {:error, _} -> {:error, "Invalid path"}
    end
  end

  # If the exact lookup misses, the path part is normalized via
  # Slug.normalize_path/1 and tried again. The record that comes back carries
  # the canonical stored path anyway, so no extra field is needed on the
  # response.
  defp lookup_lenient(table, exact_key, fallback_key_fun) do
    case :ets.lookup(table, exact_key) do
      [{_, rec}] ->
        {:ok, rec}

      [] ->
        case fallback_key_fun.() do
          nil ->
            :not_found

          fallback_key ->
            case :ets.lookup(table, fallback_key) do
              [{_, rec}] -> {:ok, rec}
              [] -> :not_found
            end
        end
    end
  end

  ## Links (AP15 §5.4)

  defp do_links(id, direction, depth) do
    path_part = id |> String.split("#", parts: 2) |> hd()

    with :ok <- basic_path_sanity(path_part),
         :ok <- validate_depth(depth) do
      if String.contains?(id, "#") do
        lookup_lenient(@chunks_table, id, fn ->
          with {:ok, normalized_path, true} <- Slug.normalize_path(path_part) do
            [_, fragment] = String.split(id, "#", parts: 2)
            "#{normalized_path}##{fragment}"
          else
            _ -> nil
          end
        end)
        |> case do
          {:ok, rec} -> {:ok, build_links_result(rec.id, [rec.id], direction, depth)}
          :not_found -> {:error, "Nicht gefunden: #{id}"}
        end
      else
        lookup_lenient(@files_table, id, fn ->
          with {:ok, normalized_path, true} <- Slug.normalize_path(id) do
            normalized_path
          else
            _ -> nil
          end
        end)
        |> case do
          {:ok, file} -> {:ok, build_links_result(file.path, file.chunk_ids, direction, depth)}
          :not_found -> {:error, "Nicht gefunden: #{id}"}
        end
      end
    else
      {:error, msg} -> {:error, msg}
    end
  end

  defp validate_depth(d) when d in [1, 2], do: :ok
  defp validate_depth(_), do: {:error, "depth must be 1 or 2 (no deeper value allowed)"}

  defp build_links_result(id, chunk_ids, direction, depth) do
    base = %{id: id}

    base =
      if direction in [:out, :both],
        do: Map.put(base, :outgoing, outgoing_for(chunk_ids)),
        else: base

    base =
      if direction in [:in, :both], do: Map.put(base, :incoming, incoming_for(id)), else: base

    if depth == 2, do: Map.put(base, :neighbors, neighbors_for(base, id)), else: base
  end

  defp outgoing_for(chunk_ids) do
    Enum.flat_map(chunk_ids, fn cid ->
      @links_out_table
      |> :ets.lookup(cid)
      |> Enum.map(fn {_cid, resolved} -> format_outgoing(cid, resolved) end)
    end)
  end

  defp format_outgoing(from_chunk, %{status: :ok, target_chunk: nil, target_note: note}) do
    %{target: note, from_chunk: from_chunk, status: "ok"}
  end

  defp format_outgoing(from_chunk, %{status: :ok, target_chunk: chunk_id}) do
    %{target: chunk_id, from_chunk: from_chunk, status: "ok"}
  end

  defp format_outgoing(from_chunk, %{status: :ambiguous, candidates: candidates} = resolved) do
    %{
      target: link_label(resolved),
      from_chunk: from_chunk,
      status: "ambiguous",
      candidates: candidates
    }
  end

  defp format_outgoing(from_chunk, %{status: :broken} = resolved) do
    %{target: link_label(resolved), from_chunk: from_chunk, status: "broken"}
  end

  # A link to an existing note with a non-existent fragment is `broken` too.
  # Without the fragment in the label the finding would read as "note
  # missing" when only the section is missing.
  defp link_label(%{raw: raw, fragment: nil}), do: raw
  defp link_label(%{raw: raw, fragment: fragment}), do: "#{raw}##{fragment}"

  defp incoming_for(id) do
    id
    |> backlinks_for()
    |> Enum.map(fn source -> %{source: source, status: "ok"} end)
  end

  # depth: 2 — for each directly connected note its own depth-1 out/in, with
  # no further recursion. Beyond that the value drops off fast while the
  # response size does not.
  defp neighbors_for(base, own_id) do
    own_note = own_id |> String.split("#", parts: 2) |> hd()

    outgoing_notes =
      base
      |> Map.get(:outgoing, [])
      |> Enum.filter(&(&1.status == "ok"))
      |> Enum.map(fn %{target: t} -> t |> String.split("#", parts: 2) |> hd() end)

    incoming_notes =
      base
      |> Map.get(:incoming, [])
      |> Enum.map(fn %{source: s} -> s |> String.split("#", parts: 2) |> hd() end)

    (outgoing_notes ++ incoming_notes)
    |> Enum.uniq()
    |> Enum.reject(&(&1 == own_note))
    |> Map.new(fn note_path ->
      chunk_ids =
        case :ets.lookup(@files_table, note_path) do
          [{_, file}] -> file.chunk_ids
          [] -> []
        end

      {note_path, %{outgoing: outgoing_for(chunk_ids), incoming: incoming_for(note_path)}}
    end)
  end

  defp chunk_result(rec, backlinks?) do
    base = %{
      id: rec.id,
      heading: rec.heading,
      heading_path: rec.heading_path,
      type: rec.type,
      starts: iso(rec.starts),
      ends: iso(rec.ends),
      body: rec.body,
      created_at: iso(rec.created_at),
      updated_at: iso(rec.updated_at)
    }

    if backlinks? do
      Map.put(base, :backlinks, backlinks_for(rec.path))
    else
      base
    end
  end

  defp file_result(file, backlinks?, _state) do
    toc =
      file.chunk_ids
      |> Enum.map(fn cid -> :ets.lookup(@chunks_table, cid) end)
      |> Enum.flat_map(fn
        [{_, rec}] -> [rec]
        [] -> []
      end)
      |> Enum.filter(& &1.heading)
      |> Enum.map(fn rec ->
        %{id: rec.id, heading: rec.heading, heading_path: rec.heading_path}
      end)

    base = %{
      path: file.path,
      title: file.title,
      type: file.type,
      starts: iso(file.starts),
      ends: iso(file.ends),
      created_at: iso(file.created_at),
      updated_at: iso(file.updated_at),
      toc: toc,
      links: note_link_counts(file)
    }

    if backlinks? do
      Map.put(base, :backlinks, backlinks_for(file.path))
    else
      base
    end
  end

  # A compact counter field on every note `read` response. Details come from
  # the `links` tool, not from `read` itself — otherwise every read response
  # grows ballast.
  defp note_link_counts(file) do
    outgoing =
      file.chunk_ids
      |> Enum.flat_map(fn cid -> :ets.lookup(@links_out_table, cid) end)
      |> Enum.map(fn {_cid, resolved} -> resolved end)

    %{
      out: Enum.count(outgoing, &(&1.status == :ok)),
      in: length(backlinks_for(file.path)),
      broken: Enum.count(outgoing, &(&1.status != :ok))
    }
  end

  defp backlinks_for(target_key) do
    @links_in_table
    |> :ets.lookup(target_key)
    |> Enum.map(fn {_target, source_id} -> source_id end)
    |> Enum.uniq()
  end

  defp iso(nil), do: nil
  defp iso(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  ## Path validation (section 5)

  defp basic_path_sanity(path) do
    cond do
      String.contains?(path, "..") ->
        {:error, "Invalid path"}

      String.starts_with?(path, "/") ->
        {:error, "Invalid path"}

      String.contains?(path, "\\") ->
        {:error, "Invalid path"}

      String.contains?(path, <<0>>) ->
        {:error, "Invalid path"}

      Enum.any?(String.split(path, "/"), &reserved_segment?/1) ->
        {:error, "Invalid path"}

      true ->
        :ok
    end
  end

  # A leading "." (hidden) or "_" (reserved, e.g. _domains.yml) is allowed in
  # no path segment — checked both before and after normalization.
  defp reserved_segment?(segment) do
    String.starts_with?(segment, ".") or String.starts_with?(segment, "_")
  end

  defp resolve_within_vault(state, path) do
    abs = Path.expand(path, state.vault_path)

    if String.starts_with?(abs, state.vault_path <> "/") do
      {:ok, abs}
    else
      {:error, "Invalid path"}
    end
  end

  defp validate_write_path(path, state, create_dirs \\ false) do
    with :ok <- basic_path_sanity(path),
         {:ok, _abs} <- resolve_within_vault(state, path) do
      parts = String.split(path, "/")
      first = hd(parts)
      last = List.last(parts)

      cond do
        not String.ends_with?(last, ".md") ->
          {:error, "Invalid path"}

        first == "skills" ->
          {:error, "Invalid path"}

        first in state.exclude ->
          {:error, "Invalid path"}

        String.starts_with?(first, ".") or String.starts_with?(first, "_") ->
          {:error, "Invalid path"}

        length(parts) == 2 ->
          validate_domain(first, parts, state, create_dirs)

        length(parts) == 3 and first == "projects" ->
          validate_domain(first, parts, state, create_dirs)

        true ->
          {:error, "Invalid path"}
      end
    else
      {:error, msg} -> {:error, msg}
    end
  end

  defp validate_domain(first, parts, state, create_dirs) do
    domains = list_domain_names(state)

    if first not in domains do
      {:error, "Invalid path. Available domains: #{Enum.join(domains, ", ")}"}
    else
      if length(parts) == 3 do
        project_dir = Path.join([state.vault_path, "projects", Enum.at(parts, 1)])

        cond do
          File.dir?(project_dir) ->
            {:ok, first}

          create_dirs ->
            case safe_mkdir_p(project_dir) do
              :ok -> {:ok, first}
              {:error, msg} -> {:error, msg}
            end

          true ->
            {:error, "Invalid path. Project directory does not exist: #{Enum.at(parts, 1)}"}
        end
      else
        {:ok, first}
      end
    end
  end

  ## naming convention (AP9a §4 — Schicht 3, aus _domains.yml)

  defp check_naming_convention(path, domain, state, content) do
    case domain_naming(state, domain) do
      nil ->
        :ok

      naming ->
        with :ok <- check_naming_pattern(path, domain, naming, content),
             :ok <- check_naming_max_depth(path, domain, naming) do
          :ok
        end
    end
  end

  defp check_naming_pattern(path, domain, naming, content) do
    scope_string = naming_scope_string(path, domain, naming.scope)

    if Regex.match?(naming.pattern, scope_string) do
      :ok
    else
      suggestion = naming_suggestion_path(path, domain, naming, content)

      {:error,
       "The name \"#{scope_string}\" does not match the schema for domain #{domain}.\n" <>
         "#{naming.hint}\nSuggestion: #{suggestion}"}
    end
  end

  defp check_naming_max_depth(_path, _domain, %{max_depth: nil}), do: :ok

  defp check_naming_max_depth(path, domain, %{max_depth: max_depth}) do
    depth_level = path |> naming_scope_string(domain, :relpath) |> String.split("/") |> length()

    if depth_level <= max_depth do
      :ok
    else
      {:error, "Invalid path. Domain #{domain} allows at most #{max_depth} nesting level(s)."}
    end
  end

  defp naming_scope_string(path, _domain, :filename), do: Path.basename(path)

  defp naming_scope_string(path, domain, :relpath) do
    case String.split(path, "/") do
      [^domain | rest] -> Enum.join(rest, "/")
      _ -> path
    end
  end

  defp naming_suggestion_path(_path, domain, %{suggestion: :date}, _content) do
    heute = DateTime.now!(tz()) |> DateTime.to_date() |> Date.to_iso8601()
    "#{domain}/#{heute}.md"
  end

  defp naming_suggestion_path(path, _domain, %{suggestion: :slug}, content) do
    directory = Path.dirname(path)

    case extract_h1(content) do
      nil ->
        path

      h1 ->
        case Slug.slugify(h1) do
          {:ok, slug} -> "#{directory}/#{slug}.md"
          {:error, _} -> path
        end
    end
  end

  defp extract_h1(content) do
    content
    |> split_lines()
    |> Enum.find_value(fn line ->
      case Regex.run(~r/^\#\s+(.+?)\s*$/, line) do
        [_, text] -> String.trim(text)
        _ -> nil
      end
    end)
  end

  ## create

  defp do_create(params, state) do
    path = Map.fetch!(params, :path)
    type = Map.fetch!(params, :type)
    content = Map.fetch!(params, :content)
    starts = Map.get(params, :starts)
    ends = Map.get(params, :ends)
    force = Map.get(params, :force, false)
    create_dirs = Map.get(params, :create_dirs, false)

    with :ok <- basic_path_sanity(path),
         {:ok, normalized_path, changed?} <- normalize_path_or_error(path),
         :ok <- basic_path_sanity(normalized_path),
         {:ok, domain} <- validate_write_path(normalized_path, state, create_dirs),
         :ok <- check_naming_convention(normalized_path, domain, state, content),
         {:ok, abs_path} <- resolve_within_vault(state, normalized_path),
         :ok <- ensure_not_exists(abs_path, normalized_path),
         :ok <- validate_content_shape(content),
         {:ok, type_atom, starts_dt, ends_dt} <- validate_type_and_times(type, starts, ends),
         :ok <- check_duplicates(normalized_path, domain, force, state) do
      frontmatter = build_frontmatter(type_atom, starts_dt, ends_dt)
      full_content = normalize_trailing_newline(frontmatter <> content)

      result =
        write_and_commit(
          state,
          normalized_path,
          abs_path,
          full_content,
          "create: #{normalized_path} — #{first_line(content)}"
        )

      case result do
        {:ok, ok_map} when changed? -> {:ok, Map.put(ok_map, :path_normalized_from, path)}
        other -> other
      end
    else
      {:error, msg} -> {:error, msg}
    end
  end

  defp normalize_path_or_error(path) do
    case Slug.normalize_path(path) do
      {:ok, normalized, changed?} ->
        {:ok, normalized, changed?}

      {:error, _reason} ->
        {:error,
         "No valid filename can be derived from \"#{path}\". Use a name containing letters or digits."}
    end
  end

  defp ensure_not_exists(abs_path, path) do
    if File.exists?(abs_path) do
      {:error, "File already exists: #{path}"}
    else
      :ok
    end
  end

  defp validate_content_shape(content) do
    trimmed = String.trim_leading(content)

    cond do
      String.starts_with?(trimmed, "---") ->
        {:error, "content must not contain its own frontmatter block"}

      not Regex.match?(~r/^\#\s+.+/, trimmed) ->
        {:error, "content must start with an H1 (# Title)"}

      true ->
        :ok
    end
  end

  defp validate_type_and_times(type, starts, ends) do
    type_atom =
      case type do
        "reference" -> :reference
        "decision" -> :decision
        "event" -> :event
        t when is_atom(t) -> t
        _ -> nil
      end

    cond do
      type_atom == nil ->
        {:error, "Invalid type"}

      type_atom == :event and (is_nil(starts) or is_nil(ends)) ->
        {:error, "starts/ends sind Pflicht bei type: event"}

      type_atom != :event and (not is_nil(starts) or not is_nil(ends)) ->
        {:error, "starts/ends sind nur bei type: event erlaubt"}

      type_atom == :event ->
        with {:ok, s, _} <- DateTime.from_iso8601(starts),
             {:ok, e, _} <- DateTime.from_iso8601(ends) do
          {:ok, type_atom, s, e}
        else
          _ -> {:error, "starts/ends must be valid ISO8601 timestamps with an offset"}
        end

      true ->
        {:ok, type_atom, nil, nil}
    end
  end

  defp check_duplicates(_path, _domain, true, _state), do: :ok

  defp check_duplicates(path, domain, false, _state) do
    stem = Path.basename(path, ".md")

    tokens =
      stem
      |> String.split("-")
      |> Enum.filter(fn t -> String.length(t) > 3 end)

    candidates =
      tokens
      |> Enum.flat_map(fn token ->
        do_search(%{query: token, domain: domain, limit: 25}, nil)
      end)
      |> Enum.filter(fn r -> r.score >= 10 end)
      |> Enum.uniq_by(& &1.id)
      |> Enum.reject(&same_project_folder?(&1.id, path, domain))

    if candidates == [] do
      :ok
    else
      ids = Enum.map(candidates, & &1.id) |> Enum.join(", ")

      {:error,
       "Possible duplicates found: #{ids}. If this is the same topic, extend one of those with append/replace_section instead of creating a new note — or pass force: true for a deliberately separate note."}
    end
  end

  defp same_project_folder?(candidate_id, path, "projects") do
    candidate_path = candidate_id |> String.split("#") |> hd()
    project_of(candidate_path) != nil and project_of(candidate_path) == project_of(path)
  end

  defp same_project_folder?(_candidate_id, _path, _domain), do: false

  defp project_of(path) do
    case String.split(path, "/") do
      ["projects", project | _] -> project
      _ -> nil
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
    path = Map.fetch!(params, :path)
    heading = Map.get(params, :heading)
    content = Map.fetch!(params, :content)

    with {:ok, abs_path} <- resolve_within_vault(state, path),
         :ok <- basic_path_sanity(path),
         :ok <- ensure_exists(abs_path, path) do
      {:ok, original} = File.read(abs_path)
      orig_lines = split_lines(original)

      new_lines = insert_append(path, orig_lines, heading, content)
      new_content = Enum.join(new_lines, "\n") <> "\n"

      write_and_commit(
        state,
        path,
        abs_path,
        new_content,
        "append: #{path} — #{first_line(content)}"
      )
    else
      {:error, msg} -> {:error, msg}
    end
  end

  defp ensure_exists(abs_path, path) do
    if File.exists?(abs_path), do: :ok, else: {:error, "File not found: #{path}"}
  end

  defp insert_append(_path, orig_lines, nil, content) do
    orig_lines ++ [""] ++ split_lines(content)
  end

  defp insert_append(path, orig_lines, heading, content) do
    target_slug = Parser.slug(heading)
    existing = find_chunk_by_heading_slug(path, target_slug)

    case existing do
      nil ->
        orig_lines ++ ["", "## #{heading}"] ++ split_lines(content)

      rec ->
        prefix = Enum.slice(orig_lines, 0, rec.body_end_line)
        suffix = Enum.slice(orig_lines, rec.body_end_line, length(orig_lines) - rec.body_end_line)
        prefix ++ split_lines(content) ++ suffix
    end
  end

  defp find_chunk_by_heading_slug(path, target_slug) do
    case :ets.lookup(@files_table, path) do
      [{_, file}] ->
        file.chunk_ids
        |> Enum.map(fn cid -> :ets.lookup(@chunks_table, cid) end)
        |> Enum.flat_map(fn
          [{_, rec}] -> [rec]
          [] -> []
        end)
        |> Enum.find(fn rec -> rec.heading && Parser.slug(rec.heading) == target_slug end)

      [] ->
        nil
    end
  end

  ## replace_section

  defp do_replace_section(id, content, state) do
    case String.split(id, "#", parts: 2) do
      [path, _frag] ->
        with :ok <- basic_path_sanity(path),
             {:ok, abs_path} <- resolve_within_vault(state, path),
             [{_, rec}] <- {:ets.lookup(@chunks_table, id)} |> unwrap_lookup(),
             true <- rec.heading != nil,
             :ok <- validate_replace_content(content) do
          {:ok, original} = File.read(abs_path)
          orig_lines = split_lines(original)

          prefix = Enum.slice(orig_lines, 0, rec.heading_line)

          suffix =
            Enum.slice(orig_lines, rec.body_end_line, length(orig_lines) - rec.body_end_line)

          new_lines = prefix ++ split_lines(content) ++ suffix
          new_content = Enum.join(new_lines, "\n") <> "\n"

          write_and_commit(state, path, abs_path, new_content, "replace_section: #{id}")
        else
          false -> {:error, "A section without a heading cannot be replaced: #{id}"}
          {:error, msg} -> {:error, msg}
          :not_found -> {:error, "Nicht gefunden: #{id}"}
        end

      [_path] ->
        {:error, "id must contain a fragment: path#heading-slug"}
    end
  end

  defp unwrap_lookup({[{_, _rec}] = list}), do: list
  defp unwrap_lookup({[]}), do: :not_found

  defp validate_replace_content(content) do
    lines = split_lines(content)

    if Enum.any?(lines, &Regex.match?(@heading_re, &1)) do
      {:error, "content must not contain headings (## through ####)"}
    else
      :ok
    end
  end

  ## rewrite_note

  defp do_rewrite_note(params, state) do
    path = Map.fetch!(params, :path)
    content = Map.fetch!(params, :content)
    confirm = Map.get(params, :confirm, false)

    with {:ok, abs_path} <- resolve_within_vault(state, path),
         :ok <- basic_path_sanity(path),
         :ok <- ensure_exists(abs_path, path),
         :ok <- validate_content_shape(content),
         :ok <- check_rewrite_shrink_threshold(path, content, confirm) do
      {:ok, original} = File.read(abs_path)

      case split_frontmatter(original) do
        {:ok, frontmatter, _old_body} ->
          new_content = normalize_trailing_newline(frontmatter <> content)
          write_and_commit(state, path, abs_path, new_content, "rewrite_note: #{path}")

        {:error, msg} ->
          {:error, msg}
      end
    else
      {:error, msg} -> {:error, msg}
    end
  end

  # confirm is only required when the new version removes more than half of
  # the existing sections OR more than 20 headings; below that rewrite_note
  # goes through without it. The baseline (old heading count) comes from the
  # ETS record rather than the file, because that is the state vigil knows.
  defp check_rewrite_shrink_threshold(path, content, confirm) do
    old_count = count_existing_headings(path)
    new_count = content |> split_lines() |> Enum.count(&Regex.match?(@heading_re, &1))
    removed = old_count - new_count

    if removed > 0 and (removed > div(old_count, 2) or removed > 20) do
      require_confirm(
        confirm,
        "removes #{removed} of #{old_count} headings from #{path}"
      )
    else
      :ok
    end
  end

  defp count_existing_headings(path) do
    case :ets.lookup(@files_table, path) do
      [{_, file}] ->
        file.chunk_ids
        |> Enum.map(fn cid -> :ets.lookup(@chunks_table, cid) end)
        |> Enum.count(fn
          [{_, rec}] -> rec.heading != nil
          [] -> false
        end)

      [] ->
        0
    end
  end

  ## delete_section

  defp do_delete_section(id, state) do
    case String.split(id, "#", parts: 2) do
      [path, _frag] ->
        with :ok <- basic_path_sanity(path),
             {:ok, abs_path} <- resolve_within_vault(state, path),
             [{_, rec}] <- {:ets.lookup(@chunks_table, id)} |> unwrap_lookup(),
             true <- rec.heading != nil do
          {:ok, original} = File.read(abs_path)
          orig_lines = split_lines(original)

          prefix = Enum.slice(orig_lines, 0, rec.heading_line - 1)

          suffix =
            Enum.slice(orig_lines, rec.body_end_line, length(orig_lines) - rec.body_end_line)

          new_lines = prefix ++ suffix
          new_content = Enum.join(new_lines, "\n") <> "\n"

          write_and_commit(state, path, abs_path, new_content, "delete_section: #{id}")
        else
          false -> {:error, "A section without a heading cannot be deleted: #{id}"}
          {:error, msg} -> {:error, msg}
          :not_found -> {:error, "Nicht gefunden: #{id}"}
        end

      [_path] ->
        {:error, "id must contain a fragment: path#heading-slug"}
    end
  end

  ## update_frontmatter

  defp do_update_frontmatter(params, state) do
    path = Map.fetch!(params, :path)
    type = Map.fetch!(params, :type)
    starts = Map.get(params, :starts)
    ends = Map.get(params, :ends)

    with {:ok, abs_path} <- resolve_within_vault(state, path),
         :ok <- basic_path_sanity(path),
         :ok <- ensure_exists(abs_path, path),
         {:ok, type_atom, starts_dt, ends_dt} <- validate_type_and_times(type, starts, ends) do
      {:ok, original} = File.read(abs_path)

      case split_frontmatter(original) do
        {:ok, _old_frontmatter, body} ->
          new_frontmatter = build_frontmatter(type_atom, starts_dt, ends_dt)
          new_content = normalize_trailing_newline(new_frontmatter <> body)
          write_and_commit(state, path, abs_path, new_content, "update_frontmatter: #{path}")

        {:error, msg} ->
          {:error, msg}
      end
    else
      {:error, msg} -> {:error, msg}
    end
  end

  ## delete

  defp do_delete_note(params, state) do
    path = Map.fetch!(params, :path)
    confirm = Map.get(params, :confirm, false)

    with :ok <- require_confirm(confirm, delete_confirm_description(path)),
         {:ok, abs_path} <- resolve_within_vault(state, path),
         :ok <- basic_path_sanity(path),
         :ok <- ensure_exists(abs_path, path) do
      case Git.remove_commit(state.vault_path, path, "delete: #{path}") do
        :ok ->
          case Git.push(state.vault_path, state.git_remote) do
            :ok ->
              remove_file_from_index(path)
              rebuild_links_index()
              {:ok, %{path: path, deleted: true, pushed: true}}

            {:error, out} ->
              {:error, "Deletion committed locally, but push failed: #{out}"}
          end

        {:error, out} ->
          {:error, "git rm/commit fehlgeschlagen: #{out}"}
      end
    else
      {:error, msg} -> {:error, msg}
    end
  end

  # The preview shown before confirm: true also names the incoming links, so
  # it is visible what will break after the deletion.
  defp delete_confirm_description(path) do
    case backlinks_for(path) do
      [] ->
        "permanently deletes #{path} from the vault"

      backlinks ->
        "permanently deletes #{path} from the vault (#{length(backlinks)} incoming references: #{Enum.join(backlinks, ", ")})"
    end
  end

  ## move_note

  defp do_move_note(params, state) do
    from = Map.fetch!(params, :from)
    to = Map.fetch!(params, :to)
    confirm = Map.get(params, :confirm, false)

    with :ok <- require_confirm(confirm, "verschiebt #{from} nach #{to}"),
         :ok <- basic_path_sanity(from),
         {:ok, normalized_from, _changed?} <- normalize_path_or_error(from),
         :ok <- basic_path_sanity(normalized_from),
         {:ok, from_abs} <- resolve_within_vault(state, normalized_from),
         :ok <- ensure_exists(from_abs, normalized_from) do
      do_move_note_to(state, normalized_from, from_abs, to)
    else
      {:error, msg} -> {:error, msg}
    end
  end

  defp do_move_note_to(state, normalized_from, from_abs, to) do
    {:ok, existing_content} = File.read(from_abs)
    backlinks_before = backlinks_for(normalized_from)

    with :ok <- basic_path_sanity(to),
         {:ok, normalized_to, _changed?} <- normalize_path_or_error(to),
         :ok <- basic_path_sanity(normalized_to),
         {:ok, domain} <- validate_write_path(normalized_to, state),
         :ok <- check_naming_convention(normalized_to, domain, state, existing_content),
         {:ok, to_abs} <- resolve_within_vault(state, normalized_to),
         :ok <- ensure_not_exists(to_abs, normalized_to) do
      commit_message = "move: #{normalized_from} -> #{normalized_to}"

      case Git.move_commit(state.vault_path, normalized_from, normalized_to, commit_message) do
        {:ok, commit_meta} ->
          case Git.push(state.vault_path, state.git_remote) do
            :ok ->
              reparse_moved_file(state, normalized_from, normalized_to, commit_meta)
              # Backlink report from :links_in — a diff of incoming
              # references before and after the move rather than an ad-hoc
              # scan. A source chunk that resolved before and no longer shows
              # up in the (rebuilt) incoming references of the target now
              # points nowhere — for example because it referenced an
              # explicit path instead of a basename.
              backlinks_after = backlinks_for(normalized_to)
              broken_backlinks = backlinks_before -- backlinks_after

              {:ok,
               %{
                 from: normalized_from,
                 to: normalized_to,
                 pushed: true,
                 broken_backlinks: broken_backlinks
               }}

            {:error, out} ->
              {:error, "Verschieben lokal committed, aber Push fehlgeschlagen: #{out}"}
          end

        {:error, out} ->
          {:error, "git mv/commit fehlgeschlagen: #{out}"}
      end
    else
      {:error, msg} -> {:error, msg}
    end
  end

  defp reparse_moved_file(state, from, to, commit_meta) do
    existing_created_at =
      case :ets.lookup(@files_table, from) do
        [{_, file}] -> file.created_at
        [] -> nil
      end

    created_at = existing_created_at || commit_meta.updated_at

    {:ok, content} = File.read(Path.join(state.vault_path, to))

    meta = %{
      created_at: created_at,
      updated_at: commit_meta.updated_at,
      last_author: commit_meta.last_author
    }

    {:ok, file} = Parser.parse(to, content, meta)

    remove_file_from_index(from)
    index_file(file)
    rebuild_links_index()
  end

  defp require_confirm(true, _description), do: :ok

  defp require_confirm(_confirm, description) do
    {:error,
     "Destructive operation: #{description}. Call again with confirm: true to execute it."}
  end

  defp split_frontmatter(content) do
    lines = split_lines(content)

    case lines do
      ["---" | rest] ->
        case Enum.find_index(rest, &(&1 == "---")) do
          nil ->
            {:error, "Unterminated frontmatter"}

          idx ->
            frontmatter_lines = Enum.take(rest, idx + 1)
            body_lines = Enum.drop(rest, idx + 1)
            frontmatter = Enum.join(["---" | frontmatter_lines], "\n") <> "\n"
            body = Enum.join(body_lines, "\n") <> "\n"
            {:ok, frontmatter, body}
        end

      _ ->
        {:error, "No frontmatter found"}
    end
  end

  ## shared write path

  defp write_and_commit(state, rel_path, abs_path, full_content, message) do
    with :ok <- safe_mkdir_p(Path.dirname(abs_path)),
         :ok <- safe_write(abs_path, full_content) do
      case Git.add_commit(state.vault_path, rel_path, message) do
        {:ok, commit_meta} ->
          reparse_file(state, rel_path, commit_meta)

          case Git.push(state.vault_path, state.git_remote) do
            :ok ->
              {:ok, %{path: rel_path, pushed: true}}

            {:error, out} ->
              {:error, "Change saved and committed locally, but push failed: #{out}"}
          end

        {:error, out} ->
          {:error, "git commit fehlgeschlagen: #{out}"}
      end
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

  defp reparse_file(state, rel_path, commit_meta) do
    existing_created_at =
      case :ets.lookup(@files_table, rel_path) do
        [{_, file}] -> file.created_at
        [] -> nil
      end

    created_at = existing_created_at || commit_meta.updated_at

    {:ok, content} = File.read(Path.join(state.vault_path, rel_path))

    meta = %{
      created_at: created_at,
      updated_at: commit_meta.updated_at,
      last_author: commit_meta.last_author
    }

    {:ok, file} = Parser.parse(rel_path, content, meta)

    remove_file_from_index(rel_path)
    index_file(file)
    rebuild_links_index()
  end

  # Removes chunks and files only. The link index is not maintained here but
  # rebuilt by the caller via rebuild_links_index/0 — necessary anyway, since
  # other notes may reference the one being removed.
  defp remove_file_from_index(rel_path) do
    case :ets.lookup(@files_table, rel_path) do
      [{_, file}] ->
        Enum.each(file.chunk_ids, fn cid -> :ets.delete(@chunks_table, cid) end)
        :ets.delete(@files_table, rel_path)

      [] ->
        :ok
    end
  end

  defp split_lines(content) do
    lines = String.split(content, "\n")

    case List.last(lines) do
      "" -> Enum.slice(lines, 0..-2//1)
      _ -> lines
    end
  end

  ## current()

  defp do_current(now) do
    events =
      :ets.tab2list(@files_table)
      |> Enum.map(fn {_path, file} -> file end)
      |> Enum.filter(&(&1.type == :event))

    active =
      events
      |> Enum.filter(fn e ->
        DateTime.compare(now, e.starts) != :lt and DateTime.compare(now, e.ends) != :gt
      end)
      |> Enum.sort_by(& &1.ends, DateTime)
      |> Enum.map(fn e ->
        %{id: e.path, title: e.title, ends_in: Vigil.TimeFmt.duration(DateTime.diff(e.ends, now))}
      end)

    upcoming_cutoff = DateTime.add(now, 30 * 86_400, :second)

    upcoming =
      events
      |> Enum.filter(fn e ->
        DateTime.compare(e.starts, now) == :gt and
          DateTime.compare(e.starts, upcoming_cutoff) != :gt
      end)
      |> Enum.sort_by(& &1.starts, DateTime)
      |> Enum.map(fn e ->
        %{
          id: e.path,
          title: e.title,
          starts_in: Vigil.TimeFmt.duration(DateTime.diff(e.starts, now))
        }
      end)

    past_cutoff = DateTime.add(now, -7 * 86_400, :second)

    recently_past =
      events
      |> Enum.filter(fn e ->
        DateTime.compare(e.ends, now) == :lt and DateTime.compare(e.ends, past_cutoff) != :lt
      end)
      |> Enum.sort_by(& &1.ends, {:desc, DateTime})
      |> Enum.map(fn e ->
        %{id: e.path, title: e.title, ended: Vigil.TimeFmt.ago(DateTime.diff(now, e.ends))}
      end)

    %{
      now: DateTime.to_iso8601(now),
      active: active,
      upcoming: upcoming,
      recently_past: recently_past
    }
  end

  defp do_near_summary(now) do
    events =
      :ets.tab2list(@files_table)
      |> Enum.map(fn {_path, file} -> file end)
      |> Enum.filter(&(&1.type == :event))

    active =
      events
      |> Enum.filter(fn e ->
        DateTime.compare(now, e.starts) != :lt and DateTime.compare(now, e.ends) != :gt
      end)
      |> Enum.sort_by(& &1.ends, DateTime)
      |> Enum.map(fn e ->
        %{id: e.path, title: e.title, ends_in: Vigil.TimeFmt.duration(DateTime.diff(e.ends, now))}
      end)

    horizon_cutoff = DateTime.add(now, 7 * 86_400, :second)

    upcoming =
      events
      |> Enum.filter(fn e ->
        DateTime.compare(e.starts, now) == :gt and
          DateTime.compare(e.starts, horizon_cutoff) != :gt
      end)
      |> Enum.sort_by(& &1.starts, DateTime)
      |> Enum.map(fn e ->
        %{
          id: e.path,
          title: e.title,
          starts_in: Vigil.TimeFmt.duration(DateTime.diff(e.starts, now))
        }
      end)

    %{active: active, upcoming: upcoming}
  end

  defp do_active_event_ids(now) do
    :ets.tab2list(@files_table)
    |> Enum.map(fn {_path, file} -> file end)
    |> Enum.filter(fn f ->
      f.type == :event and DateTime.compare(now, f.starts) != :lt and
        DateTime.compare(now, f.ends) != :gt
    end)
    |> Enum.map(& &1.path)
    |> MapSet.new()
  end

  ## Lint (AP-5)

  defp do_lint(now) do
    files = :ets.tab2list(@files_table) |> Enum.map(fn {_path, file} -> file end)
    chunks = :ets.tab2list(@chunks_table) |> Enum.map(fn {_id, rec} -> rec end)

    %{
      duplicate_headings: lint_duplicate_headings(chunks),
      sentence_headings: lint_sentence_headings(chunks),
      orphaned_links: lint_orphaned_links(),
      overlong_notes: lint_overlong_notes(files),
      stale_decisions: lint_stale_decisions(files, now)
    }
  end

  defp lint_duplicate_headings(chunks) do
    chunks
    |> Enum.filter(& &1.heading)
    |> Enum.group_by(&{&1.path, &1.heading_path})
    |> Enum.filter(fn {_key, group} -> length(group) > 1 end)
    |> Enum.map(fn {{path, heading_path}, group} ->
      %{path: path, heading_path: heading_path, ids: Enum.map(group, & &1.id)}
    end)
  end

  defp lint_sentence_headings(chunks) do
    chunks
    |> Enum.filter(fn c -> c.heading && sentence_heading?(c.heading) end)
    |> Enum.map(fn c -> %{id: c.id, heading: c.heading} end)
  end

  # Rough heuristic: a heading that reads like a sentence is either long or
  # ends in punctuation. Both are signals, not proof.
  defp sentence_heading?(heading) do
    String.length(heading) > @sentence_heading_length_threshold or
      String.ends_with?(heading, [".", "!", "?"])
  end

  defp lint_orphaned_links do
    @links_out_table
    |> :ets.tab2list()
    |> Enum.filter(fn {_source_id, resolved} -> resolved.status == :broken end)
    |> Enum.map(fn {_source_id, resolved} -> link_label(resolved) end)
    |> Enum.uniq()
  end

  defp lint_overlong_notes(files) do
    files
    |> Enum.filter(fn f -> length(f.chunk_ids) > @overlong_note_chunk_threshold end)
    |> Enum.map(fn f -> %{path: f.path, chunk_count: length(f.chunk_ids)} end)
  end

  defp lint_stale_decisions(files, now) do
    cutoff = DateTime.add(now, -@stale_decision_days * 86_400, :second)

    files
    |> Enum.filter(fn f ->
      f.type == :decision and f.updated_at != nil and
        DateTime.compare(f.updated_at, cutoff) == :lt
    end)
    |> Enum.map(fn f -> %{path: f.path, updated_at: iso(f.updated_at)} end)
  end

  ## Skills

  defp do_skill_list(state) do
    dir = Path.join(state.vault_path, "skills")

    if File.dir?(dir) do
      dir
      |> File.ls!()
      |> Enum.filter(&String.ends_with?(&1, ".md"))
      |> Enum.map(fn filename ->
        name = Path.basename(filename, ".md")
        description = skill_description(Path.join(dir, filename))
        %{name: name, description: description}
      end)
    else
      []
    end
  end

  defp skill_description(abs_path) do
    with {:ok, content} <- File.read(abs_path),
         ["---" | rest] <- String.split(content, "\n"),
         {:ok, idx} <- find_closing_line(rest),
         yaml_text = Enum.join(Enum.take(rest, idx), "\n"),
         {:ok, %{"description" => desc}} <- YamlElixir.read_from_string(yaml_text) do
      desc
    else
      _ -> nil
    end
  end

  defp find_closing_line(lines) do
    idx = Enum.find_index(lines, &(&1 == "---"))
    if idx, do: {:ok, idx}, else: :error
  end

  defp normalize_skill_name(name) do
    name
    |> String.trim()
    |> String.replace_suffix(".md", "")
  end

  defp valid_skill_name?(name), do: Regex.match?(~r/^[a-z0-9_-]+$/, name)

  defp do_skill_read(name, state) do
    normalized = normalize_skill_name(name)

    if valid_skill_name?(normalized) do
      abs_path = Path.join([state.vault_path, "skills", "#{normalized}.md"])

      case File.read(abs_path) do
        {:ok, content} ->
          token = SkillKey.current(SkillKey.secret())

          prefixed =
            "SkillKey: #{token} (valid until the next full hour)\n\n" <> content

          {:ok, %{name: normalized, content: prefixed}}

        {:error, _} ->
          # The key is a pure HMAC over secret + time and does not depend on
          # any skill existing, so it is handed out in the not-found case too.
          # Otherwise this deadlocks bootstrapping: skill_write itself
          # requires a SkillKey, but a fresh vault has no conventions skill to
          # read one from.
          names = do_skill_list(state) |> Enum.map(& &1.name) |> Enum.join(", ")
          token = SkillKey.current(SkillKey.secret())

          {:error,
           "Skill not found: #{normalized}. Available: #{names}. SkillKey: #{token} (valid until the next full hour)."}
      end
    else
      {:error, "Invalid path"}
    end
  end

  defp do_skill_write(name, content, state) do
    normalized = normalize_skill_name(name)

    with true <- valid_skill_name?(normalized),
         :ok <- validate_skill_frontmatter(content) do
      abs_path = Path.join([state.vault_path, "skills", "#{normalized}.md"])
      rel_path = "skills/#{normalized}.md"

      with :ok <- safe_mkdir_p(Path.dirname(abs_path)),
           :ok <- safe_write(abs_path, normalize_trailing_newline(content)) do
        case Git.add_commit(state.vault_path, rel_path, "skill_write: #{rel_path}") do
          {:ok, _commit_meta} ->
            case Git.push(state.vault_path, state.git_remote) do
              :ok ->
                {:ok, %{name: normalized, pushed: true}}

              {:error, out} ->
                {:error, "Skill lokal gespeichert, aber Push fehlgeschlagen: #{out}"}
            end

          {:error, out} ->
            {:error, "git commit fehlgeschlagen: #{out}"}
        end
      end
    else
      false -> {:error, "Invalid path"}
      {:error, msg} -> {:error, msg}
    end
  end

  defp validate_skill_frontmatter(content) do
    case String.split(content, "\n") do
      ["---" | rest] ->
        case find_closing_line(rest) do
          {:ok, idx} ->
            yaml_text = Enum.join(Enum.take(rest, idx), "\n")

            case YamlElixir.read_from_string(yaml_text) do
              {:ok, %{"name" => _, "description" => _}} -> :ok
              _ -> {:error, "Frontmatter must contain 'name' and 'description'"}
            end

          :error ->
            {:error, "Unterminated frontmatter"}
        end

      _ ->
        {:error, "content must start with frontmatter"}
    end
  end
end
