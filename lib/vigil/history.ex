defmodule Vigil.History do
  @moduledoc """
  The two reads that answer out of the Git history rather than the index:
  the `history` tool, and `read` at a revision (docs/design.md, "No audit
  log").

  Git is vigil's metadata database (principle 3), and every write is a
  commit, so what a note went through is already recorded — this reads it
  back through the `Vigil.Git` value the writer holds, and records nothing of
  its own. Both are answered by `Vigil.Store` inside its read clause, so they
  are freshened like every other read.

  A path is handled the way `Vigil.Index` handles one: unsafe answers
  "Invalid path" without being quoted back, and the exact spelling is tried
  before the canonical one.
  """

  require Logger

  alias Vigil.{Git, Index, Parser, Slug}

  # What every commit vigil makes is authored as (`Vigil.Git`'s commit
  # identity). The address, not the name, is what tells vigil's commits from
  # a human's: a human may call themselves anything, but commits from
  # vigil@local are vigil's.
  @vigil_email "vigil@local"

  @doc """
  The commits that touched the note at `path`, newest first, at most `limit`,
  following renames: `{:ok, %{path: path, commits: [%{commit:, date:, author:,
  by:, message:, path:}]}}`. `by` is `"vigil"` or `"human"`; each commit's
  `path` is what the note was called in it, which is what `read` at that
  commit takes. A path with no history at all is "Not found".
  """
  @spec history(Git.t(), Path.t(), %{path: String.t(), limit: pos_integer()}) ::
          {:ok, map()} | {:error, String.t()}
  def history(%Git{} = git, vault_path, %{path: path, limit: limit}) do
    with {:ok, candidates} <- candidates(path) do
      Enum.reduce_while(candidates, {:error, "Not found: #{path}"}, fn candidate, miss ->
        case git.history.(vault_path, candidate, limit) do
          {:ok, []} ->
            {:cont, miss}

          {:ok, commits} ->
            {:halt, {:ok, %{path: candidate, commits: Enum.map(commits, &commit_result/1)}}}

          {:error, reason} ->
            Logger.warning("history of #{candidate} failed: #{inspect(reason)}")
            {:halt, {:error, "Could not read the history of #{path}"}}
        end
      end)
    end
  end

  defp commit_result(commit) do
    %{
      commit: commit.commit,
      date: DateTime.to_iso8601(commit.at),
      author: commit.author,
      by: if(commit.email == @vigil_email, do: "vigil", else: "human"),
      message: commit.message,
      path: commit.path
    }
  end

  @doc """
  `read` at a revision: the note or chunk `id` names, as the note was at
  `at`, rendered as `Vigil.Index.read/2` renders the current one, plus `at`,
  the commit the revision names in full.

  The old text is parsed with the normal parser and read against the current
  vault, so its `links` counters and backlinks are today's; its `updated_at`
  is the last commit up to `at` that touched the note, and its `created_at`
  the one the vault knows for the path. The id's path is the one the note had
  at that revision — a note renamed since is read under the name `history`
  reports for the commit. A revision that names no commit is "Unknown
  revision".
  """
  @spec read_at(Git.t(), Path.t(), Index.t(), map()) :: {:ok, map()} | {:error, String.t()}
  def read_at(%Git{} = git, vault_path, index, %{id: id, at: rev, backlinks: backlinks?}) do
    [path | fragment] = String.split(id, "#", parts: 2)

    with {:ok, candidates} <- candidates(path),
         {:ok, found, shown} <- show(git, vault_path, rev, candidates, id),
         {:ok, parsed} <- parse(found, shown) do
      index
      |> Index.put(parsed)
      |> Index.read(%{id: Enum.join([found | fragment], "#"), backlinks: backlinks?})
      |> case do
        {:ok, result} -> {:ok, Map.put(result, :at, shown.commit)}
        {:error, "Not found: " <> _} -> {:error, "Not found: #{id} at #{rev}"}
        error -> error
      end
    end
  end

  defp show(git, vault_path, rev, candidates, id) do
    Enum.reduce_while(candidates, {:error, "Not found: #{id} at #{rev}"}, fn candidate, miss ->
      case git.show.(vault_path, rev, candidate) do
        {:ok, shown} -> {:halt, {:ok, candidate, shown}}
        {:error, :not_found} -> {:cont, miss}
        {:error, :unknown_revision} -> {:halt, {:error, "Unknown revision: #{rev}"}}
      end
    end)
  end

  defp parse(path, shown) do
    case Parser.parse(path, shown.content, %{updated_at: shown.updated_at}) do
      {:ok, parsed} -> {:ok, parsed}
      {:error, :invalid_utf8} -> {:error, "Not UTF-8: #{path}"}
    end
  end

  # The exact spelling first, so a note whose filename the vault stores
  # unslugified is found under the name it has, then the canonical one.
  defp candidates(path) do
    case Slug.canonical_path(path) do
      {:ok, canonical} -> {:ok, Enum.uniq([path, canonical])}
      {:error, _} -> {:error, "Invalid path"}
    end
  end
end
