defmodule Vigil.MCP.Tools do
  @moduledoc false

  alias Vigil.Store

  @type_enum ["reference", "decision", "event"]

  @doc "Tool definitions for `tools/list`."
  def definitions do
    [
      %{
        name: "search",
        description: "Searches chunk bodies and headings for a phrase.",
        inputSchema: %{
          type: "object",
          properties: %{
            query: %{type: "string", description: "Exact search phrase."},
            domain: %{type: "string", description: "Restrict results to this domain."},
            type: %{type: "string", enum: @type_enum, description: "Filter by chunk type."},
            prefer: %{
              type: "string",
              enum: @type_enum,
              description: "Boost this type in the ranking."
            },
            limit: %{type: "integer", description: "Maximum number of hits (default 10, max 25)."}
          },
          required: ["query"]
        }
      },
      %{
        name: "read",
        description:
          "Reads a chunk, or the table of contents of a note. Notes carry a compact links counter (out/in/broken); the links tool has the details.",
        inputSchema: %{
          type: "object",
          properties: %{
            id: %{type: "string", description: "path#heading-slug, or just path."},
            backlinks: %{type: "boolean", description: "Append the chunk ids that link here."}
          },
          required: ["id"]
        }
      },
      %{
        name: "links",
        description:
          "Shows outgoing and incoming references of a note or chunk — [[wiki]] and [text](path.md) links, resolved with status ok/ambiguous/broken.",
        inputSchema: %{
          type: "object",
          properties: %{
            id: %{type: "string", description: "path, or path#heading-slug."},
            direction: %{
              type: "string",
              enum: ["out", "in", "both"],
              description: "Defaults to both."
            },
            depth: %{
              type: "integer",
              description: "1 (default) or 2; 2 adds neighbors. Higher values are an error."
            }
          },
          required: ["id"]
        }
      },
      %{
        name: "create",
        description:
          "Creates a new note. The path is normalized first — the response contains path_normalized_from when that changed it.",
        inputSchema: %{
          type: "object",
          properties: %{
            path: %{type: "string", description: "domain/filename.md."},
            type: %{
              type: "string",
              enum: @type_enum,
              description: "Frontmatter type of the note."
            },
            content: %{type: "string", description: "Markdown body, starting with an H1."},
            starts: %{type: "string", description: "ISO timestamp, only for type: event."},
            ends: %{type: "string", description: "ISO timestamp, only for type: event."},
            force: %{type: "boolean", description: "Skip the duplicate check."},
            create_dirs: %{
              type: "boolean",
              description: "Create a missing project directory under projects/."
            },
            skill_key: %{type: "string", description: "Current key from skill_read."}
          },
          required: ["path", "type", "content", "skill_key"]
        }
      },
      %{
        name: "append",
        description: "Appends content to an existing note.",
        inputSchema: %{
          type: "object",
          properties: %{
            path: %{type: "string", description: "domain/filename.md."},
            heading: %{
              type: "string",
              description: "Section name; without it, appends at end of file."
            },
            content: %{type: "string", description: "Markdown text to append."},
            skill_key: %{type: "string", description: "Current key from skill_read."}
          },
          required: ["path", "content", "skill_key"]
        }
      },
      %{
        name: "replace_section",
        description: "Replaces the body of exactly one chunk.",
        inputSchema: %{
          type: "object",
          properties: %{
            id: %{type: "string", description: "path#heading-slug."},
            content: %{type: "string", description: "New body, without headings of its own."},
            skill_key: %{type: "string", description: "Current key from skill_read."}
          },
          required: ["id", "content", "skill_key"]
        }
      },
      %{
        name: "rewrite_note",
        description:
          "Replaces the entire body of a note; frontmatter is preserved. Requires confirm: true only past the shrink threshold.",
        inputSchema: %{
          type: "object",
          properties: %{
            path: %{type: "string", description: "domain/filename.md."},
            content: %{type: "string", description: "New body, starting with an H1."},
            confirm: %{
              type: "boolean",
              description: "Must be true, otherwise the call is rejected."
            },
            skill_key: %{type: "string", description: "Current key from skill_read."}
          },
          required: ["path", "content", "skill_key"]
        }
      },
      %{
        name: "delete_section",
        description: "Removes a chunk including its heading.",
        inputSchema: %{
          type: "object",
          properties: %{
            id: %{type: "string", description: "path#heading-slug."},
            skill_key: %{type: "string", description: "Current key from skill_read."}
          },
          required: ["id", "skill_key"]
        }
      },
      %{
        name: "update_frontmatter",
        description:
          "Sets type/starts/ends in the frontmatter of an existing note; the body is untouched.",
        inputSchema: %{
          type: "object",
          properties: %{
            path: %{type: "string", description: "domain/filename.md."},
            type: %{type: "string", enum: @type_enum, description: "New frontmatter type."},
            starts: %{type: "string", description: "ISO timestamp, only for type: event."},
            ends: %{type: "string", description: "ISO timestamp, only for type: event."},
            skill_key: %{type: "string", description: "Current key from skill_read."}
          },
          required: ["path", "type", "skill_key"]
        }
      },
      %{
        name: "delete_note",
        description: "Permanently deletes a note. Destructive — requires confirm: true.",
        inputSchema: %{
          type: "object",
          properties: %{
            path: %{type: "string", description: "domain/filename.md."},
            confirm: %{
              type: "boolean",
              description: "Must be true, otherwise the call is rejected."
            },
            skill_key: %{type: "string", description: "Current key from skill_read."}
          },
          required: ["path", "skill_key"]
        }
      },
      %{
        name: "move_note",
        description:
          "Moves or renames a note; both paths are normalized. Destructive — requires confirm: true.",
        inputSchema: %{
          type: "object",
          properties: %{
            from: %{type: "string", description: "Existing path."},
            to: %{type: "string", description: "New path."},
            confirm: %{
              type: "boolean",
              description: "Must be true, otherwise the call is rejected."
            },
            skill_key: %{type: "string", description: "Current key from skill_read."}
          },
          required: ["from", "to", "skill_key"]
        }
      },
      %{
        name: "lint",
        description:
          "Reports duplicate headings, sentence-like headings, broken links, overlong notes and stale decision notes.",
        inputSchema: %{type: "object", properties: %{}}
      },
      %{
        name: "current",
        description: "Returns the current time plus active and nearby events.",
        inputSchema: %{type: "object", properties: %{}}
      },
      %{
        name: "reload",
        description: "Runs git pull and reparses the vault.",
        inputSchema: %{type: "object", properties: %{}}
      },
      %{
        name: "skill_list",
        description: "Lists available skills with their description, without bodies.",
        inputSchema: %{type: "object", properties: %{}}
      },
      %{
        name: "skill_read",
        description: "Reads the full content of a skill.",
        inputSchema: %{
          type: "object",
          properties: %{name: %{type: "string", description: "Skill name, with or without .md."}},
          required: ["name"]
        }
      },
      %{
        name: "skill_write",
        description: "Creates or replaces a skill; only on explicit instruction.",
        inputSchema: %{
          type: "object",
          properties: %{
            name: %{type: "string", description: "Skill name, with or without .md."},
            content: %{
              type: "string",
              description: "Full file content including frontmatter."
            },
            skill_key: %{type: "string", description: "Current key from skill_read."}
          },
          required: ["name", "content", "skill_key"]
        }
      }
    ]
  end

  @write_tools ~w(create append replace_section rewrite_note delete_section update_frontmatter delete_note move_note skill_write)

  @doc """
  True for tools that write to the vault — gated by both AP-4's SkillKey and
  AP-6's read-only (`vault:read`) scope. `skill_write` requires a SkillKey
  same as any other write tool; the bootstrap deadlock this could cause on a
  brand-new vault (no `vigil-vault-conventions` skill yet to read a key from)
  is resolved in `Vigil.Store.skill_read/1`, which reveals the current key
  even when the requested skill doesn't exist yet.
  """
  def write_tool?(name), do: name in @write_tools

  @doc "Dispatches a `tools/call` to the Store. Returns `{:ok, result}` or `{:error, message}`."
  def dispatch(name, args) do
    if write_tool?(name) do
      with :ok <- require_skill_key(args) do
        dispatch_tool(name, args)
      end
    else
      dispatch_tool(name, args)
    end
  end

  defp require_skill_key(args) do
    case Map.get(args, "skill_key") do
      key when is_binary(key) and key != "" ->
        if Vigil.SkillKey.valid?(key, Vigil.SkillKey.secret()) do
          :ok
        else
          skill_key_error()
        end

      _ ->
        skill_key_error()
    end
  end

  defp skill_key_error do
    {:error,
     "Missing or expired SkillKey. Call skill_read('vigil-vault-conventions') first to read the conventions and obtain the current key."}
  end

  defp dispatch_tool("search", args) do
    with {:ok, query} <- require_string(args, "query") do
      Store.search(%{
        query: query,
        domain: opt_string(args, "domain"),
        type: opt_type_atom(args, "type"),
        prefer: opt_type_atom(args, "prefer"),
        limit: opt_integer(args, "limit", 10)
      })
      |> ok()
    end
  end

  defp dispatch_tool("read", args) do
    with {:ok, id} <- require_string(args, "id") do
      Store.read(id, opt_bool(args, "backlinks", false))
    end
  end

  defp dispatch_tool("links", args) do
    with {:ok, id} <- require_string(args, "id") do
      Store.links(id, opt_direction(args), opt_integer(args, "depth", 1))
    end
  end

  defp dispatch_tool("create", args) do
    with {:ok, path} <- require_string(args, "path"),
         {:ok, type} <- require_string(args, "type"),
         {:ok, content} <- require_string(args, "content") do
      Store.create(%{
        path: path,
        type: type,
        content: content,
        starts: opt_string(args, "starts"),
        ends: opt_string(args, "ends"),
        force: opt_bool(args, "force", false),
        create_dirs: opt_bool(args, "create_dirs", false)
      })
    end
  end

  defp dispatch_tool("append", args) do
    with {:ok, path} <- require_string(args, "path"),
         {:ok, content} <- require_string(args, "content") do
      Store.append(%{path: path, heading: opt_string(args, "heading"), content: content})
    end
  end

  defp dispatch_tool("replace_section", args) do
    with {:ok, id} <- require_string(args, "id"),
         {:ok, content} <- require_string(args, "content") do
      Store.replace_section(id, content)
    end
  end

  defp dispatch_tool("rewrite_note", args) do
    with {:ok, path} <- require_string(args, "path"),
         {:ok, content} <- require_string(args, "content") do
      Store.rewrite_note(%{
        path: path,
        content: content,
        confirm: opt_bool(args, "confirm", false)
      })
    end
  end

  defp dispatch_tool("delete_section", args) do
    with {:ok, id} <- require_string(args, "id") do
      Store.delete_section(id)
    end
  end

  defp dispatch_tool("update_frontmatter", args) do
    with {:ok, path} <- require_string(args, "path"),
         {:ok, type} <- require_string(args, "type") do
      Store.update_frontmatter(%{
        path: path,
        type: type,
        starts: opt_string(args, "starts"),
        ends: opt_string(args, "ends")
      })
    end
  end

  defp dispatch_tool("delete_note", args) do
    with {:ok, path} <- require_string(args, "path") do
      Store.delete_note(%{path: path, confirm: opt_bool(args, "confirm", false)})
    end
  end

  defp dispatch_tool("move_note", args) do
    with {:ok, from} <- require_string(args, "from"),
         {:ok, to} <- require_string(args, "to") do
      Store.move_note(%{from: from, to: to, confirm: opt_bool(args, "confirm", false)})
    end
  end

  defp dispatch_tool("lint", _args) do
    ok(Store.lint())
  end

  defp dispatch_tool("current", _args) do
    ok(Store.current())
  end

  defp dispatch_tool("reload", _args) do
    ok(Store.reload())
  end

  defp dispatch_tool("skill_list", _args) do
    ok(Store.skill_list())
  end

  defp dispatch_tool("skill_read", args) do
    with {:ok, name} <- require_string(args, "name") do
      Store.skill_read(name)
    end
  end

  defp dispatch_tool("skill_write", args) do
    with {:ok, name} <- require_string(args, "name"),
         {:ok, content} <- require_string(args, "content") do
      Store.skill_write(name, content)
    end
  end

  defp dispatch_tool(other, _args), do: {:error, "Unknown tool: #{other}"}

  defp ok(value), do: {:ok, value}

  defp require_string(args, key) do
    case Map.get(args, key) do
      v when is_binary(v) and v != "" -> {:ok, v}
      _ -> {:error, "Missing or invalid parameter: #{key}"}
    end
  end

  defp opt_string(args, key), do: Map.get(args, key)

  defp opt_bool(args, key, default) do
    case Map.get(args, key) do
      nil -> default
      v when is_boolean(v) -> v
      _ -> default
    end
  end

  defp opt_integer(args, key, default) do
    case Map.get(args, key) do
      nil -> default
      v when is_integer(v) -> v
      v when is_binary(v) -> String.to_integer(v)
      _ -> default
    end
  end

  defp opt_direction(args) do
    case Map.get(args, "direction") do
      "out" -> :out
      "in" -> :in
      _ -> :both
    end
  end

  defp opt_type_atom(args, key) do
    case Map.get(args, key) do
      "reference" -> :reference
      "decision" -> :decision
      "event" -> :event
      _ -> nil
    end
  end
end
