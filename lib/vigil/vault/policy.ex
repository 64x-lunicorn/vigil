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

  alias Vigil.{Index, Markdown, Slug}
  alias Vigil.Vault.{Decision, Facts, Frontmatter, Layout}

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

  # Which paths are notes is Vigil.Vault.Layout's question, and the same value
  # answers it for vault discovery — so what this gate lets in is what a load
  # takes back. What is left here is what to *say* about each answer, and the
  # one thing the layout does not decide: whether a missing project directory
  # is refused or created, which only `:create` may ask for.
  defp writable_path(path, facts, create_dirs) do
    case Layout.classify(facts.layout, path) do
      {:note, domain} ->
        {:ok, domain, nil}

      {:missing_project, domain, project} ->
        if create_dirs,
          do: {:ok, domain, project},
          else: {:error, "Invalid path. Project directory does not exist: #{project}"}

      {:unknown_domain, _domain} ->
        {:error, "Invalid path. Available domains: #{Enum.join(facts.layout.domains, ", ")}"}

      # A path under `skills/`, in an excluded domain, or shaped like nothing
      # this vault holds. All three are refused without naming anything: an
      # excluded domain must not be confirmed to exist by the wording of a
      # refusal (docs/design.md, "`VIGIL_EXCLUDE` is the hard boundary").
      _ ->
        @invalid_path
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
        naming_pattern(path, domain, naming, content, facts)
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
  #
  # Which is why the fence has to be closed. A block left open swallows every
  # line below the splice point — the whole rest of the note becomes part of
  # the sample, and every section under it loses its chunk id. That is a
  # larger blast than the split this gate exists to prevent, and only the
  # mid-note targets can suffer it: the other two append at the end of the
  # file, where there is nothing below to swallow.
  defp appended_content({:section, _chunk}, content) do
    with :ok <-
           refute_headings(
             content,
             "content appended to an existing section must not contain headings (## through ####): it would split the section in two"
           ) do
      refute_open_fence(content)
    end
  end

  defp appended_content(_target, _content), do: :ok

  defp refute_open_fence(content) do
    if Markdown.unclosed_fence?(content) do
      {:error,
       "content appended to an existing section must not leave a fenced block open: every line below it in the note would become part of the code sample"}
    else
      :ok
    end
  end

  defp refute_headings(content, message) do
    if Markdown.headings(content) == [] do
      :ok
    else
      {:error, message}
    end
  end

  # The frontmatter rule itself is `Vigil.Vault.Frontmatter`'s, so that the
  # write gate and the reader that indexes what it wrote cannot disagree about
  # what a valid note is. What stays here is the refusal: the sentence the
  # caller is handed back.
  defp type_and_times(request) do
    type = Map.fetch!(request, :type)
    starts = Map.get(request, :starts)
    ends = Map.get(request, :ends)

    case Frontmatter.check(type, starts, ends) do
      {:ok, %Frontmatter{type: type, starts: starts, ends: ends}} -> {:ok, type, starts, ends}
      {:error, problem} -> {:error, refusal(problem)}
    end
  end

  defp refusal(:type_missing), do: "Invalid type"
  defp refusal({:unknown_type, _value}), do: "Invalid type"
  defp refusal(:times_missing), do: "starts/ends are required for type: event"
  defp refusal(:times_not_allowed), do: "starts/ends are only allowed for type: event"

  defp refusal(:times_unparsable),
    do: "starts/ends must be valid ISO8601 timestamps with an offset"

  defp refusal(:ends_before_starts), do: "ends must not be before starts"

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
  #
  # The gate's sensitivity, stated here in one interface, in units a reader
  # can act on. It used to be spread across three modules that did not mention
  # each other: which terms were searched for (here), how deep each search
  # went (an uncommented `limit: 25` in `Vigil.Store`'s adapter) and what the
  # threshold meant (`Vigil.Index`'s search ranking, a bare `10` at the call
  # site).
  #
  # @term_floor — how long a `-`-separated segment of the note's name has to
  # be to be searched for on its own. A shorter one says too little: "gp"
  # matches every GPS note in the domain. The note's whole name is a term
  # regardless, so a name made only of short segments — home/weg.md,
  # gear/rad.md, training/ftp.md, all live shapes in a German vault — is still
  # asked about, and every unforced create asks the vault at least one
  # question. The gate is never decided before `Facts` is reached.
  #
  # @search_depth — how many hits per term the vault is asked for, best first.
  # Not a window over the domain: a note outside the best 25 for every one of
  # its terms is not similar enough to be a candidate.
  #
  # @names_the_note_score — how strong a hit has to be to count as a
  # candidate. Asked of `Vigil.Index` by name rather than repeated as an
  # integer here: the scale is the search ranking's, and so is the statement
  # of what reaching this score does and does not prove. That statement holds
  # for a search with no preferred type, which is what `find_similar` is — a
  # `prefer` hint would lift a weaker hit to the same score.
  @term_floor 4
  @search_depth 25
  @names_the_note_score Index.strength(:title)

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
    |> search_terms()
    |> Enum.flat_map(&facts.find_similar.(&1, domain, @search_depth))
    |> Enum.filter(&(&1.score >= @names_the_note_score))
    |> Enum.uniq_by(& &1.id)
    |> Enum.reject(&same_project_folder?(&1.id, path))
  end

  defp search_terms(basename) do
    segments =
      basename
      |> String.split("-")
      |> Enum.filter(&(String.length(&1) >= @term_floor))

    Enum.uniq([basename | segments])
  end

  # Which paths lie in a project folder is the layout's question, like every
  # other one about the shape of a path (docs/design.md, "Domains are
  # directories"): a note outside the nesting domain lies in no project, so
  # two of them are never in the same one.
  defp same_project_folder?(candidate_id, path) do
    project = candidate_id |> String.split("#") |> hd() |> Layout.project_of()

    project != nil and project == Layout.project_of(path)
  end
end
