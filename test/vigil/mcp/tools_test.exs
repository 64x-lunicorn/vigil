defmodule Vigil.MCP.ToolsTest do
  use ExUnit.Case, async: true

  alias Vigil.MCP.Tools

  # Every dispatch is made at the instant its response's envelope was decided
  # at; nothing in this file depends on which one it is.
  @now ~U[2026-07-09 11:20:00Z]

  # The deployment's SkillKey, stated rather than resolved: the write gate
  # takes it as an argument, so the key a test signs a token with is the key
  # the gate checks it against.
  @key %{secret: "tools-test-secret", window: 3600}

  @write_tools ~w(create append replace_section rewrite_note delete_section update_frontmatter delete_note move_note skill_write)

  describe "definitions/0 is derived from the declaration table" do
    test "seventeen tools, matching write_tool?/1 to the write: flag" do
      definitions = Tools.definitions()
      assert length(definitions) == 17

      for %{name: name} <- definitions do
        assert Tools.write_tool?(name) == name in @write_tools
      end
    end

    test "search: query required with minLength 1, type/prefer carry the enum, limit does not" do
      [search] = Enum.filter(Tools.definitions(), &(&1.name == "search"))
      props = search.inputSchema.properties

      assert search.inputSchema.required == ["query"]
      assert props.query == %{type: "string", description: "Exact search phrase.", minLength: 1}
      assert props.domain.type == "string"
      refute Map.has_key?(props.domain, :minLength)
      assert props.type.enum == ["reference", "decision", "event"]
      assert props.prefer.enum == ["reference", "decision", "event"]

      assert props.limit == %{
               type: "integer",
               minimum: 1,
               maximum: 25,
               description: "Maximum number of hits (default 10)."
             }
    end

    test "links: direction carries the out/in/both enum, depth publishes its range" do
      [links] = Enum.filter(Tools.definitions(), &(&1.name == "links"))
      props = links.inputSchema.properties

      assert links.inputSchema.required == ["id"]
      assert props.direction.enum == ["out", "in", "both"]
      assert props.depth.type == "integer"
      assert props.depth.minimum == 1
      assert props.depth.maximum == 2
    end

    test "create: path/type/content/skill_key are required, type carries the enum" do
      [create] = Enum.filter(Tools.definitions(), &(&1.name == "create"))
      props = create.inputSchema.properties

      assert create.inputSchema.required == ["path", "type", "content", "skill_key"]
      assert props.type.enum == ["reference", "decision", "event"]
      assert props.path.minLength == 1
      assert props.force.type == "boolean"
      assert props.create_dirs.type == "boolean"
    end

    test "rewrite_note's confirm description matches what Policy does, not the destructive wording" do
      [rewrite_note] = Enum.filter(Tools.definitions(), &(&1.name == "rewrite_note"))
      description = rewrite_note.inputSchema.properties.confirm.description

      refute description == "Must be true, otherwise the call is rejected."
      assert description =~ "shrink threshold"
    end

    test "delete_note and move_note keep confirm out of required" do
      [delete_note] = Enum.filter(Tools.definitions(), &(&1.name == "delete_note"))
      [move_note] = Enum.filter(Tools.definitions(), &(&1.name == "move_note"))

      refute "confirm" in delete_note.inputSchema.required
      refute "confirm" in move_note.inputSchema.required
      assert delete_note.inputSchema.properties.confirm.description =~ "rejected"
      assert move_note.inputSchema.properties.confirm.description =~ "rejected"
    end

    # No row declares `skill_key`: a tool takes one because it writes, and the
    # row already says `write: true`. What the derivation replaces is nine
    # identical blocks, each free to drift in its description or its
    # required-ness while the gate went on requiring the same thing.
    test "every write tool publishes the same skill_key, and no read tool publishes one" do
      for %{name: name, inputSchema: schema} <- Tools.definitions() do
        if name in @write_tools do
          assert schema.properties.skill_key == %{
                   type: "string",
                   minLength: 1,
                   description: "Current key from skill_read."
                 }

          assert List.last(schema.required) == "skill_key"
        else
          refute Map.has_key?(schema.properties, :skill_key)
          refute "skill_key" in Map.get(schema, :required, [])
        end
      end
    end

    test "parameterless tools declare no required key" do
      for name <- ~w(lint current reload skill_list) do
        [tool] = Enum.filter(Tools.definitions(), &(&1.name == name))
        refute Map.has_key?(tool.inputSchema, :required)
        assert tool.inputSchema.properties == %{}
      end
    end
  end

  describe "dispatch/5 validates before the Store is reached" do
    test "an unknown tool is rejected without touching the Store" do
      assert Tools.dispatch("does_not_exist", %{}, @now, @key) ==
               {:error, "Unknown tool: does_not_exist"}
    end

    test "a missing required string is a tool error, not a raise" do
      assert {:error, message} = Tools.dispatch("search", %{}, @now, @key)
      assert message =~ "Missing or invalid parameter: query"
    end

    test "an empty required string is treated the same as missing" do
      assert {:error, message} = Tools.dispatch("search", %{"query" => ""}, @now, @key)
      assert message =~ "Missing or invalid parameter: query"
    end

    test "a non-string value for a string parameter is a tool error" do
      assert {:error, message} = Tools.dispatch("search", %{"query" => 123}, @now, @key)
      assert message =~ "Invalid parameter query"
      assert message =~ "a string"
    end

    test "a non-boolean value for a boolean parameter is a tool error" do
      assert {:error, message} =
               Tools.dispatch("read", %{"id" => "bike/x.md", "backlinks" => "yes"}, @now, @key)

      assert message =~ "Invalid parameter backlinks"
      assert message =~ "a boolean"
    end

    test "limit: \"abc\" is a tool error, not a 500" do
      assert {:error, message} =
               Tools.dispatch("search", %{"query" => "tires", "limit" => "abc"}, @now, @key)

      assert message =~ "Invalid parameter limit"
      assert message =~ "an integer between 1 and 25"
    end

    # The bound used to be a silent clamp in Vigil.Search: limit: 100 returned
    # 25 hits and said nothing, limit: -5 returned none. A declared bound is
    # refused in the same shape as an off-enum string.
    test "a limit outside 1..25 is refused rather than clamped" do
      for out_of_range <- [100, 26, 0, -5] do
        assert {:error, message} =
                 Tools.dispatch(
                   "search",
                   %{"query" => "tires", "limit" => out_of_range},
                   @now,
                   @key
                 )

        assert message =~ "Invalid parameter limit: expected an integer between 1 and 25"
      end
    end

    test "a depth outside 1..2 is refused before the Store is reached" do
      assert {:error, message} =
               Tools.dispatch("links", %{"id" => "bike/x.md", "depth" => 3}, @now, @key)

      assert message =~ "Invalid parameter depth: expected an integer between 1 and 2"

      assert {:error, message} =
               Tools.dispatch("links", %{"id" => "bike/x.md", "depth" => 0}, @now, @key)

      assert message =~ "Invalid parameter depth"
    end

    test "an off-enum value is a tool error naming the allowed values" do
      assert {:error, message} =
               Tools.dispatch("search", %{"query" => "tires", "type" => "bogus"}, @now, @key)

      assert message =~ "Invalid parameter type"
      assert message =~ "reference"
      assert message =~ "decision"
      assert message =~ "event"
    end

    test "direction: \"sideways\" is rejected rather than silently becoming :both" do
      assert {:error, message} =
               Tools.dispatch(
                 "links",
                 %{"id" => "bike/x.md", "direction" => "sideways"},
                 @now,
                 @key
               )

      assert message =~ "Invalid parameter direction"
    end

    test "every violation is reported in one message, not only the first" do
      assert {:error, message} =
               Tools.dispatch("search", %{"type" => "bogus", "limit" => "abc"}, @now, @key)

      assert message =~ "query"
      assert message =~ "type"
      assert message =~ "limit"
    end

    test "undeclared parameters are ignored" do
      assert {:error, message} = Tools.dispatch("search", %{"nonsense" => "x"}, @now, @key)
      refute message =~ "nonsense"
      assert message =~ "query"
    end

    test "an explicit null for an optional parameter is treated as absent, not a type error" do
      assert {:error, message} = Tools.dispatch("search", %{"domain" => nil}, @now, @key)
      refute message =~ "domain"
      assert message =~ "query"
    end

    test "an explicit null for a required parameter is the same as missing" do
      assert {:error, message} = Tools.dispatch("search", %{"query" => nil}, @now, @key)
      assert message =~ "Missing or invalid parameter: query"
    end

    test "a write tool without skill_key gets the SkillKey error, not a generic one" do
      assert {:error, message} =
               Tools.dispatch(
                 "create",
                 %{
                   "path" => "bike/x.md",
                   "type" => "reference",
                   "content" => "# X"
                 },
                 @now,
                 @key
               )

      assert message =~ "SkillKey"
    end

    test "a write tool with an expired skill_key gets the SkillKey error" do
      token = Vigil.SkillKey.current(@key, System.system_time(:second) - 7200)

      assert {:error, message} =
               Tools.dispatch(
                 "create",
                 %{
                   "path" => "bike/x.md",
                   "type" => "reference",
                   "content" => "# X",
                   "skill_key" => token
                 },
                 @now,
                 @key
               )

      assert message =~ "SkillKey"
    end

    test "a read-only tool needs no skill_key" do
      assert {:error, message} = Tools.dispatch("search", %{}, @now, @key)
      refute message =~ "SkillKey"
    end
  end
end
