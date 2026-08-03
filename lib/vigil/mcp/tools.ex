defmodule Vigil.MCP.Tools do
  @moduledoc false

  alias Vigil.Store

  @type_enum ["reference", "decision", "event"]

  @doc "Tool definitions for `tools/list`."
  def definitions do
    [
      %{
        name: "search",
        description: "Durchsucht Chunk-Bodies und Überschriften nach einer Phrase.",
        inputSchema: %{
          type: "object",
          properties: %{
            query: %{type: "string", description: "Exakte Suchphrase."},
            domain: %{type: "string", description: "Domäne, auf die gefiltert wird."},
            type: %{type: "string", enum: @type_enum, description: "Filtert nach Chunk-Typ."},
            prefer: %{
              type: "string",
              enum: @type_enum,
              description: "Bevorzugt einen Typ im Ranking."
            },
            limit: %{type: "integer", description: "Maximale Trefferzahl (Default 10, Max 25)."}
          },
          required: ["query"]
        }
      },
      %{
        name: "read",
        description: "Liest einen Chunk oder das Inhaltsverzeichnis einer Note.",
        inputSchema: %{
          type: "object",
          properties: %{
            id: %{type: "string", description: "pfad#heading-slug oder pfad."},
            backlinks: %{type: "boolean", description: "Hängt verlinkende Chunk-IDs an."}
          },
          required: ["id"]
        }
      },
      %{
        name: "create",
        description: "Legt eine neue Note an.",
        inputSchema: %{
          type: "object",
          properties: %{
            path: %{type: "string", description: "domäne/dateiname.md."},
            type: %{type: "string", enum: @type_enum, description: "Frontmatter-Typ der Note."},
            content: %{type: "string", description: "Markdown-Body, beginnend mit einer H1."},
            starts: %{type: "string", description: "ISO-Zeit, nur bei type: event."},
            ends: %{type: "string", description: "ISO-Zeit, nur bei type: event."},
            force: %{type: "boolean", description: "Überspringt die Duplikat-Prüfung."},
            create_dirs: %{
              type: "boolean",
              description: "Legt einen fehlenden Projektordner unter projects/ an."
            },
            skill_key: %{type: "string", description: "Aktueller Key aus skill_read (AP-4)."}
          },
          required: ["path", "type", "content", "skill_key"]
        }
      },
      %{
        name: "append",
        description: "Hängt Inhalt an eine bestehende Note an.",
        inputSchema: %{
          type: "object",
          properties: %{
            path: %{type: "string", description: "domäne/dateiname.md."},
            heading: %{type: "string", description: "Abschnittsname; ohne Angabe ans Dateiende."},
            content: %{type: "string", description: "Anzuhängender Markdown-Text."},
            skill_key: %{type: "string", description: "Aktueller Key aus skill_read (AP-4)."}
          },
          required: ["path", "content", "skill_key"]
        }
      },
      %{
        name: "replace_section",
        description: "Ersetzt den Body genau eines Chunks.",
        inputSchema: %{
          type: "object",
          properties: %{
            id: %{type: "string", description: "pfad#heading-slug."},
            content: %{type: "string", description: "Neuer Body ohne eigene Überschriften."},
            skill_key: %{type: "string", description: "Aktueller Key aus skill_read (AP-4)."}
          },
          required: ["id", "content", "skill_key"]
        }
      },
      %{
        name: "rewrite_note",
        description:
          "Ersetzt den gesamten Body einer Note, Frontmatter bleibt erhalten. Destruktiv — verlangt confirm: true.",
        inputSchema: %{
          type: "object",
          properties: %{
            path: %{type: "string", description: "domäne/dateiname.md."},
            content: %{type: "string", description: "Neuer Body, beginnend mit einer H1."},
            confirm: %{type: "boolean", description: "Muss true sein, sonst wird abgelehnt."},
            skill_key: %{type: "string", description: "Aktueller Key aus skill_read (AP-4)."}
          },
          required: ["path", "content", "skill_key"]
        }
      },
      %{
        name: "delete_section",
        description: "Entfernt einen Chunk inklusive Überschrift.",
        inputSchema: %{
          type: "object",
          properties: %{
            id: %{type: "string", description: "pfad#heading-slug."},
            skill_key: %{type: "string", description: "Aktueller Key aus skill_read (AP-4)."}
          },
          required: ["id", "skill_key"]
        }
      },
      %{
        name: "update_frontmatter",
        description:
          "Setzt type/starts/ends im Frontmatter einer bestehenden Note; Body bleibt unangetastet.",
        inputSchema: %{
          type: "object",
          properties: %{
            path: %{type: "string", description: "domäne/dateiname.md."},
            type: %{type: "string", enum: @type_enum, description: "Neuer Frontmatter-Typ."},
            starts: %{type: "string", description: "ISO-Zeit, nur bei type: event."},
            ends: %{type: "string", description: "ISO-Zeit, nur bei type: event."},
            skill_key: %{type: "string", description: "Aktueller Key aus skill_read (AP-4)."}
          },
          required: ["path", "type", "skill_key"]
        }
      },
      %{
        name: "delete",
        description: "Löscht eine Note unwiderruflich. Destruktiv — verlangt confirm: true.",
        inputSchema: %{
          type: "object",
          properties: %{
            path: %{type: "string", description: "domäne/dateiname.md."},
            confirm: %{type: "boolean", description: "Muss true sein, sonst wird abgelehnt."},
            skill_key: %{type: "string", description: "Aktueller Key aus skill_read (AP-4)."}
          },
          required: ["path", "skill_key"]
        }
      },
      %{
        name: "move",
        description: "Verschiebt/benennt eine Note um. Destruktiv — verlangt confirm: true.",
        inputSchema: %{
          type: "object",
          properties: %{
            from: %{type: "string", description: "Bestehender Pfad."},
            to: %{type: "string", description: "Neuer Pfad."},
            confirm: %{type: "boolean", description: "Muss true sein, sonst wird abgelehnt."},
            skill_key: %{type: "string", description: "Aktueller Key aus skill_read (AP-4)."}
          },
          required: ["from", "to", "skill_key"]
        }
      },
      %{
        name: "lint",
        description:
          "Meldet Duplikate, Satz-Überschriften, verwaiste Links, überlange Notes und veraltete decision-Notes.",
        inputSchema: %{type: "object", properties: %{}}
      },
      %{
        name: "current",
        description: "Gibt die aktuelle Zeit sowie aktive/nahe Events zurück.",
        inputSchema: %{type: "object", properties: %{}}
      },
      %{
        name: "reload",
        description: "Führt git pull aus und parst den Vault neu.",
        inputSchema: %{type: "object", properties: %{}}
      },
      %{
        name: "skill_list",
        description: "Listet verfügbare Skills mit Description, ohne Body.",
        inputSchema: %{type: "object", properties: %{}}
      },
      %{
        name: "skill_read",
        description: "Liest den vollständigen Inhalt eines Skills.",
        inputSchema: %{
          type: "object",
          properties: %{name: %{type: "string", description: "Skill-Name, mit oder ohne .md."}},
          required: ["name"]
        }
      },
      %{
        name: "skill_write",
        description: "Legt einen Skill an oder ersetzt ihn; nur auf ausdrückliche Anweisung.",
        inputSchema: %{
          type: "object",
          properties: %{
            name: %{type: "string", description: "Skill-Name, mit oder ohne .md."},
            content: %{
              type: "string",
              description: "Vollständiger Dateiinhalt inkl. Frontmatter."
            }
          },
          required: ["name", "content"]
        }
      }
    ]
  end

  @write_tools ~w(create append replace_section rewrite_note delete_section update_frontmatter delete move)

  @doc "True for tools that modify the vault and are gated by AP-4's SkillKey / AP-6's read-only scope."
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
     "Fehlender oder abgelaufener SkillKey. Zuerst skill_read('vigil-vault-conventions') aufrufen, um die Konventionen zu lesen und den aktuellen Key zu erhalten."}
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

  defp dispatch_tool("delete", args) do
    with {:ok, path} <- require_string(args, "path") do
      Store.delete(%{path: path, confirm: opt_bool(args, "confirm", false)})
    end
  end

  defp dispatch_tool("move", args) do
    with {:ok, from} <- require_string(args, "from"),
         {:ok, to} <- require_string(args, "to") do
      Store.move(%{from: from, to: to, confirm: opt_bool(args, "confirm", false)})
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

  defp dispatch_tool(other, _args), do: {:error, "Unbekanntes Tool: #{other}"}

  defp ok(value), do: {:ok, value}

  defp require_string(args, key) do
    case Map.get(args, key) do
      v when is_binary(v) and v != "" -> {:ok, v}
      _ -> {:error, "Fehlender oder ungültiger Parameter: #{key}"}
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

  defp opt_type_atom(args, key) do
    case Map.get(args, key) do
      "reference" -> :reference
      "decision" -> :decision
      "event" -> :event
      _ -> nil
    end
  end
end
