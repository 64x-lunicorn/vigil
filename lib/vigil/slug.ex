defmodule Vigil.Slug do
  @moduledoc """
  Canonical slug form for path segments and headings, and the path-safety
  rule that guards them.

  This is the single slug implementation in the project — `Vigil.Parser.slug/1`
  delegates here, so that chunk IDs and file/directory names can never drift
  apart. `legacy_slugify/1` is the one deliberate exception; see its docs.

  `safe_path/1` sits here because it is the rule `normalize_path/1` is applied
  under: a path is checked for sanity, normalized, and checked again. Both the
  read path (`Vigil.Index`) and the write gate (`Vigil.Vault.Policy`) ask it;
  neither owns it.
  """

  @max_length 80

  @invalid_path {:error, "Invalid path"}

  # Applied *before* generic diacritic stripping: NFD decomposition would turn
  # "ü" into "u", losing the information that German expects "ue".
  @transliterations [
    {"ä", "ae"},
    {"ö", "oe"},
    {"ü", "ue"},
    {"ß", "ss"},
    {"å", "aa"},
    {"ø", "oe"},
    {"æ", "ae"},
    {"đ", "d"},
    {"ł", "l"},
    {"þ", "th"}
  ]

  @doc """
  Slugifies a single segment (file basename, directory name, heading).

  Pipeline: NFC normalize, trim, downcase, explicit transliteration, generic
  diacritic stripping, non-alphanumeric runs to a single hyphen, collapse and
  trim hyphens, truncate to #{@max_length} characters at a hyphen boundary.

  Returns `{:ok, slug}`, or `{:error, :empty}` when nothing is left (input had
  no alphanumeric characters at all).
  """
  def slugify(text) do
    slug =
      text
      |> String.normalize(:nfc)
      |> String.trim()
      |> String.downcase()
      |> transliterate()
      |> strip_diacritics()
      |> String.replace(~r/[^a-z0-9]+/u, "-")
      |> collapse_hyphens()
      |> truncate()

    if slug == "" do
      {:error, :empty}
    else
      {:ok, slug}
    end
  end

  defp transliterate(text) do
    Enum.reduce(@transliterations, text, fn {from, to}, acc ->
      String.replace(acc, from, to)
    end)
  end

  defp strip_diacritics(text) do
    text
    |> String.normalize(:nfd)
    |> String.replace(~r/\p{Mn}/u, "")
    |> String.normalize(:nfc)
  end

  defp collapse_hyphens(text) do
    text
    |> String.replace(~r/-+/, "-")
    |> String.trim("-")
  end

  defp truncate(text) do
    if String.length(text) <= @max_length do
      text
    else
      text
      |> String.slice(0, @max_length)
      |> truncate_at_hyphen()
    end
  end

  defp truncate_at_hyphen(text) do
    case :binary.matches(text, "-") do
      [] ->
        text

      matches ->
        {pos, _len} = List.last(matches)
        String.slice(text, 0, pos)
    end
    |> String.trim_trailing("-")
  end

  @doc """
  Normalizes a vault-relative path.

  Every directory segment and the file basename are slugified individually;
  the extension is lowercased and re-appended (whether the extension is
  *allowed* is the security layer's job, not this function's). Empty segments
  from doubled slashes are dropped.

  Returns `{:ok, normalized_path, changed?}` or `{:error, reason}`.
  """
  def normalize_path(path) do
    segments =
      path
      |> String.split("/")
      |> Enum.reject(&(&1 == ""))

    case segments do
      [] ->
        {:error, :empty}

      _ ->
        {directories, [filename]} = Enum.split(segments, -1)
        extension = filename |> Path.extname() |> String.downcase()
        basename = Path.basename(filename, Path.extname(filename))

        with {:ok, slugged_directories} <- slugify_all(directories),
             {:ok, slugged_basename} <- slugify(basename) do
          normalized =
            Enum.join(slugged_directories ++ ["#{slugged_basename}#{extension}"], "/")

          {:ok, normalized, normalized != path}
        end
    end
  end

  defp slugify_all(segments) do
    Enum.reduce_while(segments, {:ok, []}, fn segment, {:ok, acc} ->
      case slugify(segment) do
        {:ok, s} -> {:cont, {:ok, acc ++ [s]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  @doc """
  Whether a vault-relative path is safe to resolve at all.

  The rule every path crosses, on the read side as well as the write side:
  no traversal, no absolute path, no backslash, no null byte, and no segment
  starting with `.` (hidden) or `_` (reserved, e.g. `_domains.yml`).

  It is deliberately not a *permission* check — `skills/tdd.md` and a note in
  an excluded domain both pass here. Which paths a caller may read or write is
  the caller's own rule; `Vigil.Vault.Policy` adds the write ones on top,
  `Vigil.Index` adds none.

  Where it goes relative to `normalize_path/1` is `canonical_path/1`'s to
  know, not each caller's: a caller that needs both wants that one.

  Returns `:ok` or `{:error, "Invalid path"}` — the message callers hand back
  verbatim.
  """
  @spec safe_path(String.t()) :: :ok | {:error, String.t()}
  def safe_path(path) do
    cond do
      String.contains?(path, "..") -> @invalid_path
      String.starts_with?(path, "/") -> @invalid_path
      String.contains?(path, "\\") -> @invalid_path
      String.contains?(path, <<0>>) -> @invalid_path
      Enum.any?(String.split(path, "/"), &reserved_segment?/1) -> @invalid_path
      true -> :ok
    end
  end

  @doc """
  The canonical form of a vault-relative path, or the refusal `safe_path/1`
  gives.

  The two steps in the one order they are safe in. `normalize_path/1`
  slugifies every segment, which turns `_domains.yml` into `domains.yml`,
  `/abs/x.md` into `abs/x.md` and `a\\b.md` into `a-b.md` — so a path checked
  only *after* it is normalized is a path whose check the normalization has
  laundered. Checking before and after is the rule, and this is where it is
  stated: every caller that turns a path a caller typed into the path the
  vault stores needs it, and a caller cannot get the order wrong if it does
  not hold the order.

  A path no filename can be derived from comes back unchanged rather than as
  an error. It will not be found either way, and a caller should answer for it
  the way it answers a miss — `Vigil.Index` does, and `Vigil.Vault.Policy`
  wants the same verdict.
  """
  @spec canonical_path(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def canonical_path(path) do
    with :ok <- safe_path(path) do
      case normalize_path(path) do
        {:ok, normalized, _changed?} -> {:ok, normalized}
        {:error, _reason} -> {:ok, path}
      end
    end
  end

  @doc """
  Whether a single path segment is hidden (`.`) or reserved (`_`).

  The per-segment half of `safe_path/1`, for callers holding one segment
  rather than a path.
  """
  @spec reserved_segment?(String.t()) :: boolean
  def reserved_segment?(segment) do
    String.starts_with?(segment, ".") or String.starts_with?(segment, "_")
  end

  @doc """
  The slug logic as it was *before* the canonical-slug rework, preserved
  verbatim.

  Used only to show what a slug change would break: `Vigil.Vault.Rules` holds
  the comparison, and `Vigil.VaultCheck` and `mix vigil.slug_diff` report it.
  **Never** used in the production path — this is the one deliberate exception
  to "a single slug implementation in the project".
  """
  def legacy_slugify(text) do
    text
    |> String.downcase()
    |> String.replace("ä", "ae")
    |> String.replace("ö", "oe")
    |> String.replace("ü", "ue")
    |> String.replace("ß", "ss")
    |> String.replace(~r/\s+/, "-")
    |> String.replace(~r/[^a-z0-9-]/, "")
    |> String.replace(~r/-+/, "-")
    |> String.trim("-")
  end
end
