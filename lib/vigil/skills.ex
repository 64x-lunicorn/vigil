defmodule Vigil.Skills do
  @moduledoc """
  `skills/` — one repository, two systems (`docs/design.md`).

  Skills are a genuinely separate concern from notes: `skills/` is excluded
  from domain discovery, skill files are never parsed or indexed as notes,
  and skill writes carry no `Vigil.Vault.Policy` check — only this module's
  own two: a protected skill is not written at all, and an existing one is
  replaced only on `confirm: true`. The write effect is
  still the same effect, and `Vigil.Commit` owns it for both — what `write/3`
  does not do is `Vigil.Store`'s reparse between commit and push, which would
  index a skill as a note.

  Takes `vault_path`/`git_remote`/`git_branch` as plain arguments — no
  GenServer, no ETS — and the git adapter as a value beside them
  (`docs/design.md`, "Git is reached through a value"). There is no default
  for it here: this module holds no configuration it could build one from, so
  the one caller that has it hands it over.
  """

  require Logger

  alias Vigil.{Commit, Markdown, SkillKey}
  alias Vigil.Vault.Layout

  @doc """
  Lists skills (name + description) found under `vault_path`/skills/.

  A file whose name is not UTF-8 is left out with a warning: its name could
  not travel as a skill name in `skill_list`'s JSON, and `read/3` refuses it
  anyway (docs/design.md, "A note that is not UTF-8 is skipped").
  """
  def list(vault_path) do
    dir = Path.join(vault_path, "skills")

    if File.dir?(dir), do: listed(dir, File.ls!(dir)), else: []
  end

  @doc false
  # list/1 over file names handed in, so a name the test filesystem refuses
  # (APFS will not hold one that is not UTF-8) can still be handed to it.
  def listed(dir, filenames) do
    filenames
    |> Enum.filter(&(String.ends_with?(&1, ".md") and utf8_name?(&1)))
    |> Enum.map(fn filename ->
      name = Path.basename(filename, ".md")
      description = skill_description(Path.join(dir, filename))
      %{name: name, description: description}
    end)
  end

  defp utf8_name?(filename) do
    if String.valid?(filename) do
      true
    else
      Logger.warning(
        "vigil: skipped skills/#{Layout.printable_path(filename)}: its file name is not " <>
          "UTF-8, so it cannot be a skill name; rename it in UTF-8 to list it"
      )

      false
    end
  end

  # Sobelow: a file name vigil listed from skills/ itself.
  # sobelow_skip ["Traversal.FileModule"]
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

  `key` is the deployment's SkillKey, handed in the way the vault path is:
  this module reads no configuration of its own.
  """
  # Sobelow: name must match ^[a-z0-9_-]+$ (valid_skill_name?/1) before it is
  # joined.
  # sobelow_skip ["Traversal.FileModule"]
  def read(name, vault_path, key) do
    normalized = normalize_skill_name(name)

    if valid_skill_name?(normalized) do
      abs_path = Path.join([vault_path, "skills", "#{normalized}.md"])

      case File.read(abs_path) do
        {:ok, content} ->
          token = SkillKey.current(key)
          prefixed = "SkillKey: #{token} #{validity(key)}\n\n" <> content
          {:ok, %{name: normalized, content: prefixed}}

        {:error, _} ->
          # The key is a pure HMAC over secret + time and does not depend on
          # any skill existing, so it is handed out in the not-found case too.
          # Otherwise this deadlocks bootstrapping: skill_write itself
          # requires a SkillKey, but a fresh vault has no conventions skill to
          # read one from.
          names = vault_path |> list() |> Enum.map(& &1.name) |> Enum.join(", ")
          token = SkillKey.current(key)

          {:error,
           "Skill not found: #{normalized}. Available: #{names}. SkillKey: #{token} #{validity(key)}."}
      end
    else
      {:error, "Invalid path"}
    end
  end

  # What the gate will accept, said from the key it checks against: the window
  # is the deployment's, and `Vigil.SkillKey.valid?/3` takes the previous
  # window's token too, so no fixed hour is true of every deployment.
  defp validity(key) do
    "(rotates every #{key.window} seconds; the previous window's key is still accepted)"
  end

  defp normalize_skill_name(name) do
    name
    |> String.trim()
    |> String.replace_suffix(".md", "")
  end

  defp valid_skill_name?(name), do: Regex.match?(~r/^[a-z0-9_-]+$/, name)

  # Skills no MCP call may write, created or replaced: the conventions skill is
  # what every session reads before it writes, so an instruction smuggled into
  # something the assistant read could otherwise rewrite what every later
  # session is told (docs/design.md, "skills/ — one repository, two systems").
  # They change the way a hand edit does, as a commit through the remote.
  @protected ~w(vigil-vault-conventions)

  @doc """
  Writes a skill, commits and pushes it. Does not parse or index the file —
  skills are never notes.

  A skill that already exists is replaced only with `confirm: true` in
  `opts`, and a protected one (`vigil-vault-conventions`) is never written.
  """
  def write(name, content, %{vault_path: vault_path, git: git} = target, opts \\ []) do
    normalized = normalize_skill_name(name)

    rel_path = "skills/#{normalized}.md"

    with true <- valid_skill_name?(normalized),
         :ok <- writable(normalized),
         :ok <- validate_skill_frontmatter(content),
         :ok <- confirm_replace(vault_path, rel_path, Keyword.get(opts, :confirm, false)),
         {:ok, _commit_meta} <-
           Commit.write(
             git,
             vault_path,
             target.git_branch,
             rel_path,
             Markdown.normalize_trailing_newline(content),
             "skill_write: #{rel_path}"
           ) do
      push(git, normalized, vault_path, target)
    else
      false -> {:error, "Invalid path"}
      {:error, msg} -> {:error, msg}
    end
  end

  defp writable(name) when name in @protected do
    {:error,
     "#{name} is protected and cannot be written through MCP. " <>
       "Change it by hand, as a commit through the remote " <>
       ~s{(docs/guide.md, "Editing by hand").}}
  end

  defp writable(_name), do: :ok

  # The same gate, in the same words, as Vigil.Vault.Policy's on delete_note
  # and move_note: replacing a skill takes away what it said.
  defp confirm_replace(vault_path, rel_path, confirm) do
    if confirm == true or not File.exists?(Path.join(vault_path, rel_path)) do
      :ok
    else
      {:error,
       "Destructive operation: replaces the existing skill #{rel_path}. " <>
         "Call again with confirm: true to execute it."}
    end
  end

  # The push is Vigil.Commit's, like the write above it; the sentence in front
  # of the failure is this module's. The push-failure messages in the project
  # describe different objects — a skill, and a change, a deletion or a move to
  # the vault — and saying so is the point of having four. As in Vigil.Store, a
  # failed push is a success with `pushed: false`: the skill is committed, and
  # an error would only invite a retry.
  defp push(git, name, vault_path, %{git_remote: remote, git_branch: branch}) do
    case Commit.push(git, vault_path, remote, branch) do
      :ok ->
        {:ok, %{name: name, pushed: true}}

      {:error, out} ->
        {:ok,
         %{name: name, pushed: false, push_error: "Skill saved locally, but push failed: #{out}"}}
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
