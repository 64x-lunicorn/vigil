defmodule Vigil.Slug do
  @moduledoc """
  Canonical slug form for path segments and headings.

  This is the single slug implementation in the project — `Vigil.Parser.slug/1`
  delegates here, so that chunk IDs and file/directory names can never drift
  apart. `legacy_slugify/1` is the one deliberate exception; see its docs.
  """

  @max_length 80

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
  The slug logic as it was *before* the canonical-slug rework, preserved
  verbatim.

  Used exclusively by `mix vigil.slug_diff` to show which chunk IDs would
  change on migration. **Never** used in the production path — this is the one
  deliberate exception to "a single slug implementation in the project".
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
