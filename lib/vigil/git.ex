defmodule Vigil.Git do
  @moduledoc false

  require Logger

  @doc "git pull --ff-only <remote> main. Logs and returns {:error, reason} on failure (caller decides)."
  def pull(vault_path, remote) do
    case run(vault_path, ["pull", "--ff-only", remote, "main"]) do
      {:ok, _out} ->
        :ok

      {:error, out} ->
        Logger.warning("git pull fehlgeschlagen: #{out}")
        {:error, out}
    end
  end

  @doc """
  One-shot metadata scan for the whole vault: returns a map
  `path => %{created_at:, updated_at:, last_author:}`.
  """
  def log_metadata(vault_path) do
    format = "%H%x00%aI%x00%an"

    case run(vault_path, [
           "log",
           "--format=#{format}",
           "--name-only",
           "--diff-filter=AM",
           "--reverse"
         ]) do
      {:ok, out} -> parse_log(out)
      {:error, _out} -> %{}
    end
  end

  defp parse_log(output) do
    output
    |> String.split("\n")
    |> Enum.reduce({%{}, nil}, fn line, {acc, current} ->
      cond do
        line == "" ->
          {acc, current}

        String.contains?(line, "\0") ->
          [_hash, iso, author] = String.split(line, "\0", parts: 3)
          {:ok, dt, _} = DateTime.from_iso8601(iso)
          {acc, %{at: dt, author: author}}

        current != nil ->
          path = line
          entry = Map.get(acc, path)

          new_entry =
            case entry do
              nil ->
                %{created_at: current.at, updated_at: current.at, last_author: current.author}

              existing ->
                %{existing | updated_at: current.at, last_author: current.author}
            end

          {Map.put(acc, path, new_entry), current}

        true ->
          {acc, current}
      end
    end)
    |> elem(0)
  end

  @doc """
  `git add` + `git commit` for a single file, authored as `vigil <vigil@local>`.
  Returns `{:ok, %{updated_at:, last_author:}}` or `{:error, reason}`.
  """
  def add_commit(vault_path, path, message) do
    with {:ok, _} <- run(vault_path, ["add", "--", path]),
         {:ok, _} <-
           run(vault_path, [
             "-c",
             "user.name=vigil",
             "-c",
             "user.email=vigil@local",
             "commit",
             "-m",
             message,
             "--",
             path
           ]) do
      last_commit_meta(vault_path, path)
    end
  end

  @doc "git push <remote> main. Returns :ok | {:error, reason}."
  def push(vault_path, remote) do
    case run(vault_path, ["push", remote, "main"]) do
      {:ok, _} -> :ok
      {:error, out} -> {:error, out}
    end
  end

  @doc "git rm -- path, then commit, authored as vigil. Returns :ok | {:error, reason}."
  def remove_commit(vault_path, path, message) do
    with {:ok, _} <- run(vault_path, ["rm", "--", path]),
         {:ok, _} <-
           run(vault_path, [
             "-c",
             "user.name=vigil",
             "-c",
             "user.email=vigil@local",
             "commit",
             "-m",
             message,
             "--",
             path
           ]) do
      :ok
    end
  end

  @doc """
  `git mv from to`, then commit both paths, authored as vigil.
  Returns `{:ok, %{updated_at:, last_author:}}` or `{:error, reason}`.
  """
  def move_commit(vault_path, from, to, message) do
    with {:ok, _} <- run(vault_path, ["mv", "--", from, to]),
         {:ok, _} <-
           run(vault_path, [
             "-c",
             "user.name=vigil",
             "-c",
             "user.email=vigil@local",
             "commit",
             "-m",
             message,
             "--",
             from,
             to
           ]) do
      last_commit_meta(vault_path, to)
    end
  end

  defp last_commit_meta(vault_path, path) do
    case run(vault_path, ["log", "-1", "--format=%aI%x00%an", "--", path]) do
      {:ok, out} ->
        [iso, author] = out |> String.trim() |> String.split("\0", parts: 2)
        {:ok, dt, _} = DateTime.from_iso8601(iso)
        {:ok, %{updated_at: dt, last_author: author}}

      {:error, out} ->
        {:error, out}
    end
  end

  defp run(vault_path, args) do
    case System.cmd("git", args, cd: vault_path, stderr_to_stdout: true) do
      {out, 0} -> {:ok, out}
      {out, _code} -> {:error, out}
    end
  end
end
