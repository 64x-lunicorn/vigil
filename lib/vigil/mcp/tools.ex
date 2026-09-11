defmodule Vigil.MCP.Tools do
  @moduledoc """
  Every MCP tool's contract, declared once.

  `@tools` is the single source of truth: name, description, the `write`
  flag, the `call` the tool makes, whether that call resolves an instant
  (`now:`), and each parameter's name, type, and whether it is required. Three things are generated from it — `definitions/0`
  (the JSON schema handed to the client on `tools/list`), the argument
  validation `dispatch/5` runs on `tools/call`, and the `Store.call/3` that
  follows it. A schema, its validation and the call they describe cannot drift
  out of agreement when they are the same table. Adding a tool is adding a
  row.

  The call is a row's `call:` and its parameters: every declared parameter
  travels under the name the table gives it, except `skill_key`, which
  authorizes a write (AP-4) and belongs to no operation. Nothing is parsed or
  defaulted at that point — by the time the call is built, validation has run
  and every declared parameter has a value.

  `skill_key` is also the one parameter no row declares. A write takes it
  because it is a write, and the row already says `write: true` — the gate
  below reads the requirement off that flag, so the parameter is derived from
  it as well rather than written out identically in every write row. The
  `confirm` parameter is not derivable the same way and stays declared per
  row: only three of the nine writes take one, and `write: true` does not
  say which.

  `Vigil.Store` answers all but two of the operations. `skill_list` and
  `skill_read` are answered against `Vigil.Skills` in the caller's own
  process — see `answer/4`.

  Which writer that is, is the caller's to say. `dispatch/5` takes it and
  defaults to `Vigil.Store.default_name/0`, the registration production runs
  under and hands in no name for. A caller that supplies one reaches a writer
  of its own — the same thing `Vigil.Store`'s own interface has always taken,
  and what lets a test file exercising this layer run beside the others
  instead of queueing behind one registered atom.

  Four types cover every tool: `:string`, `:boolean`, `{:integer, min..max}`,
  `{:enum, values}`. A `:string` marked `required: true` must also be
  non-empty; the generated schema says so with `minLength: 1`. An integer is
  always bounded — there is no unbounded integer type, because a bound stated
  anywhere but here is a bound the published schema does not carry and the
  validator does not enforce. The range is published as `minimum`/`maximum`
  and an out-of-range value is refused in the same shape as an off-enum
  string, before the Store's mailbox is reached.

  An enum's internal form is the atom of the same name. The table declares the
  values, so the mapping is derived from them rather than restated per tool —
  which is what let `search` convert its `type` while `create` passed the same
  enum through as a string.
  """

  alias Vigil.{Skills, SkillKey, Store}

  # The one parameter that is not a parameter of any Store operation: it
  # authorizes a write and is consumed by the gate below.
  @skill_key :skill_key
  @skill_key_name Atom.to_string(@skill_key)

  # And the one parameter no row declares. It belongs to every write and to no
  # read, which is what `write:` already says, so the table states it once here
  # instead of nine times identically.
  @skill_key_param %{
    name: @skill_key_name,
    type: :string,
    required: true,
    description: "Current key from skill_read."
  }

  @type_enum ["reference", "decision", "event"]

  @type param_type :: :string | :boolean | {:integer, Range.t()} | {:enum, [String.t()]}

  @type param_spec :: %{
          required(:name) => String.t(),
          required(:type) => param_type,
          required(:description) => String.t(),
          optional(:required) => boolean(),
          optional(:default) => term()
        }

  @type tool_spec :: %{
          required(:name) => String.t(),
          required(:description) => String.t(),
          required(:write) => boolean(),
          required(:call) => atom(),
          required(:params) => [param_spec],
          optional(:now) => boolean()
        }

  @tools [
    %{
      name: "search",
      description: "Searches chunk bodies and headings for a phrase.",
      write: false,
      call: :search,
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
          type: {:integer, 1..25},
          default: 10,
          description: "Maximum number of hits (default 10)."
        }
      ]
    },
    %{
      name: "read",
      description:
        "Reads a chunk, or the table of contents of a note. Notes carry a compact links counter (out/in/broken); the links tool has the details.",
      write: false,
      call: :read,
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
      call: :links,
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
          type: {:integer, 1..2},
          default: 1,
          description: "Defaults to 1; 2 adds each directly connected note's own depth-1 view."
        }
      ]
    },
    %{
      name: "create",
      description:
        "Creates a new note. The path is normalized first — the response contains path_normalized_from when that changed it.",
      write: true,
      call: :create,
      now: true,
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
        }
      ]
    },
    %{
      name: "append",
      description: "Appends content to an existing note.",
      write: true,
      call: :append,
      now: true,
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
        }
      ]
    },
    %{
      name: "replace_section",
      description: "Replaces the body of exactly one chunk.",
      write: true,
      call: :replace_section,
      now: true,
      params: [
        %{name: "id", type: :string, required: true, description: "path#heading-slug."},
        %{
          name: "content",
          type: :string,
          required: true,
          description: "New body, without headings of its own."
        }
      ]
    },
    %{
      name: "rewrite_note",
      description:
        "Replaces the entire body of a note; frontmatter is preserved. Requires confirm: true only past the shrink threshold.",
      write: true,
      call: :rewrite_note,
      now: true,
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
        }
      ]
    },
    %{
      name: "delete_section",
      description: "Removes a chunk including its heading.",
      write: true,
      call: :delete_section,
      now: true,
      params: [
        %{name: "id", type: :string, required: true, description: "path#heading-slug."}
      ]
    },
    %{
      name: "update_frontmatter",
      description:
        "Sets type/starts/ends in the frontmatter of an existing note; the body is untouched.",
      write: true,
      call: :update_frontmatter,
      now: true,
      params: [
        %{name: "path", type: :string, required: true, description: "domain/filename.md."},
        %{
          name: "type",
          type: {:enum, @type_enum},
          required: true,
          description: "New frontmatter type."
        },
        %{name: "starts", type: :string, description: "ISO timestamp, only for type: event."},
        %{name: "ends", type: :string, description: "ISO timestamp, only for type: event."}
      ]
    },
    %{
      name: "delete_note",
      description: "Permanently deletes a note. Destructive — requires confirm: true.",
      write: true,
      call: :delete_note,
      now: true,
      params: [
        %{name: "path", type: :string, required: true, description: "domain/filename.md."},
        %{
          name: "confirm",
          type: :boolean,
          default: false,
          description: "Must be true, otherwise the call is rejected."
        }
      ]
    },
    %{
      name: "move_note",
      description:
        "Moves or renames a note; both paths are normalized. Destructive — requires confirm: true.",
      write: true,
      call: :move_note,
      now: true,
      params: [
        %{name: "from", type: :string, required: true, description: "Existing path."},
        %{name: "to", type: :string, required: true, description: "New path."},
        %{
          name: "confirm",
          type: :boolean,
          default: false,
          description: "Must be true, otherwise the call is rejected."
        }
      ]
    },
    %{
      name: "lint",
      description:
        "Reports duplicate headings, sentence-like headings, broken links, overlong notes and stale decision notes.",
      write: false,
      call: :lint,
      now: true,
      params: []
    },
    %{
      name: "current",
      description: "Returns the current time plus active and nearby events.",
      write: false,
      call: :current,
      now: true,
      params: []
    },
    %{
      name: "reload",
      description: "Runs git pull and reparses the vault.",
      write: false,
      call: :reload,
      params: []
    },
    %{
      name: "skill_list",
      description: "Lists available skills with their description, without bodies.",
      write: false,
      call: :skill_list,
      params: []
    },
    %{
      name: "skill_read",
      description: "Reads the full content of a skill.",
      write: false,
      call: :skill_read,
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
      call: :skill_write,
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
        }
      ]
    }
  ]

  # Every enum value the table declares, paired with its internal form. Built
  # once from `@tools` rather than written per tool, so an enum added to a row
  # converts without a second edit somewhere else.
  @enum_atoms for tool <- @tools,
                  %{type: {:enum, values}} <- tool.params,
                  value <- values,
                  into: %{},
                  do: {value, String.to_atom(value)}

  @doc "Tool definitions for `tools/list`, generated from `@tools`."
  @spec definitions() :: [map()]
  def definitions do
    Enum.map(@tools, fn tool ->
      %{
        name: tool.name,
        description: tool.description,
        inputSchema: input_schema(param_specs(tool))
      }
    end)
  end

  # A row's parameters, plus the one its `write:` flag implies. Last, where it
  # was written by hand in every write row — the published schema lists its
  # required parameters in declaration order, and this is a change to how the
  # table is written, not to what `tools/list` serves.
  defp param_specs(%{write: true} = tool), do: tool.params ++ [@skill_key_param]
  defp param_specs(%{write: false} = tool), do: tool.params

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

  defp property_schema(%{type: {:integer, min..max//_}, description: description}),
    do: %{type: "integer", minimum: min, maximum: max, description: description}

  defp property_schema(%{type: {:enum, values}, description: description}),
    do: %{type: "string", enum: values, description: description}

  defp required?(spec), do: Map.get(spec, :required, false)

  @doc """
  True for tools that write to the vault — gated by both AP-4's SkillKey and
  AP-6's read-only (`vault:read`) scope. `skill_write` requires a SkillKey
  same as any other write tool; the bootstrap deadlock this could cause on a
  brand-new vault (no `vigil-vault-conventions` skill yet to read a key from)
  is resolved in `Vigil.Skills.read/3`, which reveals the current key even
  when the requested skill doesn't exist yet.
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
  Dispatches a `tools/call` to `store` at `now`, the instant the response's
  envelope was decided at.

  Validates `args` against the declared tool's parameters first — a
  violation (wrong type, off-enum value, missing or empty required
  parameter) is reported as a tool error before the Store's mailbox is
  reached, naming every violation rather than only the first. Undeclared
  parameters are ignored. What is left is the call the row declares.
  Returns `{:ok, result}` or `{:error, message}`.

  A row's `now:` marks an operation that resolves an instant. It is handed
  the response's, under the `:now` key the Store already reads, rather than
  reading a clock of its own inside the writer — which is how `current` came
  to report a time its own envelope could contradict across a minute
  boundary. `now` has no default here: an instant a caller forgot to pass is
  a second clock read, which is the thing being removed.

  `store` is the writer the call is made against, the one thing here that a
  deployment and a test file legitimately disagree about. It defaults to the
  registration production runs under, so the MCP surface hands in no name.

  `key` is the deployment's SkillKey (`Vigil.SkillKey.key/1`), built from the
  settings the composition root resolved and handed in for the same reason
  `now` is: it has no default here, because a gate that resolves its own
  secret is a gate a test cannot hand another deployment.
  """
  @spec dispatch(GenServer.server(), String.t(), map(), DateTime.t(), SkillKey.t()) ::
          {:ok, term()} | {:error, String.t()}
  def dispatch(store \\ Store.default_name(), name, args, now, key) do
    case find_tool(name) do
      nil ->
        {:error, "Unknown tool: #{name}"}

      tool ->
        with :ok <- maybe_require_skill_key(tool, args, key),
             {:ok, params} <- validate_params(param_specs(tool), args) do
          params = params |> Map.delete(@skill_key) |> maybe_put_now(tool, now)
          tool.call |> answer(params, store, key) |> to_result()
        end
    end
  end

  # Almost every operation is the single writer's. The two exceptions are the
  # skill reads: `skills/` is a separate system from the vault's notes
  # (docs/design.md, "skills/ — one repository, two systems"), Vigil.Skills
  # takes the vault path as a plain argument, and principle 2 — one writer —
  # is a rule about writes. A skill *write* still goes through the mailbox, to
  # commit and push in order with note writes. Answering the reads here is
  # what keeps a skill read — the mandatory bootstrap in front of every write
  # (AP-4) — from queueing behind the push at the end of the write before it.
  #
  # They still read the path off the writer that was handed in, not off the
  # default one: a vault is the writer's, and a read answered against another
  # writer's vault is a read of the wrong vault.
  defp answer(:skill_list, %{}, store, _key), do: Skills.list(Store.vault_path(store))

  defp answer(:skill_read, %{name: name}, store, key),
    do: Skills.read(name, Store.vault_path(store), key)

  defp answer(op, params, store, _key), do: Store.call(store, op, params)

  defp maybe_put_now(params, %{now: true}, now), do: Map.put(params, :now, now)
  defp maybe_put_now(params, _tool, _now), do: params

  defp maybe_require_skill_key(%{write: true}, args, key), do: require_skill_key(args, key)
  defp maybe_require_skill_key(%{write: false}, _args, _key), do: :ok

  defp require_skill_key(args, key) do
    case Map.get(args, @skill_key_name) do
      token when is_binary(token) and token != "" ->
        if SkillKey.valid?(token, key) do
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

  ## Argument validation — the table's second product.

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
    resolved =
      case Map.get(args, spec.name) do
        nil -> default_or_missing(spec)
        value -> check_type(spec, value)
      end

    with {:ok, value} <- resolved, do: {:ok, internal_form(spec, value)}
  end

  # The declared form is what the schema publishes and what a violation is
  # reported against; the internal form is what the vault speaks. An enum
  # crosses over here — on the same path for a supplied value and for a
  # default, so `direction`'s "both" arrives as `:both` like any other.
  defp internal_form(%{type: {:enum, _}}, value) when is_binary(value),
    do: Map.fetch!(@enum_atoms, value)

  defp internal_form(_spec, value), do: value

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

  defp check_type(%{type: {:integer, min..max//_ = range}} = spec, value) do
    if is_integer(value) and value in range do
      {:ok, value}
    else
      type_error(spec, "an integer between #{min} and #{max}")
    end
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

  ## The Store's answer.

  # An operation that cannot fail answers with its value; one that can answers
  # with a result tuple. Which is which is a property of the operation, read
  # off the shape it returns — a `raw: true` in the table would be a second
  # statement of it, free to disagree with the Store, and removing that class
  # of twin is what the table is for.
  defp to_result({:ok, _} = result), do: result
  defp to_result({:error, _} = result), do: result
  defp to_result(value), do: {:ok, value}
end
