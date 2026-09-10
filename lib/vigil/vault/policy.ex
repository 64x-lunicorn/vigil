defmodule Vigil.Vault.Policy do
  @moduledoc """
  Whether a write to the vault is allowed, and what it resolves to.

  One interface — `check/3` — behind which every rule about a write lives:
  path safety, path normalization, which domains are writable, naming
  conventions from `_domains.yml`, frontmatter and type rules, duplicate
  detection, and the confirm gates on destructive operations.

  Policy performs no effect and changes nothing. It asks the vault questions
  through `Vigil.Vault.Facts` — whether a path exists, what a note contains,
  which chunk an id resolves to — and where a decision authorises an effect it
  says so in its result rather than performing it. Asking never changes the
  vault.

  Every write path goes through here. That is the point: the rules used to be
  private to `Vigil.Store` and only two of the eight write paths applied them,
  so `append`, `rewrite_note`, `update_frontmatter` and `delete_note` could
  each reach into `skills/` and into excluded domains.
  """

  alias Vigil.{Markdown, Slug}
  alias Vigil.Vault.{Decision, Facts}

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

  Returns `{:ok, decision}` — one `Vigil.Vault.Decision` struct per write
  shape, carrying what the policy derived and the caller needs: the normalized
  path, the resolved target or chunk, parsed timestamps, a project directory
  to create. Or `{:error, message}`, with the message the caller is expected
  to hand back verbatim.
  """
  @spec check(op, map, Facts.t()) :: {:ok, Decision.t()} | {:error, String.t()}

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
       %Decision.Create{
         path: normalized,
         normalized_from: if(changed?, do: path),
         create_project_dir: create_dir,
         type: type,
         starts: starts,
         ends: ends
       }}
    end
  end

  def check(:append, request, facts) do
    content = Map.fetch!(request, :content)

    with {:ok, path} <- existing_note(Map.fetch!(request, :path), facts),
         {:ok, target} <- append_target(path, Map.get(request, :heading), facts),
         :ok <- appended_content(target, content) do
      {:ok, %Decision.Append{path: path, target: target}}
    end
  end

  def check(:rewrite_note, request, facts) do
    content = Map.fetch!(request, :content)

    with {:ok, path} <- existing_note(Map.fetch!(request, :path), facts),
         :ok <- content_shape(content),
         :ok <- shrink_threshold(path, content, confirm?(request), facts) do
      {:ok, %Decision.RewriteNote{path: path}}
    end
  end

  def check(:update_frontmatter, request, facts) do
    with {:ok, path} <- existing_note(Map.fetch!(request, :path), facts),
         {:ok, type, starts, ends} <- type_and_times(request) do
      {:ok, %Decision.UpdateFrontmatter{path: path, type: type, starts: starts, ends: ends}}
    end
  end

  # The confirm gate comes last, for the same reason the section ops check the
  # path first: a write the policy will refuse outright must be refused, not
  # quoted back in a confirmation prompt. `delete_note("skills/tdd.md",
  # confirm: false)` used to answer "permanently deletes skills/tdd.md" for a
  # path that is not deletable at all.
  def check(:delete_note, request, facts) do
    with {:ok, path} <- existing_note(Map.fetch!(request, :path), facts),
         backlinks = facts.find_backlinks.(path),
         :ok <- require_confirm(confirm?(request), delete_description(path, backlinks)) do
      {:ok, %Decision.DeleteNote{path: path, backlinks: backlinks}}
    end
  end

  # The section ops resolve through the index, not the filesystem: the chunk
  # record the index hands back is what says the section exists, and its
  # canonical path is the one the caller writes to. A section id is resolved
  # once, here.
  #
  # The order is load-bearing twice over. The path check on the id's own path
  # part comes first, so an id naming `skills/` or an excluded domain answers
  # "Invalid path" rather than "Not found". The chunk is then resolved before
  # the replacement content is judged, so a bad id is reported as a bad id
  # rather than as bad content.
  def check(:replace_section, request, facts) do
    id = Map.fetch!(request, :id)

    with :ok <- section_id_writable(id, facts),
         {:ok, chunk} <- section_chunk(id, facts, "replaced"),
         :ok <- replacement_content(Map.fetch!(request, :content)) do
      {:ok, %Decision.Section{path: chunk.path, chunk: chunk}}
    end
  end

  def check(:delete_section, request, facts) do
    id = Map.fetch!(request, :id)

    with :ok <- section_id_writable(id, facts),
         {:ok, chunk} <- section_chunk(id, facts, "deleted") do
      {:ok, %Decision.Section{path: chunk.path, chunk: chunk}}
    end
  end

  # Confirm last, as on `:delete_note`: a move to `skills/` or out of an
  # excluded domain answers "Invalid path" rather than quoting the path back
  # in a prompt for a write that will be refused on the next turn.
  def check(:move_note, request, facts) do
    from = Map.fetch!(request, :from)
    to = Map.fetch!(request, :to)

    with :ok <- path_sanity(from),
         {:ok, from_candidate, _changed?} <- normalize(from),
         {:ok, normalized_from} <- existing_note(from_candidate, facts),
         content = note_content(normalized_from, facts),
         :ok <- path_sanity(to),
         {:ok, normalized_to, _changed?} <- normalize(to),
         :ok <- path_sanity(normalized_to),
         {:ok, domain, _create_dir} <- writable_path(normalized_to, facts, false),
         :ok <- naming_convention(normalized_to, domain, content, facts),
         :ok <- refute_exists(normalized_to, facts),
         :ok <- require_confirm(confirm?(request), "moves #{from} to #{to}") do
      # No project directory to create: the move asks `writable_path/3` with
      # directory creation switched off, and `Vigil.Store` creates one for
      # `:create` alone.
      {:ok, %Decision.MoveNote{from: normalized_from, to: normalized_to}}
    end
  end

  ## Path safety

  # Owned by `Vigil.Slug`, alongside the normalization it is applied under —
  # the read paths ask the same function. Checked before normalization and
  # again after it: normalization must not be able to turn a rejected path
  # into an accepted one.
  defp path_sanity(path), do: Slug.safe_path(path)

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
      Slug.reserved_segment?(first) -> @invalid_path
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

  # The path the caller named must be a writable note before the id is looked
  # up at all — and it is judged on the normalized path, because that is the
  # path `find_chunk` resolves to. Judging the raw one would answer "Invalid
  # path" for an id `read` accepts, which is the asymmetry this seam exists to
  # close. Sanity is still checked before normalization as well as after
  # (`writable_note/2` re-checks it), so normalization cannot turn a rejected
  # path into an accepted one. Only the verdict is kept: the path the write
  # uses comes from the resolved record, never from here.
  defp section_id_writable(id, facts) do
    case String.split(id, "#", parts: 2) do
      [path, _fragment] ->
        with :ok <- path_sanity(path),
             {:ok, _path} <- writable_note(canonical_or_raw(path), facts) do
          :ok
        end

      [_path] ->
        {:error, "id must contain a fragment: path#heading-slug"}
    end
  end

  # A path no filename can be derived from stays as it is: the lookup will not
  # find it either, and "Not found" is what `read` answers for an id naming no
  # section.
  defp canonical_or_raw(path) do
    case Slug.normalize_path(path) do
      {:ok, normalized, _changed?} -> normalized
      {:error, _reason} -> path
    end
  end

  # Where an append lands: at the end of a section the note already has, in a
  # new section at the end of the file, or at the end of the file itself. Which
  # one it is decides what the file becomes, which makes it a policy question
  # and not the caller's.
  defp append_target(_path, nil, _facts), do: {:ok, :end}

  defp append_target(path, heading, facts) do
    case facts.find_section.(path, heading) do
      nil -> {:ok, {:new_section, heading}}
      chunk -> {:ok, {:section, chunk}}
    end
  end

  defp section_chunk(id, facts, verb) do
    case facts.find_chunk.(id) do
      nil -> {:error, "Not found: #{id}"}
      %{heading: nil} -> {:error, "A section without a heading cannot be #{verb}: #{id}"}
      chunk -> {:ok, chunk}
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
    refute_headings(content, "content must not contain headings (## through ####)")
  end

  # A heading spliced into the middle of an existing section splits that
  # section on the next parse, into two chunks one of which nobody asked for.
  # The other two targets append at the end of the file, where a heading opens
  # a section rather than cutting one in half, and are left alone.
  #
  # "Heading" means what the parser means by it: a `##` line inside a fenced
  # block splits nothing, and appending a code sample to an existing section
  # is an ordinary thing to want.
  defp appended_content({:section, _chunk}, content) do
    refute_headings(
      content,
      "content appended to an existing section must not contain headings (## through ####): it would split the section in two"
    )
  end

  defp appended_content(_target, _content), do: :ok

  defp refute_headings(content, message) do
    if Markdown.headings(content) == [] do
      :ok
    else
      {:error, message}
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

  defp delete_description(path, backlinks) do
    case backlinks do
      [] ->
        "permanently deletes #{path} from the vault"

      backlinks ->
        "permanently deletes #{path} from the vault (#{length(backlinks)} incoming references: #{Enum.join(backlinks, ", ")})"
    end
  end

  # confirm is only required when the new version removes more than half of
  # the existing sections OR more than 20 headings; below that rewrite_note
  # goes through without it. The baseline is what vigil has indexed for the
  # note the policy resolved, asked for here rather than handed in.
  #
  # Both sides count the same way: the index has no chunk for a heading inside
  # a fenced block, and `Markdown.count_headings/1` does not count one either.
  # Counting them on the way in would judge the new content against a baseline
  # it does not share.
  defp shrink_threshold(path, content, confirm, facts) do
    old_count = facts.count_headings.(path)
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
