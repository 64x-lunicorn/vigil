defmodule Vigil.Store do
  @moduledoc false
  use GenServer
  require Logger

  alias Vigil.{Parser, Git, Search, SkillKey}

  @chunks_table :vigil_chunks
  @files_table :vigil_files
  @links_table :vigil_links

  @heading_re ~r/^(\#{2,4})\s+(.+?)\s*$/

  @overlong_note_chunk_threshold 40
  @stale_decision_days 180
  @sentence_heading_length_threshold 60

  ## Public API

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def search(params), do: GenServer.call(__MODULE__, {:search, params})
  def read(id, backlinks?), do: GenServer.call(__MODULE__, {:read, id, backlinks?})
  def create(params), do: GenServer.call(__MODULE__, {:create, params})
  def append(params), do: GenServer.call(__MODULE__, {:append, params})

  def replace_section(id, content),
    do: GenServer.call(__MODULE__, {:replace_section, id, content})

  def rewrite_note(params), do: GenServer.call(__MODULE__, {:rewrite_note, params})
  def delete_section(id), do: GenServer.call(__MODULE__, {:delete_section, id})
  def update_frontmatter(params), do: GenServer.call(__MODULE__, {:update_frontmatter, params})
  def delete(params), do: GenServer.call(__MODULE__, {:delete, params})
  def move(params), do: GenServer.call(__MODULE__, {:move, params})
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
      raise "VIGIL_VAULT_PATH #{vault_path} ist kein Git-Repository oder existiert nicht"
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
    for {name, type} <- [{@chunks_table, :set}, {@files_table, :set}, {@links_table, :bag}] do
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

  def handle_call({:delete, params}, _from, state) do
    {:reply, do_delete(params, state), state}
  end

  def handle_call({:move, params}, _from, state) do
    {:reply, do_move(params, state), state}
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
    :ets.delete_all_objects(@links_table)

    domain_dirs = discover_domain_dirs(state.vault_path, state.exclude)

    warn_domain_mismatches(domain_dirs, domains_desc)

    files =
      domain_dirs
      |> Enum.flat_map(&list_domain_files(state.vault_path, &1))

    Enum.each(files, fn rel_path ->
      load_file(state.vault_path, rel_path, git_meta)
    end)

    note_count = :ets.info(@files_table, :size)
    chunk_count = :ets.info(@chunks_table, :size)

    Logger.info(
      "vigil: #{length(domain_dirs)} Domänen (#{Enum.join(domain_dirs, ", ")}), #{note_count} Notes, #{chunk_count} Chunks"
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
      Logger.warning("_domains.yml: Key '#{key}' hat keinen zugehörigen Ordner")
    end

    for dir <- domain_dirs, not Map.has_key?(domains_desc, dir) do
      Logger.warning("Domäne '#{dir}' hat keinen Eintrag in _domains.yml")
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
        Logger.warning("Kann #{rel_path} nicht lesen: #{inspect(reason)}")
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
        links: chunk.links,
        created_at: chunk.created_at,
        updated_at: chunk.updated_at
      }

      :ets.insert(@chunks_table, {chunk.id, record})

      Enum.each(chunk.links, fn target_slug ->
        :ets.insert(@links_table, {target_slug, chunk.id})
      end)
    end)
  end

  defp domain_of(path), do: path |> String.split("/") |> hd()

  defp load_domains_yml(vault_path) do
    path = Path.join(vault_path, "_domains.yml")

    if File.exists?(path) do
      case YamlElixir.read_from_file(path) do
        {:ok, map} when is_map(map) ->
          map

        {:error, reason} ->
          Logger.warning("_domains.yml unparsbar: #{inspect(reason)}")
          %{}
      end
    else
      Logger.warning("_domains.yml fehlt")
      %{}
    end
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

    Search.run(items, query, %{limit: limit, prefer: prefer})
  end

  ## Read

  defp do_read(id, backlinks?, state) do
    path_part = id |> String.split("#", parts: 2) |> hd()

    with :ok <- basic_path_sanity(path_part) do
      if String.contains?(id, "#") do
        case :ets.lookup(@chunks_table, id) do
          [{_, rec}] -> {:ok, chunk_result(rec, backlinks?)}
          [] -> {:error, "Nicht gefunden: #{id}"}
        end
      else
        case :ets.lookup(@files_table, id) do
          [{_, file}] -> {:ok, file_result(file, backlinks?, state)}
          [] -> {:error, "Nicht gefunden: #{id}"}
        end
      end
    else
      {:error, _} -> {:error, "Ungültiger Pfad"}
    end
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
      toc: toc
    }

    if backlinks? do
      Map.put(base, :backlinks, backlinks_for(file.path))
    else
      base
    end
  end

  defp backlinks_for(path) do
    slug = Parser.slug(Path.basename(path, ".md"))

    @links_table
    |> :ets.lookup(slug)
    |> Enum.map(fn {_target, source_id} -> source_id end)
    |> Enum.uniq()
  end

  defp iso(nil), do: nil
  defp iso(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  ## Path validation (section 5)

  defp basic_path_sanity(path) do
    cond do
      String.contains?(path, "..") ->
        {:error, "Ungültiger Pfad"}

      String.starts_with?(path, "/") ->
        {:error, "Ungültiger Pfad"}

      String.contains?(path, "\\") ->
        {:error, "Ungültiger Pfad"}

      String.contains?(path, <<0>>) ->
        {:error, "Ungültiger Pfad"}

      Enum.any?(String.split(path, "/"), &String.starts_with?(&1, ".")) ->
        {:error, "Ungültiger Pfad"}

      true ->
        :ok
    end
  end

  defp resolve_within_vault(state, path) do
    abs = Path.expand(path, state.vault_path)

    if String.starts_with?(abs, state.vault_path <> "/") do
      {:ok, abs}
    else
      {:error, "Ungültiger Pfad"}
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
          {:error, "Ungültiger Pfad"}

        first == "skills" ->
          {:error, "Ungültiger Pfad"}

        first in state.exclude ->
          {:error, "Ungültiger Pfad"}

        String.starts_with?(first, ".") or String.starts_with?(first, "_") ->
          {:error, "Ungültiger Pfad"}

        length(parts) == 2 ->
          validate_domain(first, parts, state, create_dirs)

        length(parts) == 3 and first == "projects" ->
          validate_domain(first, parts, state, create_dirs)

        true ->
          {:error, "Ungültiger Pfad"}
      end
    else
      {:error, msg} -> {:error, msg}
    end
  end

  defp validate_domain(first, parts, state, create_dirs) do
    domains = list_domain_names(state)

    if first not in domains do
      {:error, "Ungültiger Pfad. Vorhandene Domänen: #{Enum.join(domains, ", ")}"}
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
            {:error, "Ungültiger Pfad. Projektordner existiert nicht: #{Enum.at(parts, 1)}"}
        end
      else
        {:ok, first}
      end
    end
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

    with {:ok, domain} <- validate_write_path(path, state, create_dirs),
         {:ok, abs_path} <- resolve_within_vault(state, path),
         :ok <- ensure_not_exists(abs_path, path),
         :ok <- validate_content_shape(content),
         {:ok, type_atom, starts_dt, ends_dt} <- validate_type_and_times(type, starts, ends),
         :ok <- check_duplicates(path, domain, force, state) do
      frontmatter = build_frontmatter(type_atom, starts_dt, ends_dt)
      full_content = normalize_trailing_newline(frontmatter <> content)

      write_and_commit(
        state,
        path,
        abs_path,
        full_content,
        "create: #{path} — #{first_line(content)}"
      )
    else
      {:error, msg} -> {:error, msg}
    end
  end

  defp ensure_not_exists(abs_path, path) do
    if File.exists?(abs_path) do
      {:error, "Datei existiert bereits: #{path}"}
    else
      :ok
    end
  end

  defp validate_content_shape(content) do
    trimmed = String.trim_leading(content)

    cond do
      String.starts_with?(trimmed, "---") ->
        {:error, "content darf keinen eigenen Frontmatter-Block enthalten"}

      not Regex.match?(~r/^\#\s+.+/, trimmed) ->
        {:error, "content muss mit einer H1 (# Titel) beginnen"}

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
        {:error, "Ungültiger type"}

      type_atom == :event and (is_nil(starts) or is_nil(ends)) ->
        {:error, "starts/ends sind Pflicht bei type: event"}

      type_atom != :event and (not is_nil(starts) or not is_nil(ends)) ->
        {:error, "starts/ends sind nur bei type: event erlaubt"}

      type_atom == :event ->
        with {:ok, s, _} <- DateTime.from_iso8601(starts),
             {:ok, e, _} <- DateTime.from_iso8601(ends) do
          {:ok, type_atom, s, e}
        else
          _ -> {:error, "starts/ends müssen gültige ISO8601-Zeiten mit Offset sein"}
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
       "Mögliche Duplikate gefunden: #{ids}. Falls es dasselbe Thema ist, lieber dort mit append/replace_section ergänzen statt hier neu anzulegen — oder force: true für eine bewusst getrennte Note."}
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
    if File.exists?(abs_path), do: :ok, else: {:error, "Datei nicht gefunden: #{path}"}
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
          false -> {:error, "Kein Abschnitt ohne Überschrift kann ersetzt werden: #{id}"}
          {:error, msg} -> {:error, msg}
          :not_found -> {:error, "Nicht gefunden: #{id}"}
        end

      [_path] ->
        {:error, "id muss ein Fragment enthalten: pfad#heading-slug"}
    end
  end

  defp unwrap_lookup({[{_, _rec}] = list}), do: list
  defp unwrap_lookup({[]}), do: :not_found

  defp validate_replace_content(content) do
    lines = split_lines(content)

    if Enum.any?(lines, &Regex.match?(@heading_re, &1)) do
      {:error, "content darf keine Überschriften (## bis ####) enthalten"}
    else
      :ok
    end
  end

  ## rewrite_note

  defp do_rewrite_note(params, state) do
    path = Map.fetch!(params, :path)
    content = Map.fetch!(params, :content)
    confirm = Map.get(params, :confirm, false)

    with :ok <- require_confirm(confirm, "ersetzt den gesamten Inhalt von #{path}"),
         {:ok, abs_path} <- resolve_within_vault(state, path),
         :ok <- basic_path_sanity(path),
         :ok <- ensure_exists(abs_path, path),
         :ok <- validate_content_shape(content) do
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
          false -> {:error, "Kein Abschnitt ohne Überschrift kann gelöscht werden: #{id}"}
          {:error, msg} -> {:error, msg}
          :not_found -> {:error, "Nicht gefunden: #{id}"}
        end

      [_path] ->
        {:error, "id muss ein Fragment enthalten: pfad#heading-slug"}
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

  defp do_delete(params, state) do
    path = Map.fetch!(params, :path)
    confirm = Map.get(params, :confirm, false)

    with :ok <- require_confirm(confirm, "löscht #{path} unwiderruflich aus dem Vault"),
         {:ok, abs_path} <- resolve_within_vault(state, path),
         :ok <- basic_path_sanity(path),
         :ok <- ensure_exists(abs_path, path) do
      case Git.remove_commit(state.vault_path, path, "delete: #{path}") do
        :ok ->
          case Git.push(state.vault_path, state.git_remote) do
            :ok ->
              remove_file_from_index(path)
              {:ok, %{path: path, deleted: true}}

            {:error, out} ->
              {:error, "Löschung lokal committed, aber Push fehlgeschlagen: #{out}"}
          end

        {:error, out} ->
          {:error, "git rm/commit fehlgeschlagen: #{out}"}
      end
    else
      {:error, msg} -> {:error, msg}
    end
  end

  ## move / rename

  defp do_move(params, state) do
    from = Map.fetch!(params, :from)
    to = Map.fetch!(params, :to)
    confirm = Map.get(params, :confirm, false)

    with :ok <- require_confirm(confirm, "verschiebt #{from} nach #{to}"),
         {:ok, _domain} <- validate_write_path(to, state),
         :ok <- basic_path_sanity(from),
         {:ok, from_abs} <- resolve_within_vault(state, from),
         :ok <- ensure_exists(from_abs, from),
         {:ok, to_abs} <- resolve_within_vault(state, to),
         :ok <- ensure_not_exists(to_abs, to) do
      case Git.move_commit(state.vault_path, from, to, "move: #{from} -> #{to}") do
        {:ok, commit_meta} ->
          case Git.push(state.vault_path, state.git_remote) do
            :ok ->
              reparse_moved_file(state, from, to, commit_meta)
              {:ok, %{from: from, to: to}}

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
  end

  defp require_confirm(true, _description), do: :ok

  defp require_confirm(_confirm, description) do
    {:error,
     "Destruktive Operation: #{description}. Mit confirm: true erneut aufrufen, um sie auszuführen."}
  end

  defp split_frontmatter(content) do
    lines = split_lines(content)

    case lines do
      ["---" | rest] ->
        case Enum.find_index(rest, &(&1 == "---")) do
          nil ->
            {:error, "Frontmatter nicht geschlossen"}

          idx ->
            frontmatter_lines = Enum.take(rest, idx + 1)
            body_lines = Enum.drop(rest, idx + 1)
            frontmatter = Enum.join(["---" | frontmatter_lines], "\n") <> "\n"
            body = Enum.join(body_lines, "\n") <> "\n"
            {:ok, frontmatter, body}
        end

      _ ->
        {:error, "Kein Frontmatter gefunden"}
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
              {:ok, %{path: rel_path}}

            {:error, out} ->
              {:error,
               "Änderung lokal gespeichert und committed, aber Push fehlgeschlagen: #{out}"}
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
        {:error, "Verzeichnis konnte nicht angelegt werden #{path}: #{fs_error(reason)}"}
    end
  end

  defp safe_write(path, content) do
    case File.write(path, content) do
      :ok ->
        :ok

      {:error, reason} ->
        {:error, "Datei konnte nicht geschrieben werden #{path}: #{fs_error(reason)}"}
    end
  end

  defp fs_error(:eacces), do: "keine Schreibrechte"
  defp fs_error(:enospc), do: "kein Speicherplatz mehr"
  defp fs_error(:eisdir), do: "Zielpfad ist ein Verzeichnis"
  defp fs_error(:enotdir), do: "ein Teil des Pfads ist kein Verzeichnis"
  defp fs_error(:erofs), do: "Dateisystem ist schreibgeschützt"
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
  end

  defp remove_file_from_index(rel_path) do
    case :ets.lookup(@files_table, rel_path) do
      [{_, file}] ->
        Enum.each(file.chunk_ids, fn cid ->
          case :ets.lookup(@chunks_table, cid) do
            [{_, rec}] ->
              Enum.each(rec.links, fn target ->
                :ets.delete_object(@links_table, {target, cid})
              end)

            [] ->
              :ok
          end

          :ets.delete(@chunks_table, cid)
        end)

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

  # Grobe Heuristik: eine Überschrift, die wie ein Satz aussieht, ist entweder
  # lang oder endet auf Satzzeichen. Beides ist ein Signal, kein Beweis.
  defp sentence_heading?(heading) do
    String.length(heading) > @sentence_heading_length_threshold or
      String.ends_with?(heading, [".", "!", "?"])
  end

  defp lint_orphaned_links do
    known_slugs =
      :ets.tab2list(@files_table)
      |> Enum.map(fn {path, _file} -> Parser.slug(Path.basename(path, ".md")) end)
      |> MapSet.new()

    @links_table
    |> :ets.tab2list()
    |> Enum.map(fn {target_slug, _source_id} -> target_slug end)
    |> Enum.uniq()
    |> Enum.reject(&MapSet.member?(known_slugs, &1))
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
            "SkillKey: #{token} (gültig bis zur nächsten vollen Stunde)\n\n" <> content

          {:ok, %{name: normalized, content: prefixed}}

        {:error, _} ->
          names = do_skill_list(state) |> Enum.map(& &1.name) |> Enum.join(", ")
          {:error, "Skill nicht gefunden: #{normalized}. Vorhanden: #{names}"}
      end
    else
      {:error, "Ungültiger Pfad"}
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
                {:ok, %{name: normalized}}

              {:error, out} ->
                {:error, "Skill lokal gespeichert, aber Push fehlgeschlagen: #{out}"}
            end

          {:error, out} ->
            {:error, "git commit fehlgeschlagen: #{out}"}
        end
      end
    else
      false -> {:error, "Ungültiger Pfad"}
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
              _ -> {:error, "Frontmatter muss 'name' und 'description' enthalten"}
            end

          :error ->
            {:error, "Frontmatter nicht geschlossen"}
        end

      _ ->
        {:error, "content muss mit Frontmatter beginnen"}
    end
  end
end
