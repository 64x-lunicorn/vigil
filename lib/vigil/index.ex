defmodule Vigil.Index do
  @moduledoc """
  The note/chunk/link index as a pure value.

  A peer of `Vigil.Store`, `Vigil.Parser`, `Vigil.LinkIndex` and
  `Vigil.Events` — not a process, not ETS. `Vigil.Store` keeps exactly one
  of these in its `GenServer` state, so every read still serializes through
  the Store process; the "one writer, serialized reads" trade-off in
  `docs/design.md` is unchanged, the seam just moves inside the process.

  `build/1` takes the vault's parsed files (`Vigil.Parser.File_` structs) and
  returns an index. `put/2` and `remove/2` return a new index — the link
  index (`Vigil.LinkIndex`) is rebuilt in full on every call, as it was in
  `Vigil.Store`'s ETS tables (`docs/design.md`, "The link index").

  The chunks it holds are the parser's own `Vigil.Parser.Chunk` values, with
  `domain` and `file_title` denormalised onto each one as it is indexed.
  There is no index-side chunk struct: one chunk, one owner, so a field added
  to it is added once.

  `search/2` decides filtering, matching, scoring, previews and `hub` in one
  place — a search result's shape is decided once, here, rather than split
  with the ranking half of the decision behind a seam of its own. `strength/1`
  publishes the scoring scale for the one caller outside this module that
  reads it: `Vigil.Vault.Policy`'s duplicate gate.
  """

  alias Vigil.{Events, LinkIndex, Parser, Slug}
  alias Vigil.Parser.Chunk
  alias Vigil.Vault.Rules

  @stale_decision_days 180

  # The scoring scale `search/2` ranks with, defined once and read by both
  # `score/3` and `strength/1`.
  @title 10
  @heading 5
  @body_occurrence 1
  @body_occurrence_cap 5
  @preferred_type 5
  @preview_len 120

  # A word of a query, once folded: a run of letters and digits.
  @word ~r/[\p{L}\p{N}]+/u

  defmodule Note do
    @moduledoc "One vault note, as the index carries it."
    defstruct [
      :path,
      :domain,
      :title,
      :type,
      :starts,
      :ends,
      :created_at,
      :updated_at,
      :chunk_ids
    ]
  end

  # `invalid_utf8` is the paths the load skipped for not being UTF-8
  # (docs/design.md, "A note that is not UTF-8 is skipped") — no note, no
  # chunk, only a `lint` finding.
  defstruct notes: %{}, chunks: %{}, links_out: %{}, links_in: %{}, invalid_utf8: []

  @typedoc "The whole index as one value: the notes, their chunks, and the links between them."
  @type t :: %__MODULE__{}

  @doc """
  Builds an index from the vault's parsed files, and the paths of the notes the
  load skipped because they are not UTF-8.
  """
  def build(parsed_files, invalid_utf8 \\ []) do
    {notes, chunks} =
      Enum.reduce(parsed_files, {%{}, %{}}, fn file, {notes, chunks} ->
        {note, file_chunks} = index_file(file)
        {Map.put(notes, note.path, note), Map.merge(chunks, file_chunks)}
      end)

    rebuild_links(%__MODULE__{
      notes: notes,
      chunks: chunks,
      invalid_utf8: Enum.sort(invalid_utf8)
    })
  end

  @doc """
  Replaces one note's chunks with a freshly parsed file, then rebuilds the link
  index in full.

  Creation date = first commit (`docs/design.md`, principle 3), and a write is
  never a note's first commit — so a note the index already holds at that path
  keeps the `created_at` it has, and only a note the index has not seen takes
  the value the parsed file carries.
  """
  def put(index, parsed_file) do
    index
    |> replace(parsed_file.path, parsed_file)
    |> rebuild_links()
  end

  @doc """
  Moves a note: the file parsed at its destination replaces the note at `from`,
  which is removed.

  A move needs its own entry point because the carry-over crosses paths — the
  old note is at the source and the new one at the destination — so `put/2`'s
  same-path rule cannot see it. Removal and carry-over belong to one function
  for that reason.
  """
  def move(index, from, parsed_file) do
    index
    |> replace(from, parsed_file)
    |> drop_source(from, parsed_file.path)
    |> rebuild_links()
  end

  @doc "Removes a note and its chunks, then rebuilds the link index in full."
  def remove(index, path) do
    index
    |> drop(path)
    |> rebuild_links()
  end

  # Puts `parsed_file` at its own path, carrying `created_at` over from
  # whatever the index holds at `previous_path` — the same path for a write,
  # the source path for a move.
  defp replace(index, previous_path, parsed_file) do
    {note, file_chunks} =
      parsed_file
      |> index_file()
      |> carry_created_at(index, previous_path)

    notes = Map.put(index.notes, note.path, note)
    chunks = index.chunks |> Map.drop(old_chunk_ids(index, note.path)) |> Map.merge(file_chunks)

    %{index | notes: notes, chunks: chunks}
  end

  # The date a note was created is a fact about the vault's history, not about
  # the write in front of us: the commit metadata a write carries describes
  # that write. So a `created_at` the index already holds always wins.
  defp carry_created_at({note, chunks}, index, previous_path) do
    case Map.get(index.notes, previous_path) do
      %Note{created_at: %DateTime{} = created_at} ->
        {%{note | created_at: created_at},
         Map.new(chunks, fn {id, chunk} -> {id, %{chunk | created_at: created_at}} end)}

      _ ->
        {note, chunks}
    end
  end

  # A move onto the note's own path is a no-op move, not a delete: dropping the
  # source after the replace would take the note just put there. The write
  # policy refuses such a move before it gets here, and this function does not
  # rely on that.
  defp drop_source(index, path, path), do: index
  defp drop_source(index, from, _to), do: drop(index, from)

  # A note the load skipped is only a path here, and deleting it is how it
  # leaves `lint`'s findings before the next load.
  defp drop(index, path) do
    %{
      index
      | notes: Map.delete(index.notes, path),
        chunks: Map.drop(index.chunks, old_chunk_ids(index, path)),
        invalid_utf8: List.delete(index.invalid_utf8, path)
    }
  end

  defp old_chunk_ids(index, path) do
    case Map.fetch(index.notes, path) do
      {:ok, note} -> note.chunk_ids
      :error -> []
    end
  end

  @doc "The `Note` at `path`, or `nil`."
  def note(index, path), do: Map.get(index.notes, path)

  @doc "`%{notes:, chunks:}` counts, for the load log line."
  def size(index), do: %{notes: map_size(index.notes), chunks: map_size(index.chunks)}

  @doc "Incoming references to `key` (a note path or a full chunk id) — the write path's backlinks question."
  def backlinks(index, key), do: backlinks_for(index, key)

  @doc """
  The links a move of `from` to `to` has to rewrite for every link to the
  note to keep leading to it: `%{source_path => %{raw => new_raw}}`, keyed by
  the linking note's path before the move — `from` itself for a note that
  links to itself.

  Only links that resolve to `from` now and would not resolve to `to` after
  the move are named, so a basename link that still finds the note is left as
  it was written. The new target keeps the link's style where that still
  leads to `to` from where the linking note will stand: a basename stays a
  basename unless the cascade would pick another note or none, and then it
  becomes the vault-relative path, which cannot be ambiguous. A path keeps a
  `.md` it was written with.
  """
  @spec relinks(t(), String.t(), String.t()) :: %{String.t() => %{String.t() => String.t()}}
  def relinks(index, from, to) do
    resolve = LinkIndex.resolver(files_after_move(index, from, to))

    index
    |> backlinks_for(from)
    |> Enum.group_by(&Map.fetch!(index.chunks, &1).path)
    |> Enum.map(fn {source_path, chunk_ids} ->
      source_after = if source_path == from, do: to, else: source_path

      rewrites =
        for chunk_id <- chunk_ids,
            %{status: :ok, target_note: ^from, raw: raw} <-
              Map.get(index.links_out, chunk_id, []),
            new_raw = retarget(raw, source_after, to, resolve),
            new_raw != nil,
            into: %{},
            do: {raw, new_raw}

      {source_path, rewrites}
    end)
    |> Enum.reject(fn {_source_path, rewrites} -> rewrites == %{} end)
    |> Map.new()
  end

  defp files_after_move(index, from, to) do
    moved = %{path: to, domain: domain_of(to)}

    index.notes
    |> Map.delete(from)
    |> Map.values()
    |> Enum.map(&%{path: &1.path, domain: &1.domain})
    |> then(&[moved | &1])
  end

  defp retarget(raw, source_after, to, resolve) do
    basename = Path.basename(to, ".md")

    cond do
      resolve.(raw, source_after) == {:ok, to} -> nil
      not String.contains?(raw, "/") and resolve.(basename, source_after) == {:ok, to} -> basename
      String.ends_with?(raw, ".md") -> to
      true -> Path.rootname(to, ".md")
    end
  end

  @doc """
  Every link from another note into one of `path`'s sections:
  `[%{from: source_chunk_id, to: chunk_id}]`. The note's own links into
  itself are not counted, and neither are links to the note as a whole —
  those survive anything but a delete or a move. What `rewrite_note` asks
  before it writes, to report the ones it broke.
  """
  @spec inbound_chunk_links(t(), String.t()) :: [%{from: String.t(), to: String.t()}]
  def inbound_chunk_links(index, path) do
    case note(index, path) do
      nil ->
        []

      note ->
        for chunk_id <- note.chunk_ids,
            chunk_id != path,
            source <- backlinks_for(index, chunk_id),
            Map.fetch!(index.chunks, source).path != path,
            do: %{from: source, to: chunk_id}
    end
  end

  @doc """
  The chunk a section id resolves to, or `nil` — through `resolve/2`, the same
  function `read/2` and `links/2` go through, so an id that reads is an id
  that writes by construction rather than by two walks agreeing. The record
  carries the canonical path, which is what makes leniency safe: the write
  goes where the lookup landed, not where the id pointed.

  `nil` covers all three ways an id fails to name a chunk — a path that is not
  safe to resolve, a chunk that is not there, and an id with no fragment,
  which names a note rather than a section. The write gate has already refused
  the first before it asks (`Vigil.Vault.Policy` judges what may be written
  before it resolves what is there), so collapsing them here loses no wording.

  One of the three questions only the index can answer for the write gate;
  `replace_section` and `delete_section` resolve their id with it.
  """
  def find_chunk(index, id) do
    case resolve(index, id) do
      {:ok, :chunk, chunk} -> chunk
      _ -> nil
    end
  end

  @doc """
  How many of `path`'s chunks carry a heading — the `rewrite_note` shrink
  gate's baseline. `0` for a path the index does not know, which is the
  permissive answer that switches the gate off.
  """
  def count_headings(index, path) do
    case Map.get(index.notes, path) do
      nil -> 0
      note -> Enum.count(note.chunk_ids, &heading_chunk?(index, &1))
    end
  end

  defp heading_chunk?(index, chunk_id) do
    case Map.get(index.chunks, chunk_id) do
      nil -> false
      chunk -> chunk.heading != nil
    end
  end

  @doc """
  The chunk in `path` whose heading slugifies the same as `heading`, or `nil` —
  `append`'s existing-section lookup. Both sides are slugged here so the caller
  never has to know how a heading becomes an id.
  """
  def find_section(index, path, heading) do
    target_slug = Parser.slug(heading)

    case Map.get(index.notes, path) do
      nil ->
        nil

      note ->
        note.chunk_ids
        |> Enum.map(&Map.get(index.chunks, &1))
        |> Enum.find(fn chunk ->
          chunk && chunk.heading && Parser.slug(chunk.heading) == target_slug
        end)
    end
  end

  @doc """
  What `kind` is worth on the scoring scale `search/2` ranks with.

    * `:title` — the query appears in the note's title.
    * `:heading` — it appears in a heading on the way to the chunk.
    * `:body_occurrence` — it appears once in the body.
    * `:body_occurrences_max` — the most the body can contribute, however
      often the query occurs in it.
    * `:preferred_type` — the chunk has the type the caller preferred.

  The whole scale is published, not only the one number a caller compares
  against: what a threshold means is a claim about how the parts add up, and
  neither a caller nor a test can check that claim unless the parts are named.

  `strength(:title)` is the lowest score meaning *the query names this note*
  rather than merely appearing in it — for a search with no preferred type. A
  title hit reaches it alone; the only other way to it is a heading hit with
  the body at its maximum. A `prefer` hint adds a second axis and the reading
  no longer holds: `:preferred_type` lifts a heading hit or a body at its
  maximum to the same score, and a chunk of the preferred type scores above
  zero without matching the query anywhere. `Vigil.Vault.Policy`'s duplicate
  gate is asked without a preference, which is what makes the reading it
  relies on true.

  A words hit is scored on the same scale, one word at a time, and scores its
  weakest word: it reaches `strength(:title)` only when every word of the
  query does — each one names the note, if the phrase does not.
  """
  @spec strength(atom) :: pos_integer
  def strength(:title), do: @title
  def strength(:heading), do: @heading
  def strength(:body_occurrence), do: @body_occurrence
  def strength(:body_occurrences_max), do: @body_occurrence * @body_occurrence_cap
  def strength(:preferred_type), do: @preferred_type

  @doc """
  Answers the `search` tool: the domain and type filters apply before
  matching, `journal/` is hidden unless asked for by name, and `hub` is
  attached when exactly one other note links to the hit's note.

  The query is trimmed and folded (`Vigil.Slug.fold/1`) as every chunk's
  title, headings and body were when it was indexed. A chunk that holds the
  folded query as a phrase is a *phrase hit*, scored on the additive scale
  `strength/1` publishes. A chunk that does not, but holds every one of the
  query's words somewhere in its title, headings or body, is a *words hit*:
  each word is scored on the same scale as if it were the query, and the hit
  scores what its weakest word scores. Every phrase hit ranks above every
  words hit; within each, the higher score first, then the more recently
  updated chunk, then the lower id — so the order is the same on every call.

  `opts` inside `params`: `:prefer`, `:cursor`, and `:limit`, which is
  required. The bound on `limit` is declared in `Vigil.MCP.Tools`' table and
  refused there; a limit that arrives here has already been validated against
  it, so this function takes the caller at its word rather than silently
  returning fewer hits than asked for.

  Answers `{:ok, %{results:, next_cursor:}}`: `next_cursor` is `nil` on the
  last page, and handed back as `:cursor` it answers the page after. A cursor
  that does not match the call is `{:error, message}` (see "Paging" below).
  """
  def search(index, params) do
    query = Map.fetch!(params, :query)
    domain = Map.get(params, :domain)
    type_filter = Map.get(params, :type)
    prefer = Map.get(params, :prefer)

    ranked =
      index.chunks
      |> Map.values()
      |> Enum.filter(&(visible?(&1.domain, domain) and of_type?(&1, type_filter)))
      |> rank(query, prefer)

    with {:ok, hits, next_cursor} <- page(ranked, :search, params) do
      results =
        Enum.map(hits, fn {score, chunk} ->
          attach_hub(index, to_search_result(chunk, score))
        end)

      {:ok, %{results: results, next_cursor: next_cursor}}
    end
  end

  # The one rule for what a read that enumerates shows by default: `journal/`
  # only when it is the domain asked for (docs/design.md, "Search"). `search`
  # and `list` both ask it.
  defp visible?(item_domain, nil), do: item_domain != "journal"
  defp visible?(item_domain, domain), do: item_domain == domain

  defp of_type?(_item, nil), do: true
  defp of_type?(item, type), do: item.type == type

  # Every hit, sorted, each beside the key it was sorted on — the key is what
  # a page's cursor is checked against (page/3).
  defp rank(chunks, query, prefer) do
    phrase = query |> String.trim() |> Slug.fold()
    words = query_words(phrase)

    chunks
    |> Enum.map(&{match(&1, phrase, words, prefer), &1})
    |> Enum.filter(fn {{_group, score}, _} -> score > 0 end)
    |> Enum.map(fn {{group, score}, chunk} ->
      {{group, -score, negated_time(chunk.updated_at), chunk.id}, {score, chunk}}
    end)
    |> Enum.sort_by(&elem(&1, 0))
  end

  @doc """
  Answers the `list` tool: a card per note — `id` (its path), `title`, `type`,
  `updated_at` — never a body, with the same `journal/` rule `search/2`
  follows. `domain` and `type` filter; `sort` is `:updated` (most recently
  updated first, a note git knows no date for last) or `:title` (folded as
  search folds, so case and accents do not split the order). Ties break on the
  path, so the order is the same on every call.

  `params` carries `:sort` and `:limit`, both required and both supplied by
  `Vigil.MCP.Tools`' table, and an optional `:cursor` from the page before.
  Answers `{:ok, %{notes:, next_cursor:}}`, or `{:error, message}` for a
  cursor that does not match the call (see "Paging" below).
  """
  def list(index, params) do
    domain = Map.get(params, :domain)
    type = Map.get(params, :type)
    sort = Map.fetch!(params, :sort)

    sorted =
      index.notes
      |> Map.values()
      |> Enum.filter(&(visible?(&1.domain, domain) and of_type?(&1, type)))
      |> Enum.map(&{list_key(&1, sort), &1})
      |> Enum.sort_by(&elem(&1, 0))

    with {:ok, notes, next_cursor} <- page(sorted, :list, params) do
      {:ok, %{notes: Enum.map(notes, &card/1), next_cursor: next_cursor}}
    end
  end

  defp list_key(note, :updated), do: {negated_time(note.updated_at), note.path}
  defp list_key(note, :title), do: {Slug.fold(note.title || ""), note.path}

  defp card(note) do
    %{id: note.path, title: note.title, type: note.type, updated_at: iso(note.updated_at)}
  end

  ## Paging
  #
  # docs/design.md, "Reads that enumerate are paged". A cursor is an offset
  # into the whole ordered answer, together with a fingerprint of that answer:
  # the call it came from (the operation and every parameter but `limit` and
  # `cursor`) and the sort key of every item, in order. While nothing is
  # written the same call orders the same items the same way, so the
  # fingerprint matches and the offset lands where the last page ended. A
  # write that changes what the call would answer, or in what order, changes
  # the fingerprint, and the cursor is refused rather than continued at an
  # offset that no longer means what it meant — a note skipped or shown twice
  # without a word is the thing paging must not do. A write elsewhere leaves
  # the cursor valid.
  #
  # Opaque to the caller, short whatever the ids are, and nothing in it is
  # trusted beyond two bounded integers.
  @fingerprint_range 4_294_967_296

  defp page(sorted, op, params) do
    limit = Map.fetch!(params, :limit)
    call = Map.drop(params, [:limit, :cursor])
    fingerprint = :erlang.phash2({op, call, Enum.map(sorted, &elem(&1, 0))}, @fingerprint_range)

    with {:ok, offset} <- cursor_offset(Map.get(params, :cursor), fingerprint, op) do
      items = sorted |> Enum.drop(offset) |> Enum.take(limit) |> Enum.map(&elem(&1, 1))
      next = offset + limit
      next_cursor = if next < length(sorted), do: encode_cursor(next, fingerprint)

      {:ok, items, next_cursor}
    end
  end

  defp cursor_offset(nil, _fingerprint, _op), do: {:ok, 0}

  defp cursor_offset(cursor, fingerprint, op) do
    case decode_cursor(cursor) do
      {:ok, offset, ^fingerprint} ->
        {:ok, offset}

      {:ok, _offset, _other} ->
        {:error,
         "The cursor no longer matches: the vault changed since it was issued, " <>
           "or #{op} was called with other parameters. Call #{op} again without a cursor."}

      :error ->
        {:error, "Invalid cursor: pass next_cursor from the previous page unchanged."}
    end
  end

  defp encode_cursor(offset, fingerprint),
    do: Base.url_encode64("#{offset}.#{fingerprint}", padding: false)

  defp decode_cursor(cursor) do
    with {:ok, raw} <- Base.url_decode64(cursor, padding: false),
         [_, offset, fingerprint] <- Regex.run(~r/\A(\d{1,9})\.(\d{1,10})\z/, raw) do
      {:ok, String.to_integer(offset), String.to_integer(fingerprint)}
    else
      _ -> :error
    end
  end

  # The words of a folded query: its runs of letters and digits, each once,
  # of two characters or more. A one-letter word (`C#`, `Plan B`) is in
  # nearly every chunk, inside longer words too, so as a word it narrows
  # nothing and caps a hit's score at a handful of stray letters; it stays in
  # the phrase. A query that is one word and nothing else has no words beyond
  # its phrase, and is not matched a second time.
  defp query_words(phrase) do
    words =
      @word
      |> Regex.scan(phrase)
      |> List.flatten()
      |> Enum.filter(&(String.length(&1) >= 2))
      |> Enum.uniq()

    case words do
      [^phrase] -> []
      words -> words
    end
  end

  defp negated_time(nil), do: 0
  defp negated_time(%DateTime{} = dt), do: -DateTime.to_unix(dt)

  # `{group, score}`: group 0 is a phrase hit, group 1 everything else, so a
  # phrase hit sorts first whatever the scores.
  defp match(_chunk, "", _words, _prefer), do: {1, 0}

  defp match(chunk, phrase, words, prefer) do
    preferred = if prefer && chunk.type == prefer, do: @preferred_type, else: 0

    case occurrence_score(chunk.folded, phrase) do
      0 -> {1, words_score(chunk.folded, words) + preferred}
      score -> {0, score + preferred}
    end
  end

  # A words hit is only as strong as the weakest of the words it must hold;
  # a word it does not hold at all scores 0, and so does the hit.
  defp words_score(_folded, []), do: 0

  defp words_score(folded, words) do
    words |> Enum.map(&occurrence_score(folded, &1)) |> Enum.min()
  end

  defp occurrence_score(folded, needle) do
    title_hit? = String.contains?(folded.title, needle)
    heading_hit? = Enum.any?(folded.headings, &String.contains?(&1, needle))
    body_hits = count_occurrences(folded.body, needle)

    score = 0
    score = if title_hit?, do: score + @title, else: score
    score = if heading_hit?, do: score + @heading, else: score
    score + @body_occurrence * min(body_hits, @body_occurrence_cap)
  end

  defp count_occurrences(haystack, needle) do
    case :binary.matches(haystack, needle) do
      :nomatch -> 0
      matches -> length(matches)
    end
  end

  defp to_search_result(chunk, score) do
    %{
      id: chunk.id,
      title: search_display_title(chunk),
      type: chunk.type,
      score: score,
      preview: search_preview(chunk.body)
    }
  end

  defp search_display_title(%{file_title: title, heading_path: path}) do
    Enum.join([title | path], " › ")
  end

  defp search_preview(body, limit \\ @preview_len) do
    text =
      body
      |> String.replace(~r/\r?\n/, " ")
      |> String.replace(~r/[#*_\[\]]/, "")
      |> String.replace(~r/\s+/, " ")
      |> String.trim()

    if String.length(text) <= limit do
      text
    else
      truncate_at_word(text, limit) <> "…"
    end
  end

  defp truncate_at_word(text, limit) do
    truncated = String.slice(text, 0, limit)

    case :binary.matches(truncated, " ") do
      [] ->
        truncated

      matches ->
        {pos, _len} = List.last(matches)
        String.slice(truncated, 0, pos)
    end
  end

  # The hub of a note, when exactly one other note links to it. Linked from
  # several notes means the hub is ambiguous, and the field is omitted rather
  # than guessed.
  defp attach_hub(index, result) do
    note_path = result.id |> String.split("#", parts: 2) |> hd()

    source_notes =
      index
      |> backlinks_for(note_path)
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

  @doc """
  A fragment id returns the chunk (with backlinks when asked). A bare path
  returns the note's `body` (the text before its first `##`, its preamble),
  its table of contents, its `links` out/in/broken counters
  and, when asked, its backlinks. Which of the two an id names, and whether it
  names anything at all, is `resolve/2`'s answer; what is left here is the
  rendering of it — a path that fails the safety check answers "Invalid path",
  anything else "Not found".

  `params` is the `read` tool's own parameter map: `:id` and `:backlinks`,
  under the names `Vigil.MCP.Tools`' table gives them.
  """
  def read(index, %{id: id, backlinks: backlinks?}) do
    case resolve(index, id) do
      {:ok, :chunk, chunk} -> {:ok, chunk_result(index, chunk, backlinks?)}
      {:ok, :note, note} -> {:ok, note_result(index, note, backlinks?)}
      :not_found -> {:error, "Not found: #{id}"}
      :unsafe_path -> {:error, "Invalid path"}
    end
  end

  # What an id resolves to, asked once for every reader that has to turn one
  # into a record: an id with a fragment is a chunk, a bare path is a note, and
  # both are answered leniently — an exact miss is retried once through path
  # normalization, and the record that comes back carries the canonical stored
  # id, which is what makes the leniency safe.
  #
  # Four verdicts, and the two failures are kept apart rather than collapsed
  # into one: `:unsafe_path` is a path that must not be quoted back at the
  # caller, `:not_found` is a miss that must. What a reader builds on a verdict
  # stays its own — `read` renders the record, `links` walks out from it — but
  # the walk that reaches the verdict is stated here alone. It was stated
  # twice, identically, apart from what each built on success; `find_chunk/2`
  # is the third, and goes through this too, which is what makes its claim
  # about the write path true rather than agreed.
  #
  # Safety and the canonical form come back together, from `Vigil.Slug`: the
  # order they have to be applied in is that module's to hold, not something
  # restated at each place that needs a path the vault might store.
  defp resolve(index, id) do
    path_part = id |> String.split("#", parts: 2) |> hd()

    case Slug.canonical_path(path_part) do
      {:error, _} ->
        :unsafe_path

      {:ok, canonical_path} ->
        if String.contains?(id, "#") do
          with {:ok, chunk} <- lookup_chunk(index, id, canonical_path),
               do: {:ok, :chunk, chunk}
        else
          with {:ok, note} <- lookup_note(index, id, canonical_path), do: {:ok, :note, note}
        end
    end
  end

  # The exact id first, so a note whose filename the vault stores unslugified
  # is still found under the name it has. Only when that misses is the
  # canonical form tried — the record that comes back carries the stored
  # id/path anyway, which is what makes the leniency safe.
  defp lookup_chunk(index, exact_id, canonical_path) do
    case Map.fetch(index.chunks, exact_id) do
      {:ok, chunk} ->
        {:ok, chunk}

      :error ->
        [_, fragment] = String.split(exact_id, "#", parts: 2)

        case Map.fetch(index.chunks, "#{canonical_path}##{fragment}") do
          {:ok, chunk} -> {:ok, chunk}
          :error -> :not_found
        end
    end
  end

  defp lookup_note(index, exact_path, canonical_path) do
    case Map.fetch(index.notes, exact_path) do
      {:ok, note} ->
        {:ok, note}

      :error ->
        case Map.fetch(index.notes, canonical_path) do
          {:ok, note} -> {:ok, note}
          :error -> :not_found
        end
    end
  end

  defp chunk_result(index, chunk, backlinks?) do
    base = %{
      id: chunk.id,
      heading: chunk.heading,
      heading_path: chunk.heading_path,
      type: chunk.type,
      starts: iso(chunk.starts),
      ends: iso(chunk.ends),
      body: chunk.body,
      hash: Chunk.hash(chunk),
      created_at: iso(chunk.created_at),
      updated_at: iso(chunk.updated_at)
    }

    if backlinks? do
      Map.put(base, :backlinks, backlinks_for(index, chunk.path))
    else
      base
    end
  end

  # The note's preamble — the chunk whose id is the path itself, holding the
  # text between the H1 (or frontmatter) and the first `##` — comes back as its
  # `body`; every chunk with a heading comes back as an entry of its `toc`.
  # Between them they cover every chunk the note has, so nothing `search` can
  # hit is out of `read`'s reach. A note with no preamble answers `""`, not a
  # missing key: the shape of a note read does not depend on the note.
  defp note_result(index, note, backlinks?) do
    chunks = note.chunk_ids |> Enum.map(&Map.get(index.chunks, &1)) |> Enum.reject(&is_nil/1)

    body =
      case Enum.find(chunks, &is_nil(&1.heading)) do
        nil -> ""
        preamble -> preamble.body
      end

    toc =
      chunks
      |> Enum.filter(& &1.heading)
      |> Enum.map(fn chunk ->
        %{
          id: chunk.id,
          heading: chunk.heading,
          heading_path: chunk.heading_path,
          hash: Chunk.hash(chunk)
        }
      end)

    base = %{
      path: note.path,
      title: note.title,
      type: note.type,
      starts: iso(note.starts),
      ends: iso(note.ends),
      created_at: iso(note.created_at),
      updated_at: iso(note.updated_at),
      body: body,
      toc: toc,
      links: note_link_counts(index, note)
    }

    if backlinks? do
      Map.put(base, :backlinks, backlinks_for(index, note.path))
    else
      base
    end
  end

  # A compact counter field on every note `read` response. Details come from
  # the `links` tool, not from `read` itself.
  defp note_link_counts(index, note) do
    outgoing =
      note.chunk_ids
      |> Enum.flat_map(&Map.get(index.links_out, &1, []))

    %{
      out: Enum.count(outgoing, &(&1.status == :ok)),
      in: length(backlinks_for(index, note.path)),
      broken: Enum.count(outgoing, &(&1.status != :ok))
    }
  end

  defp backlinks_for(index, target_key) do
    index.links_in |> Map.get(target_key, []) |> Enum.uniq()
  end

  @doc """
  Answers the `links` tool: outgoing references per chunk with status
  ok/ambiguous/broken (an ambiguous link lists its candidates; a broken
  link to an existing note with a missing fragment names the fragment),
  incoming references, direction `:out`/`:in`/`:both`, depth 1, depth 2
  adding each directly connected note's own depth-1 view with no further
  recursion, and the same lenient id resolution `read/2` uses. Depth 2
  describes at most 25 neighbours, the first by path, and says `truncated:
  true` when there were more.

  `params` is the `links` tool's own parameter map: `:id`, `:direction` and
  `:depth`, under the names `Vigil.MCP.Tools`' table gives them. `depth` is
  bounded where it is declared — the table publishes `1..2` and refuses
  anything else before the call reaches the Store — so this function is not
  the place a deeper value is caught.
  """
  def links(index, %{id: id, direction: direction, depth: depth}) do
    case resolve(index, id) do
      {:ok, :chunk, chunk} ->
        {:ok, build_links_result(index, chunk.id, [chunk.id], direction, depth)}

      {:ok, :note, note} ->
        {:ok, build_links_result(index, note.path, note.chunk_ids, direction, depth)}

      :not_found ->
        {:error, "Not found: #{id}"}

      :unsafe_path ->
        {:error, "Invalid path"}
    end
  end

  defp build_links_result(index, id, chunk_ids, direction, depth) do
    base = %{id: id}

    base =
      if direction in [:out, :both],
        do: Map.put(base, :outgoing, outgoing_for(index, chunk_ids)),
        else: base

    base =
      if direction in [:in, :both],
        do: Map.put(base, :incoming, incoming_for(index, id)),
        else: base

    if depth == 2, do: with_neighbors(base, index, id), else: base
  end

  # How many directly connected notes depth 2 describes. A hub note links to
  # and from dozens, and each neighbour brings its own out/in lists: the
  # answer grows with the square of how connected the vault is. The first
  # ones by path are kept, and `truncated` says whether that was all of them.
  @neighbors_max 25

  defp with_neighbors(base, index, id) do
    paths = neighbor_paths(base, id)

    neighbors =
      paths
      |> Enum.take(@neighbors_max)
      |> Map.new(fn note_path ->
        chunk_ids = note_chunk_ids(index, note_path)

        {note_path,
         %{outgoing: outgoing_for(index, chunk_ids), incoming: incoming_for(index, note_path)}}
      end)

    Map.merge(base, %{neighbors: neighbors, truncated: length(paths) > @neighbors_max})
  end

  defp outgoing_for(index, chunk_ids) do
    Enum.flat_map(chunk_ids, fn cid ->
      index.links_out
      |> Map.get(cid, [])
      |> Enum.map(&format_outgoing(cid, &1))
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

  defp incoming_for(index, id) do
    index
    |> backlinks_for(id)
    |> Enum.map(fn source -> %{source: source, status: "ok"} end)
  end

  # depth: 2 — for each directly connected note its own depth-1 out/in, with
  # no further recursion. Beyond that the value drops off fast while the
  # response size does not.
  defp neighbor_paths(base, own_id) do
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
    |> Enum.sort()
  end

  defp note_chunk_ids(index, note_path) do
    case Map.get(index.notes, note_path) do
      %Note{chunk_ids: ids} -> ids
      nil -> []
    end
  end

  @doc """
  Answers the `lint` tool's six findings: notes the load skipped for not being
  UTF-8, duplicate headings, sentence-like headings, orphaned links (broken
  outgoing links, labelled with their fragment where present), overlong notes
  and decision notes stale relative to `now`. The three note-hygiene definitions — duplicate headings,
  sentence-like headings, overlong notes — come from `Vigil.Vault.Rules`, so
  `mix vigil.vault_check` reports the same notes for the same reasons. The
  other two are this module's own: a broken link is the link index's verdict,
  and the stale-decision horizon is a constant here.

  Each category holds at most 50 findings, in a fixed order; `totals` counts
  every finding per category and `truncated` is `true` when any was cut.

  `params` carries `:now` — the instant the response's envelope was decided
  at. This module is a pure value and reads no clock of its own; a caller with
  no envelope to share one resolves it before calling.
  """
  def lint(index, %{now: now}) do
    notes = Map.values(index.notes)
    chunks = Map.values(index.chunks)

    %{
      invalid_utf8: index.invalid_utf8,
      duplicate_headings: lint_duplicate_headings(chunks),
      sentence_headings: lint_sentence_headings(chunks),
      orphaned_links: lint_orphaned_links(index),
      overlong_notes: lint_overlong_notes(index, notes),
      stale_decisions: lint_stale_decisions(notes, now)
    }
    |> capped()
  end

  # How many findings one category reports. A vault imported from elsewhere
  # can carry thousands of broken links, and an answer that size is one no
  # assistant reads to the end. Each category is in a fixed order, so the
  # findings kept are the same on every call; `totals` says how many there
  # are, and `truncated` whether any category was cut.
  @findings_max 50

  defp capped(findings) do
    totals = Map.new(findings, fn {category, list} -> {category, length(list)} end)

    findings
    |> Map.new(fn {category, list} -> {category, Enum.take(list, @findings_max)} end)
    |> Map.merge(%{
      totals: totals,
      truncated: Enum.any?(totals, fn {_category, total} -> total > @findings_max end)
    })
  end

  # Per note, because that is the scope a chunk id is unique in — and what
  # collides is the heading text's slug, not the heading chain
  # (Vigil.Vault.Rules). The ids locate every chunk in the collision.
  defp lint_duplicate_headings(chunks) do
    chunks
    |> Enum.group_by(& &1.path)
    |> Enum.sort_by(fn {path, _group} -> path end)
    |> Enum.flat_map(fn {path, note_chunks} ->
      note_chunks
      # index.chunks is a map, so the note's own order has to be restored
      # before grouping — the ids a finding lists are read in file order.
      |> Enum.sort_by(& &1.heading_line)
      |> Rules.duplicate_headings()
      |> Enum.map(fn %{slug: slug, chunks: group} ->
        %{
          path: path,
          slug: slug,
          headings: group |> Enum.map(& &1.heading) |> Enum.uniq(),
          ids: Enum.map(group, & &1.id)
        }
      end)
    end)
  end

  defp lint_sentence_headings(chunks) do
    chunks
    |> Enum.filter(fn c -> c.heading && Rules.sentence_heading?(c.heading) end)
    |> Enum.map(fn c -> %{id: c.id, heading: c.heading} end)
    |> Enum.sort_by(& &1.id)
  end

  defp lint_orphaned_links(index) do
    index.links_out
    |> Map.values()
    |> List.flatten()
    |> Enum.filter(&(&1.status == :broken))
    |> Enum.map(&link_label/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  # "Overlong" is Vigil.Vault.Rules' definition, the same one Vigil.VaultCheck
  # reports: headings and words, so the finding says which axis is the problem
  # rather than only that there is one.
  defp lint_overlong_notes(index, notes) do
    notes
    |> Enum.map(fn note -> {note, Rules.note_length(note_chunks(index, note))} end)
    |> Enum.filter(fn {_note, length} -> Rules.overlong?(length) end)
    |> Enum.map(fn {note, length} -> Map.put(length, :path, note.path) end)
    |> Enum.sort_by(& &1.path)
  end

  defp note_chunks(index, note) do
    Enum.flat_map(note.chunk_ids, fn id ->
      case Map.fetch(index.chunks, id) do
        {:ok, chunk} -> [chunk]
        :error -> []
      end
    end)
  end

  defp lint_stale_decisions(notes, now) do
    cutoff = DateTime.add(now, -@stale_decision_days * 86_400, :second)

    notes
    |> Enum.filter(fn n ->
      n.type == :decision and n.updated_at != nil and
        DateTime.compare(n.updated_at, cutoff) == :lt
    end)
    |> Enum.map(fn n -> %{path: n.path, updated_at: iso(n.updated_at)} end)
    |> Enum.sort_by(& &1.path)
  end

  @doc """
  `%{now:, active:, upcoming:, recently_past:}` from `Vigil.Events`, over the
  index's event-typed notes. `params` carries `:now`, on the same terms as
  `lint/2`.
  """
  def current(index, %{now: now}), do: Events.current(event_notes(index), now)

  @doc """
  The index's event-typed notes — the only part of the index the time envelope
  decides against. `Vigil.Store` publishes this list so the envelope can be
  computed without a call into the writer.
  """
  def event_notes(index) do
    index.notes |> Map.values() |> Enum.filter(&(&1.type == :event))
  end

  defp iso(nil), do: nil
  defp iso(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  defp index_file(file) do
    domain = domain_of(file.path)
    chunk_ids = Enum.map(file.chunks, & &1.id)

    note = %Note{
      path: file.path,
      domain: domain,
      title: file.title,
      type: file.type,
      starts: file.starts,
      ends: file.ends,
      created_at: file.created_at,
      updated_at: file.updated_at,
      chunk_ids: chunk_ids
    }

    # The chunk the parser produced, with the note's domain and title
    # denormalised onto it (`Vigil.Parser.Chunk`): search filters and titles
    # per chunk, and a note lookup per chunk is what this pays to avoid
    # (docs/design.md, "Chunking").
    #
    # And the text search compares against, folded once here rather than on
    # every query (docs/design.md, "Search").
    title_folded = Slug.fold(file.title)

    chunks =
      Map.new(file.chunks, fn chunk ->
        folded = %{
          title: title_folded,
          headings: Enum.map(chunk.heading_path, &Slug.fold/1),
          body: Slug.fold(chunk.body)
        }

        {chunk.id, %{chunk | domain: domain, file_title: file.title, folded: folded}}
      end)

    {note, chunks}
  end

  defp domain_of(path), do: path |> String.split("/") |> hd()

  # Rebuilt in full rather than maintained incrementally — see
  # `Vigil.Store`'s former `rebuild_links_index/0` for why (docs/design.md,
  # "The link index"). `Vigil.LinkIndex` returns bag-shaped lists of pairs;
  # grouped here into maps keyed by chunk id / target key so `read/2` can
  # look them up directly instead of scanning.
  defp rebuild_links(index) do
    files = Map.values(index.notes)
    chunks = Map.values(index.chunks)

    %{out: out, in: in_} = LinkIndex.build(files, chunks)

    %{index | links_out: group_pairs(out), links_in: group_pairs(in_)}
  end

  defp group_pairs(pairs) do
    Enum.reduce(pairs, %{}, fn {key, value}, acc ->
      Map.update(acc, key, [value], &[value | &1])
    end)
  end
end
