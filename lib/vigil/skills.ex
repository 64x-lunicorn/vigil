defmodule Vigil.Skills do
  @moduledoc """
  `skills/` — one repository, two systems (`docs/design.md`).

  Skills are a genuinely separate concern from notes: `skills/` is excluded
  from domain discovery, skill files are never parsed or indexed as notes,
  and skill writes carry no `Vigil.Vault.Policy` check. `write/3` therefore
  does not reuse `Vigil.Store.write_and_commit/5` — that helper always
  reparses and indexes the written file afterward, which would be wrong
  here — and this module keeps its own small copy of the mkdir/write/
  error-mapping helpers rather than sharing them with `Store`.

  Takes `vault_path`/`git_remote` as plain arguments — no GenServer, no ETS.
  """

  alias Vigil.{Git, Markdown, SkillKey}

  @doc "Lists skills (name + description) found under `vault_path`/skills/."
  def list(vault_path) do
    dir = Path.join(vault_path, "skills")

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
         {:ok, yaml_text, _body, _offset} <- Markdown.frontmatter(content),
         {:ok, %{"description" => desc}} <- YamlElixir.read_from_string(yaml_text) do
      desc
    else
      _ -> nil
    end
  end

  @doc """
  Reads a skill by name. Both the found and not-found response are
  prefixed with the current SkillKey token — the read-side token, data
  attached to the response, not the write gate (that lives in
  `lib/vigil/mcp/tools.ex`).
  """
  def read(name, vault_path) do
    normalized = normalize_skill_name(name)

    if valid_skill_name?(normalized) do
      abs_path = Path.join([vault_path, "skills", "#{normalized}.md"])

      case File.read(abs_path) do
        {:ok, content} ->
          token = SkillKey.current(SkillKey.config())
          prefixed = "SkillKey: #{token} (valid until the next full hour)\n\n" <> content
          {:ok, %{name: normalized, content: prefixed}}

        {:error, _} ->
          # The key is a pure HMAC over secret + time and does not depend on
          # any skill existing, so it is handed out in the not-found case too.
          # Otherwise this deadlocks bootstrapping: skill_write itself
          # requires a SkillKey, but a fresh vault has no conventions skill to
          # read one from.
          names = vault_path |> list() |> Enum.map(& &1.name) |> Enum.join(", ")
          token = SkillKey.current(SkillKey.config())

          {:error,
           "Skill not found: #{normalized}. Available: #{names}. SkillKey: #{token} (valid until the next full hour)."}
      end
    else
      {:error, "Invalid path"}
    end
  end

  defp normalize_skill_name(name) do
    name
    |> String.trim()
    |> String.replace_suffix(".md", "")
  end

  defp valid_skill_name?(name), do: Regex.match?(~r/^[a-z0-9_-]+$/, name)

  @doc """
  Writes a skill, commits and pushes it. Does not parse or index the file —
  skills are never notes.
  """
  def write(name, content, %{vault_path: vault_path, git_remote: git_remote}) do
    normalized = normalize_skill_name(name)

    with true <- valid_skill_name?(normalized),
         :ok <- validate_skill_frontmatter(content) do
      abs_path = Path.join([vault_path, "skills", "#{normalized}.md"])
      rel_path = "skills/#{normalized}.md"

      with :ok <- safe_mkdir_p(Path.dirname(abs_path)),
           :ok <- safe_write(abs_path, normalize_trailing_newline(content)) do
        case Git.add_commit(vault_path, rel_path, "skill_write: #{rel_path}") do
          {:ok, _commit_meta} ->
            case Git.push(vault_path, git_remote) do
              :ok ->
                {:ok, %{name: normalized, pushed: true}}

              {:error, out} ->
                {:error, "Skill saved locally, but push failed: #{out}"}
            end

          {:error, out} ->
            {:error, "git commit failed: #{out}"}
        end
      end
    else
      false -> {:error, "Invalid path"}
      {:error, msg} -> {:error, msg}
    end
  end

  defp validate_skill_frontmatter(content) do
    case Markdown.frontmatter(content) do
      {:ok, yaml_text, _body, _offset} ->
        case YamlElixir.read_from_string(yaml_text) do
          {:ok, %{"name" => _, "description" => _}} -> :ok
          _ -> {:error, "Frontmatter must contain 'name' and 'description'"}
        end

      :unterminated ->
        {:error, "Unterminated frontmatter"}

      :none ->
        {:error, "content must start with frontmatter"}
    end
  end

  defp normalize_trailing_newline(content) do
    String.trim_trailing(content, "\n") <> "\n"
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
end
