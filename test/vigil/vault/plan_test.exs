defmodule Vigil.Vault.PlanTest do
  use ExUnit.Case, async: true

  alias Vigil.Index
  alias Vigil.Vault.Plan

  # No vault, no git, no GenServer: a plan is a value derived from a decision
  # and a string.

  @note """
  ---
  type: reference
  ---
  # Terra Speed

  ## Fueling
  Old body.

  ## Gearing
  Gearing body.
  """

  # A chunk as Vigil.Vault.Edit needs it. Line numbers are the parser's: the
  # body ends at its last non-blank line.
  defp chunk(id, heading, heading_line, body_end_line) do
    %Index.Chunk{
      id: id,
      path: "bike/terra-speed.md",
      heading: heading,
      heading_line: heading_line,
      body_end_line: body_end_line
    }
  end

  defp fueling, do: chunk("bike/terra-speed.md#fueling", "Fueling", 6, 7)

  describe "create" do
    test "frontmatter is built in front of the content, and the message quotes the H1" do
      resolved = %{
        path: "bike/new.md",
        normalized_from: nil,
        type: :reference,
        starts: nil,
        ends: nil
      }

      assert {:ok, plan} = Plan.build(:create, resolved, %{content: "# New\n\nbody"}, nil)

      assert plan.path == "bike/new.md"
      assert plan.content == "---\ntype: reference\n---\n# New\n\nbody\n"
      assert plan.message == "create: bike/new.md — # New"
      assert plan.report == %{}
    end

    test "an event carries starts and ends in the frontmatter" do
      resolved = %{
        path: "bike/race.md",
        normalized_from: nil,
        type: :event,
        starts: ~U[2026-05-01 08:00:00Z],
        ends: ~U[2026-05-01 18:00:00Z]
      }

      assert {:ok, plan} = Plan.build(:create, resolved, %{content: "# Race\n"}, nil)

      assert plan.content =~ "starts: 2026-05-01T08:00:00Z"
      assert plan.content =~ "ends: 2026-05-01T18:00:00Z"
    end

    test "a normalized path is reported back, so the caller learns where the note landed" do
      resolved = %{
        path: "bike/terra-speed.md",
        normalized_from: "Bike/Terra Speed.md",
        type: :reference,
        starts: nil,
        ends: nil
      }

      assert {:ok, plan} = Plan.build(:create, resolved, %{content: "# T\n"}, nil)
      assert plan.report == %{path_normalized_from: "Bike/Terra Speed.md"}
    end

    test "the commit subject stays a subject" do
      long = String.duplicate("x", 200)

      resolved = %{
        path: "bike/x.md",
        normalized_from: nil,
        type: :reference,
        starts: nil,
        ends: nil
      }

      assert {:ok, plan} = Plan.build(:create, resolved, %{content: "# #{long}"}, nil)
      assert String.length(plan.message) == String.length("create: bike/x.md — ") + 50
    end
  end

  describe "append" do
    test "at the end of the file" do
      resolved = %{path: "bike/terra-speed.md", target: :end}

      assert {:ok, plan} = Plan.build(:append, resolved, %{content: "Extra."}, @note)

      assert String.ends_with?(plan.content, "Gearing body.\n\nExtra.\n")
      assert plan.message == "append: bike/terra-speed.md — Extra."
    end

    test "into an existing section" do
      resolved = %{path: "bike/terra-speed.md", target: {:section, fueling()}}

      assert {:ok, plan} = Plan.build(:append, resolved, %{content: "More."}, @note)

      assert plan.content =~ "Old body.\nMore.\n\n## Gearing"
    end

    test "in a new section at the end of the file" do
      resolved = %{path: "bike/terra-speed.md", target: {:new_section, "Tyres"}}

      assert {:ok, plan} = Plan.build(:append, resolved, %{content: "Tubeless."}, @note)

      assert String.ends_with?(plan.content, "\n## Tyres\nTubeless.\n")
    end
  end

  describe "replace_section and delete_section" do
    test "replace swaps the body and names the chunk in the message" do
      resolved = %{path: "bike/terra-speed.md", chunk: fueling()}

      assert {:ok, plan} = Plan.build(:replace_section, resolved, %{content: "New body."}, @note)

      assert plan.content =~ "## Fueling\nNew body.\n\n## Gearing"
      refute plan.content =~ "Old body."
      assert plan.message == "replace_section: bike/terra-speed.md#fueling"
    end

    test "delete takes the heading with the body" do
      resolved = %{path: "bike/terra-speed.md", chunk: fueling()}

      assert {:ok, plan} = Plan.build(:delete_section, resolved, %{}, @note)

      refute plan.content =~ "Fueling"
      assert plan.content =~ "## Gearing"
      assert plan.message == "delete_section: bike/terra-speed.md#fueling"
    end

    test "a chunk that is gone is an error, not a raise" do
      resolved = %{path: "bike/terra-speed.md", chunk: nil}

      assert {:error, "no such section"} =
               Plan.build(:replace_section, resolved, %{content: "x"}, @note)

      assert {:error, "no such section"} = Plan.build(:delete_section, resolved, %{}, @note)
    end
  end

  describe "rewrite_note" do
    test "keeps the frontmatter and replaces the body" do
      resolved = %{path: "bike/terra-speed.md"}

      assert {:ok, plan} =
               Plan.build(:rewrite_note, resolved, %{content: "# T\n\nAll new."}, @note)

      assert plan.content == "---\ntype: reference\n---\n# T\n\nAll new.\n"
      assert plan.message == "rewrite_note: bike/terra-speed.md"
    end

    test "a note whose frontmatter cannot be split is an error" do
      assert {:error, message} =
               Plan.build(
                 :rewrite_note,
                 %{path: "bike/x.md"},
                 %{content: "# T"},
                 "# No frontmatter"
               )

      assert is_binary(message)
    end
  end

  describe "update_frontmatter" do
    test "replaces the frontmatter and leaves the body alone" do
      resolved = %{path: "bike/terra-speed.md", type: :decision, starts: nil, ends: nil}

      assert {:ok, plan} = Plan.build(:update_frontmatter, resolved, %{}, @note)

      assert String.starts_with?(plan.content, "---\ntype: decision\n---\n")
      assert plan.content =~ "## Fueling\nOld body."
      assert plan.message == "update_frontmatter: bike/terra-speed.md"
    end

    test "an event gains its timestamps" do
      resolved = %{
        path: "bike/terra-speed.md",
        type: :event,
        starts: ~U[2026-05-01 08:00:00Z],
        ends: ~U[2026-05-01 18:00:00Z]
      }

      assert {:ok, plan} = Plan.build(:update_frontmatter, resolved, %{}, @note)

      assert plan.content =~ "starts: 2026-05-01T08:00:00Z"
      assert plan.content =~ "ends: 2026-05-01T18:00:00Z"
    end

    test "a note whose frontmatter cannot be split is an error" do
      resolved = %{path: "bike/x.md", type: :reference, starts: nil, ends: nil}

      assert {:error, message} =
               Plan.build(:update_frontmatter, resolved, %{}, "# No frontmatter")

      assert is_binary(message)
    end
  end

  test "every plan ends the file the way Vigil.Markdown says a file ends" do
    resolved = %{
      path: "bike/x.md",
      normalized_from: nil,
      type: :reference,
      starts: nil,
      ends: nil
    }

    assert {:ok, plan} = Plan.build(:create, resolved, %{content: "# T\n\nbody\n\n\n"}, nil)
    assert String.ends_with?(plan.content, "body\n")
    refute String.ends_with?(plan.content, "\n\n")
  end
end
