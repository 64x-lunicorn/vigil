defmodule Vigil.MCP.Tools do
  @moduledoc """
  Every MCP tool's contract, declared once.

  `@tools` is the single source of truth: name, description, the `write`
  flag, and each parameter's name, type, and whether it is required. Two
  things are generated from it — `definitions/0` (the JSON schema handed to
  the client on `tools/list`) and the argument validation `dispatch/2` runs
  before a call ever reaches `dispatch_tool/2`. A schema and its validation
  cannot drift out of agreement when they are the same table.

  `dispatch_tool/2`'s clauses stay hand-written: they aren't uniform enough
  to generate (`Store.read/2` is positional, `Store.links/3` is
  positional-3, `Store.search/1` takes a map), and by the time validation has
  run, each clause only has to say what it uniquely knows — the shape of its
  `Store` call — never how to parse or default an argument.

  Four types cover every tool: `:string`, `:boolean`, `:integer`,
  `{:enum, values}`. A `:string` marked `required: true` must also be
  non-empty; the generated schema says so with `minLength: 1`.
  """

  alias Vigil.Store

  @type_enum ["reference", "decision", "event"]

  @type param_type :: :string | :boolean | :integer | {:enum, [String.t()]}

  @type param_spec :: %{
          required(:name) => String.t(),
          required(:type) => param_type,
          required(:description) => String.t(),
          optional(:required) => boolean(),
          optional(:default) => term()
        }

  @type tool_spec :: %{
          name: String.t(),
          description: String.t(),
          write: boolean(),
          params: [param_spec]
        }

  @tools [
    %{
      name: "search",
      description: "Searches chunk bodies and headings for a phrase.",
      write: false,
      params: [
        %{name: "query", type: :string, required: true, description: "Exact search phrase."},
        %{name: "domain", type: :string, description: "Restrict results to this domain."},
        %{name: "type", type: {:enum, @type_enum}, description: "Filter by chunk type."},
        %{
          name: "prefer",
          type: {:enum, @type_enum},
          description: "Boost this type in the ranking."
        },
        %{
          name: "limit",
          type: :integer,
          default: 10,
          description: "Maximum number of hits (default 10, max 25)."
        }
      ]
    },
    %{
      name: "read",
      description:
        "Reads a chunk, or the table of contents of a note. Notes carry a compact links counter (out/in/broken); the links tool has the details.",
      write: false,
      params: [
        %{
          name: "id",
          type: :string,
          required: true,
          description: "path#heading-slug, or just path."
        },
        %{
          name: "backlinks",
          type: :boolean,
          default: false,
          description: "Append the chunk ids that link here."
        }
      ]
    },
    %{
      name: "links",
      description:
        "Shows outgoing and incoming references of a note or chunk — [[wiki]] and [text](path.md) links, resolved with status ok/ambiguous/broken.",
      write: false,
      params: [
        %{name: "id", type: :string, required: true, description: "path, or path#heading-slug."},
        %{
          name: "direction",
          type: {:enum, ["out", "in", "both"]},
          default: "both",
          description: "Defaults to both."
        },
        %{
          name: "depth",
          type: :integer,
          default: 1,
          description: "1 (default) or 2; 2 adds neighbors. Higher values are an error."
        }
      ]
    },
    %{
      name: "create",
      description:
        "Creates a new note. The path is normalized first — the response contains path_normalized_from when that changed it.",
      write: true,
      params: [
        %{name: "path", type: :string, required: true, description: "domain/filename.md."},
        %{
          name: "type",
          type: {:enum, @type_enum},
          required: true,
          description: "Frontmatter type of the note."
        },
        %{
          name: "content",
          type: :string,
          required: true,
          description: "Markdown body, starting with an H1."
        },
        %{
          name: "starts",
          type: :string,
          description: "ISO timestamp, only for type: event."
        },
        %{name: "ends", type: :string, description: "ISO timestamp, only for type: event."},
        %{
          name: "force",
          type: :boolean,
          default: false,
          description: "Skip the duplicate check."
        },
        %{
          name: "create_dirs",
          type: :boolean,
          default: false,
          description: "Create a missing project directory under projects/."
        },
        %{
          name: "skill_key",
          type: :string,
          required: true,
          description: "Current key from skill_read."
        }
      ]
    },
    %{
      name: "append",
      description: "Appends content to an existing note.",
      write: true,
      params: [
        %{name: "path", type: :string, required: true, description: "domain/filename.md."},
        %{
          name: "heading",
          type: :string,
          description: "Section name; without it, appends at end of file."
        },
        %{
          name: "content",
          type: :string,
          required: true,
          description: "Markdown text to append."
        },
        %{
          name: "skill_key",
          type: :string,
          required: true,
          description: "Current key from skill_read."
        }
      ]
    },
    %{
      name: "replace_section",
      description: "Replaces the body of exactly one chunk.",
      write: true,
      params: [
        %{name: "id", type: :string, required: true, description: "path#heading-slug."},
        %{
          name: "content",
          type: :string,
          required: true,
          description: "New body, without headings of its own."
        },
        %{
          name: "skill_key",
          type: :string,
          required: true,
          description: "Current key from skill_read."
        }
      ]
    },
    %{
      name: "rewrite_note",
      description:
        "Replaces the entire body of a note; frontmatter is preserved. Requires confirm: true only past the shrink threshold.",
      write: true,
      params: [
        %{name: "path", type: :string, required: true, description: "domain/filename.md."},
        %{
          name: "content",
          type: :string,
          required: true,
          description: "New body, starting with an H1."
        },
        %{
          name: "confirm",
          type: :boolean,
          default: false,
          description:
            "Only required once the rewrite crosses Policy's shrink threshold (removes more than half of the note's headings, or more than 20); optional otherwise."
        },
        %{
          name: "skill_key",
          type: :string,
          required: true,
          description: "Current key from skill_read."
        }
      ]
    },
    %{
      name: "delete_section",
      description: "Removes a chunk including its heading.",
      write: true,
      params: [
        %{name: "id", type: :string, required: true, description: "path#heading-slug."},
        %{
          name: "skill_key",
          type: :string,
          required: true,
          description: "Current key from skill_read."
        }
      ]
    },
    %{
      name: "update_frontmatter",
      description:
        "Sets type/starts/ends in the frontmatter of an existing note; the body is untouched.",
      write: true,
      params: [
        %{name: "path", type: :string, required: true, description: "domain/filename.md."},
        %{
          name: "type",
          type: {:enum, @type_enum},
          required: true,
          description: "New frontmatter type."
        },
        %{name: "starts", type: :string, description: "ISO timestamp, only for type: event."},
        %{name: "ends", type: :string, description: "ISO timestamp, only for type: event."},
        %{
          name: "skill_key",
          type: :string,
          required: true,
          description: "Current key from skill_read."
        }
      ]
    },
    %{
      name: "delete_note",
      description: "Permanently deletes a note. Destructive — requires confirm: true.",
      write: true,
      params: [
        %{name: "path", type: :string, required: true, description: "domain/filename.md."},
        %{
          name: "confirm",
          type: :boolean,
          default: false,
          description: "Must be true, otherwise the call is rejected."
        },
        %{
          name: "skill_key",
          type: :string,
          required: true,
          description: "Current key from skill_read."
        }
      ]
    },
    %{
      name: "move_note",
      description:
        "Moves or renames a note; both paths are normalized. Destructive — requires confirm: true.",
      write: true,
      params: [
        %{name: "from", type: :string, required: true, description: "Existing path."},
        %{name: "to", type: :string, required: true, description: "New path."},
        %{
          name: "confirm",
          type: :boolean,
          default: false,
          description: "Must be true, otherwise the call is rejected."
        },
        %{
          name: "skill_key",
          type: :string,
          required: true,
          description: "Current key from skill_read."
        }
      ]
    },
    %{
      name: "lint",
      description:
        "Reports duplicate headings, sentence-like headings, broken links, overlong notes and stale decision notes.",
      write: false,
      params: []
    },
    %{
      name: "current",
      description: "Returns the current time plus active and nearby events.",
      write: false,
      params: []
    },
    %{
      name: "reload",
      description: "Runs git pull and reparses the vault.",
      write: false,
      params: []
    },
    %{
      name: "skill_list",
      description: "Lists available skills with their description, without bodies.",
      write: false,
      params: []
    },
    %{
      name: "skill_read",
      description: "Reads the full content of a skill.",
      write: false,
      params: [
        %{
          name: "name",
          type: :string,
          required: true,
          description: "Skill name, with or without .md."
        }
      ]
    },
    %{
      name: "skill_write",
      description: "Creates or replaces a skill; only on explicit instruction.",
      write: true,
      params: [
        %{
          name: "name",
          type: :string,
          required: true,
          description: "Skill name, with or without .md."
        },
        %{
          name: "content",
          type: :string,
          required: true,
          description: "Full file content including frontmatter."
        },
        %{
          name: "skill_key",
          type: :string,
          required: true,
          description: "Current key from skill_read."
        }
      ]
    }
  ]

  @doc "Tool definitions for `tools/list`, generated from `@tools`."
  @spec definitions() :: [map()]
  def definitions do
    Enum.map(@tools, fn tool ->
      %{name: tool.name, description: tool.description, inputSchema: input_schema(tool.params)}
    end)
  end

  defp input_schema(params) do
    properties = Map.new(params, &{String.to_atom(&1.name), property_schema(&1)})
    required = for %{name: name} = spec <- params, required?(spec), do: name

    case required do
      [] -> %{type: "object", properties: properties}
      required -> %{type: "object", properties: properties, required: required}
    end
  end

  defp property_schema(%{type: :string, description: description} = spec) do
    base = %{type: "string", description: description}
    if required?(spec), do: Map.put(base, :minLength, 1), else: base
  end

  defp property_schema(%{type: :boolean, description: description}),
    do: %{type: "boolean", description: description}

  defp property_schema(%{type: :integer, description: description}),
    do: %{type: "integer", description: description}

  defp property_schema(%{type: {:enum, values}, description: description}),
    do: %{type: "string", enum: values, description: description}

  defp required?(spec), do: Map.get(spec, :required, false)

  @doc """
  True for tools that write to the vault — gated by both AP-4's SkillKey and
  AP-6's read-only (`vault:read`) scope. `skill_write` requires a SkillKey
  same as any other write tool; the bootstrap deadlock this could cause on a
  brand-new vault (no `vigil-vault-conventions` skill yet to read a key from)
  is resolved in `Vigil.Store.skill_read/1`, which reveals the current key
  even when the requested skill doesn't exist yet.
  """
  @spec write_tool?(String.t()) :: boolean()
  def write_tool?(name) do
    case find_tool(name) do
      nil -> false
      tool -> tool.write
    end
  end

  defp find_tool(name), do: Enum.find(@tools, &(&1.name == name))

  @doc """
  Dispatches a `tools/call` to the Store.

  Validates `args` against the declared tool's parameters first — a
  violation (wrong type, off-enum value, missing or empty required
  parameter) is reported as a tool error before `dispatch_tool/2` is ever
  reached, naming every violation rather than only the first. Undeclared
  parameters are ignored. Returns `{:ok, result}` or `{:error, message}`.
  """
  @spec dispatch(String.t(), map()) :: {:ok, term()} | {:error, String.t()}
  def dispatch(name, args) do
    case find_tool(name) do
      nil ->
        {:error, "Unknown tool: #{name}"}

      tool ->
        with :ok <- maybe_require_skill_key(tool, args),
             {:ok, params} <- validate_params(tool.params, args) do
          dispatch_tool(name, params)
        end
    end
  end

  defp maybe_require_skill_key(%{write: true}, args), do: require_skill_key(args)
  defp maybe_require_skill_key(%{write: false}, _args), do: :ok

  defp require_skill_key(args) do
    case Map.get(args, "skill_key") do
      key when is_binary(key) and key != "" ->
        if Vigil.SkillKey.valid?(key, Vigil.SkillKey.config()) do
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

  ## Argument validation — the table's other half.

  defp validate_params(param_specs, args) do
    {values, errors} =
      Enum.reduce(param_specs, {[], []}, fn spec, {values, errors} ->
        case validate_param(spec, args) do
          {:ok, value} -> {[{spec.name, value} | values], errors}
          {:error, message} -> {values, [message | errors]}
        end
      end)

    case Enum.reverse(errors) do
      [] -> {:ok, Map.new(values, fn {name, value} -> {String.to_atom(name), value} end)}
      messages -> {:error, Enum.join(messages, "; ")}
    end
  end

  # A JSON `null` and an absent key are the same "not provided" to a caller —
  # `Map.get/2` already collapses them, so both fall through to the default
  # (or to a missing-required error) the same way `Map.fetch/2` would only
  # for the absent case.
  defp validate_param(spec, args) do
    case Map.get(args, spec.name) do
      nil -> default_or_missing(spec)
      value -> check_type(spec, value)
    end
  end

  defp default_or_missing(spec) do
    if required?(spec) do
      missing_error(spec)
    else
      {:ok, Map.get(spec, :default)}
    end
  end

  defp check_type(%{type: :string} = spec, value) do
    cond do
      not is_binary(value) -> type_error(spec, "a string")
      required?(spec) and value == "" -> missing_error(spec)
      true -> {:ok, value}
    end
  end

  defp check_type(%{type: :boolean} = spec, value) do
    if is_boolean(value), do: {:ok, value}, else: type_error(spec, "a boolean")
  end

  defp check_type(%{type: :integer} = spec, value) do
    if is_integer(value), do: {:ok, value}, else: type_error(spec, "an integer")
  end

  defp check_type(%{type: {:enum, values}} = spec, value) do
    if value in values do
      {:ok, value}
    else
      type_error(spec, "one of #{Enum.join(values, ", ")}")
    end
  end

  defp missing_error(spec), do: {:error, "Missing or invalid parameter: #{spec.name}"}

  defp type_error(spec, expected),
    do: {:error, "Invalid parameter #{spec.name}: expected #{expected}"}

  ## Dispatch — what each tool uniquely knows about its `Store` call.

  defp dispatch_tool("search", params) do
    Store.search(%{
      query: params.query,
      domain: params.domain,
      type: type_atom(params.type),
      prefer: type_atom(params.prefer),
      limit: params.limit
    })
    |> ok()
  end

  defp dispatch_tool("read", params) do
    Store.read(params.id, params.backlinks)
  end

  defp dispatch_tool("links", params) do
    Store.links(params.id, direction_atom(params.direction), params.depth)
  end

  defp dispatch_tool("create", params) do
    Store.create(%{
      path: params.path,
      type: params.type,
      content: params.content,
      starts: params.starts,
      ends: params.ends,
      force: params.force,
      create_dirs: params.create_dirs
    })
  end

  defp dispatch_tool("append", params) do
    Store.append(%{path: params.path, heading: params.heading, content: params.content})
  end

  defp dispatch_tool("replace_section", params) do
    Store.replace_section(params.id, params.content)
  end

  defp dispatch_tool("rewrite_note", params) do
    Store.rewrite_note(%{path: params.path, content: params.content, confirm: params.confirm})
  end

  defp dispatch_tool("delete_section", params) do
    Store.delete_section(params.id)
  end

  defp dispatch_tool("update_frontmatter", params) do
    Store.update_frontmatter(%{
      path: params.path,
      type: params.type,
      starts: params.starts,
      ends: params.ends
    })
  end

  defp dispatch_tool("delete_note", params) do
    Store.delete_note(%{path: params.path, confirm: params.confirm})
  end

  defp dispatch_tool("move_note", params) do
    Store.move_note(%{from: params.from, to: params.to, confirm: params.confirm})
  end

  defp dispatch_tool("lint", _params) do
    ok(Store.lint())
  end

  defp dispatch_tool("current", _params) do
    ok(Store.current())
  end

  defp dispatch_tool("reload", _params) do
    ok(Store.reload())
  end

  defp dispatch_tool("skill_list", _params) do
    ok(Store.skill_list())
  end

  defp dispatch_tool("skill_read", params) do
    Store.skill_read(params.name)
  end

  defp dispatch_tool("skill_write", params) do
    Store.skill_write(params.name, params.content)
  end

  defp ok(value), do: {:ok, value}

  defp type_atom(nil), do: nil
  defp type_atom(value), do: String.to_existing_atom(value)

  defp direction_atom("out"), do: :out
  defp direction_atom("in"), do: :in
  defp direction_atom("both"), do: :both
end
