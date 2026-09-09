defmodule Vigil.Vault.Policy do
  @moduledoc """
  Whether a write to the vault is allowed, and what it resolves to.

  One interface — `check/3` — behind which every rule about a write lives:
  path safety, path normalization, which domains are writable, naming
  conventions from `_domains.yml`, frontmatter and type rules, duplicate
  detection, and the confirm gates on destructive operations.

  The module is pure. It reads no file, touches no ETS table and consults no
  application configuration; `Vigil.Vault.Facts` carries everything it needs.
  Where a decision authorises an effect — creating a project directory — it
  says so in its result rather than performing it, so asking the question
  never changes the vault.

  Every write path goes through here. That is the point: the rules used to be
  private to `Vigil.Store` and only two of the eight write paths applied them,
  so `append`, `rewrite_note`, `update_frontmatter` and `delete_note` could
  each reach into `skills/` and into excluded domains.
  """

  alias Vigil.{Markdown, Slug}
  alias Vigil.Vault.Facts

  @type op ::
          :create
          | :append
          | :replace_section
          | :delete_section
          | :rewrite_note
          | :update_frontmatter
          | :delete_note
          | :move_note

  @invalid_path {:error, "Invalid path"}

  @doc """
  Decides `op` for `request` against `facts`.

  Returns `{:ok, resolved}` — a map of everything the caller needs that the
  policy derived (the normalized path, the domain, parsed timestamps, a
  project directory to create) — or `{:error, message}` with the message the
  caller is expected to hand back verbatim.
  """
  @spec check(op, map, Facts.t()) :: {:ok, map} | {:error, String.t()}

  def check(:create, request, facts) do
    path = Map.fetch!(request, :path)
    content = Map.fetch!(request, :content)

    with :ok <- path_sanity(path),
         {:ok, normalized, changed?} <- normalize(path),
         :ok <- path_sanity(normalized),
         {:ok, domain, create_dir} <- writable_path(normalized, facts, create_dirs?(request)),
         :ok <- naming_convention(normalized, domain, content, facts),
         :ok <- refute_exists(normalized, facts),
         :ok <- content_shape(content),
         {:ok, type, starts, ends} <- type_and_times(request),
         :ok <- duplicates(normalized, domain, request, facts) do
      {:ok,
       %{
         path: normalized,
         normalized_from: if(changed?, do: path),
         domain: domain,
         create_project_dir: create_dir,
         type: type,
         starts: starts,
         ends: ends
       }}
    end
  end

  def check(:append, request, facts) do
    with {:ok, path} <- existing_note(Map.fetch!(request, :path), facts) do
      {:ok, %{path: path}}
    end
  end

  def check(:rewrite_note, request, facts) do
    content = Map.fetch!(request, :content)

    with {:ok, path} <- existing_note(Map.fetch!(request, :path), facts),
         :ok <- content_shape(content),
         :ok <- shrink_threshold(path, content, confirm?(request), facts) do
      {:ok, %{path: path}}
    end
  end

  def check(:update_frontmatter, request, facts) do
    with {:ok, path} <- existing_note(Map.fetch!(request, :path), facts),
         {:ok, type, starts, ends} <- type_and_times(request) do
      {:ok, %{path: path, type: type, starts: starts, ends: ends}}
    end
  end

  def check(:delete_note, request, facts) do
    path = Map.fetch!(request, :path)

    with :ok <- require_confirm(confirm?(request), delete_description(path, facts)),
         {:ok, path} <- existing_note(path, facts) do
      {:ok, %{path: path}}
    end
  end

  # The section ops resolve through the index, not the filesystem: the chunk
  # record in `facts` is what says the section exists. The order below is
  # load-bearing — the chunk must be found before the replacement content is
  # judged, so a bad id is reported as a bad id rather than as bad content.
  def check(:replace_section, request, facts) do
    id = Map.fetch!(request, :id)

    with {:ok, path} <- section_path(id, facts),
         :ok <- section_present(id, facts, "replaced"),
         :ok <- replacement_content(Map.fetch!(request, :content)) do
      {:ok, %{path: path}}
    end
  end

  def check(:delete_section, request, facts) do
    id = Map.fetch!(request, :id)

    with {:ok, path} <- section_path(id, facts),
         :ok <- section_present(id, facts, "deleted") do
      {:ok, %{path: path}}
    end
  end

  def check(:move_note, request, facts) do
    from = Map.fetch!(request, :from)
    to = Map.fetch!(request, :to)

    with :ok <- require_confirm(confirm?(request), "moves #{from} to #{to}"),
         :ok <- path_sanity(from),
         {:ok, from_candidate, _changed?} <- normalize(from),
         {:ok, normalized_from} <- existing_note(from_candidate, facts),
         content = note_content(normalized_from, facts),
         :ok <- path_sanity(to),
         {:ok, normalized_to, _changed?} <- normalize(to),
         :ok <- path_sanity(normalized_to),
         {:ok, domain, create_dir} <- writable_path(normalized_to, facts, false),
         :ok <- naming_convention(normalized_to, domain, content, facts),
         :ok <- refute_exists(normalized_to, facts) do
      {:ok,
       %{
         from: normalized_from,
         to: normalized_to,
         domain: domain,
         create_project_dir: create_dir
       }}
    end
  end

  @doc """
  The path-safety rule on its own, for the read paths.

  `read` and `links` take an id from the caller and must reject traversal the
  same way a write does, but none of the other write rules apply to them: a
  reader may reach a note in a domain that is no longer writable.
  """
  @spec safe_path(String.t()) :: :ok | {:error, String.t()}
  def safe_path(path), do: path_sanity(path)

  ## Path safety

  # Rejected before normalization and again after it: normalization must not
  # be able to turn a rejected path into an accepted one.
  defp path_sanity(path) do
    cond do
      String.contains?(path, "..") -> @invalid_path
      String.starts_with?(path, "/") -> @invalid_path
      String.contains?(path, "\\") -> @invalid_path
      String.contains?(path, <<0>>) -> @invalid_path
      Enum.any?(String.split(path, "/"), &reserved_segment?/1) -> @invalid_path
      true -> :ok
    end
  end

  # A leading "." (hidden) or "_" (reserved, e.g. _domains.yml) is allowed in
  # no path segment.
  defp reserved_segment?(segment) do
    String.starts_with?(segment, ".") or String.starts_with?(segment, "_")
  end

  defp normalize(path) do
    case Slug.normalize_path(path) do
      {:ok, normalized, changed?} ->
        {:ok, normalized, changed?}

      {:error, _reason} ->
        {:error,
         "No valid filename can be derived from \"#{path}\". Use a name containing letters or digits."}
    end
  end

  ## Which paths are writable notes

  defp writable_path(path, facts, create_dirs) do
    parts = String.split(path, "/")
    first = hd(parts)
    last = List.last(parts)

    cond do
      not within_vault?(path, facts) -> @invalid_path
      not String.ends_with?(last, ".md") -> @invalid_path
      first == "skills" -> @invalid_path
      first in facts.exclude -> @invalid_path
      reserved_segment?(first) -> @invalid_path
      length(parts) == 2 -> domain_rules(first, parts, facts, create_dirs)
      length(parts) == 3 and first == "projects" -> domain_rules(first, parts, facts, create_dirs)
      true -> @invalid_path
    end
  end

  defp within_vault?(path, facts) do
    String.starts_with?(Path.expand(path, facts.vault_path), facts.vault_path <> "/")
  end

  defp domain_rules(domain, parts, facts, create_dirs) do
    cond do
      domain not in facts.domains ->
        {:error, "Invalid path. Available domains: #{Enum.join(facts.domains, ", ")}"}

      length(parts) < 3 ->
        {:ok, domain, nil}

      true ->
        project = Enum.at(parts, 1)

        cond do
          project in facts.project_dirs -> {:ok, domain, nil}
          create_dirs -> {:ok, domain, project}
          true -> {:error, "Invalid path. Project directory does not exist: #{project}"}
        end
    end
  end

  # The path must name a writable note. Says nothing about whether it is there.
  defp writable_note(path, facts) do
    with :ok <- path_sanity(path),
         {:ok, _domain, _create_dir} <- writable_path(path, facts, false) do
      {:ok, path}
    end
  end

  # ... and the note must be there.
  defp existing_note(path, facts) do
    with {:ok, path} <- writable_note(path, facts),
         :ok <- require_exists(path, facts) do
      {:ok, path}
    end
  end

  defp section_path(id, facts) do
    case String.split(id, "#", parts: 2) do
      [path, _fragment] -> writable_note(path, facts)
      [_path] -> {:error, "id must contain a fragment: path#heading-slug"}
    end
  end

  defp section_present(id, facts, verb) do
    case facts.chunk do
      nil -> {:error, "Not found: #{id}"}
      %{heading: nil} -> {:error, "A section without a heading cannot be #{verb}: #{id}"}
      _ -> :ok
    end
  end

  defp require_exists(path, facts) do
    if facts.path_exists?.(path), do: :ok, else: {:error, "File not found: #{path}"}
  end

  defp note_content(path, facts) do
    case facts.read_note.(path) do
      {:ok, content} -> content
      _ -> ""
    end
  end

  defp refute_exists(path, facts) do
    if facts.path_exists?.(path), do: {:error, "File already exists: #{path}"}, else: :ok
  end

  ## Naming conventions (AP9a §4 — Schicht 3, aus _domains.yml)

  defp naming_convention(path, domain, content, facts) do
    case Map.get(facts.naming, domain) do
      nil ->
        :ok

      naming ->
        with :ok <- naming_pattern(path, domain, naming, content, facts) do
          naming_max_depth(path, domain, naming)
        end
    end
  end

  defp naming_pattern(path, domain, naming, content, facts) do
    scope_string = naming_scope_string(path, domain, naming.scope)

    if Regex.match?(naming.pattern, scope_string) do
      :ok
    else
      {:error,
       "The name \"#{scope_string}\" does not match the schema for domain #{domain}.\n" <>
         "#{naming.hint}\nSuggestion: #{naming_suggestion(path, domain, naming, content, facts)}"}
    end
  end

  defp naming_max_depth(_path, _domain, %{max_depth: nil}), do: :ok

  defp naming_max_depth(path, domain, %{max_depth: max_depth}) do
    depth = path |> naming_scope_string(domain, :relpath) |> String.split("/") |> length()

    if depth <= max_depth do
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

  defp naming_suggestion(_path, domain, %{suggestion: :date}, _content, facts) do
    "#{domain}/#{Date.to_iso8601(facts.today)}.md"
  end

  defp naming_suggestion(path, _domain, %{suggestion: :slug}, content, _facts) do
    with h1 when is_binary(h1) <- Markdown.first_h1(content),
         {:ok, slug} <- Slug.slugify(h1) do
      "#{Path.dirname(path)}/#{slug}.md"
    else
      _ -> path
    end
  end

  ## Content and frontmatter

  defp content_shape(content) do
    cond do
      Markdown.starts_with_frontmatter?(content) ->
        {:error, "content must not contain its own frontmatter block"}

      not Markdown.starts_with_h1?(content) ->
        {:error, "content must start with an H1 (# Title)"}

      true ->
        :ok
    end
  end

  defp replacement_content(content) do
    if Enum.any?(Markdown.split_lines(content), &Markdown.heading?/1) do
      {:error, "content must not contain headings (## through ####)"}
    else
      :ok
    end
  end

  defp type_and_times(request) do
    type = Map.fetch!(request, :type)
    starts = Map.get(request, :starts)
    ends = Map.get(request, :ends)

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

  ## Destructive-operation gates

  defp confirm?(request), do: Map.get(request, :confirm, false) == true

  defp create_dirs?(request), do: Map.get(request, :create_dirs, false) == true

  defp require_confirm(true, _description), do: :ok

  defp require_confirm(_confirm, description) do
    {:error,
     "Destructive operation: #{description}. Call again with confirm: true to execute it."}
  end

  defp delete_description(path, facts) do
    case facts.backlinks do
      [] ->
        "permanently deletes #{path} from the vault"

      backlinks ->
        "permanently deletes #{path} from the vault (#{length(backlinks)} incoming references: #{Enum.join(backlinks, ", ")})"
    end
  end

  # confirm is only required when the new version removes more than half of
  # the existing sections OR more than 20 headings; below that rewrite_note
  # goes through without it. The baseline is facts.heading_count — what vigil
  # has indexed for the note (see Vigil.Index.heading_count/2).
  defp shrink_threshold(path, content, confirm, facts) do
    old_count = facts.heading_count
    removed = old_count - Markdown.count_headings(content)

    if removed > 0 and (removed > div(old_count, 2) or removed > 20) do
      require_confirm(confirm, "removes #{removed} of #{old_count} headings from #{path}")
    else
      :ok
    end
  end

  ## Duplicate detection

  defp duplicates(path, domain, request, facts) do
    if Map.get(request, :force, false) == true do
      :ok
    else
      case similar_notes(path, domain, facts) do
        [] ->
          :ok

        candidates ->
          ids = candidates |> Enum.map(& &1.id) |> Enum.join(", ")

          {:error,
           "Possible duplicates found: #{ids}. If this is the same topic, extend one of those with append/replace_section instead of creating a new note — or pass force: true for a deliberately separate note."}
      end
    end
  end

  defp similar_notes(path, domain, facts) do
    path
    |> Path.basename(".md")
    |> String.split("-")
    |> Enum.filter(&(String.length(&1) > 3))
    |> Enum.flat_map(&facts.find_similar.(&1, domain))
    |> Enum.filter(&(&1.score >= 10))
    |> Enum.uniq_by(& &1.id)
    |> Enum.reject(&same_project_folder?(&1.id, path, domain))
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
end
