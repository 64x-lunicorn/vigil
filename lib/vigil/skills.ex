defmodule Vigil.Skills do
  @moduledoc """
  `skills/` — one repository, two systems (`docs/design.md`).

  Skills are a genuinely separate concern from notes: `skills/` is excluded
  from domain discovery, skill files are never parsed or indexed as notes,
  and skill writes carry no `Vigil.Vault.Policy` check. The write effect is
  still the same effect, and `Vigil.Commit` owns it for both — what `write/3`
  does not do is `Vigil.Store`'s reparse between commit and push, which would
  index a skill as a note.

  Takes `vault_path`/`git_remote` as plain arguments — no GenServer, no ETS.
  """

  alias Vigil.{Commit, Git, Markdown, SkillKey}

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

    rel_path = "skills/#{normalized}.md"

    with true <- valid_skill_name?(normalized),
         :ok <- validate_skill_frontmatter(content),
         {:ok, _commit_meta} <-
           Commit.write(
             vault_path,
             rel_path,
             Markdown.normalize_trailing_newline(content),
             "skill_write: #{rel_path}"
           ) do
      push(normalized, vault_path, git_remote)
    else
      false -> {:error, "Invalid path"}
      {:error, msg} -> {:error, msg}
    end
  end

  # Push stays here rather than in Vigil.Commit: the two push-failure messages
  # in the project describe different objects — a skill, and a change to the
  # vault — and saying so is the point of having two.
  defp push(name, vault_path, git_remote) do
    case Git.push(vault_path, git_remote) do
      :ok -> {:ok, %{name: name, pushed: true}}
      {:error, out} -> {:error, "Skill saved locally, but push failed: #{out}"}
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
end
