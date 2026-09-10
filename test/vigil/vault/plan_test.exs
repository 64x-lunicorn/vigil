defmodule Vigil.Vault.PlanTest do
  use ExUnit.Case, async: true

  alias Vigil.Index
  alias Vigil.Vault.{AbsentFacts, Decision, Plan, Policy}

  # No vault, no git, no GenServer: a plan is a value derived from a decision
  # and a string.
  #
  # The decisions come from `Vigil.Vault.Policy` rather than being written out
  # here, because the agreement between the two modules is the thing worth
  # testing and hand-written decisions cannot fail when it breaks. Both were
  # made pure so a write could be decided and shaped without a process; the
  # seam between them should not have to be crossed through the one they were
  # extracted from. `Vigil.Vault.EditTest` does the same for the other axis.
  #
  # The integration coverage in `Vigil.StoreTest` stays. The point is not to
  # delete it, but to stop it being the only place a rename can be caught.

  @path "bike/terra-speed.md"

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

  # The vault the policy decides against: one domain, one note in it, and
  # nothing else. Every other question answers "nothing there" until a test
  # names it (see Vigil.Vault.AbsentFacts).
  defp facts(overrides) do
    AbsentFacts.answering_nothing(
      [
        vault_path: "/vault",
        domains: ["bike"],
        path_exists?: fn path -> path == @path end,
        read_note: fn _path -> {:ok, @note} end
      ] ++ overrides
    )
  end

  defp decide(op, request, overrides \\ []) do
    assert {:ok, decision} = Policy.check(op, request, facts(overrides))
    decision
  end

  # The chunk the index hands back for `#fueling`, as Vigil.Vault.Edit needs
  # it. Line numbers are the parser's: the body ends at its last non-blank
  # line.
  defp fueling do
    %Index.Chunk{
      id: "#{@path}#fueling",
      path: @path,
      heading: "Fueling",
      heading_line: 6,
      body_end_line: 7
    }
  end

  # Every content-shaped plan writes; the bytes are what differ.
  defp written(%Plan{action: {:write, _path, content}}), do: content

  describe "create" do
    test "frontmatter is built in front of the content, and the message quotes the H1" do
      request = %{path: "bike/new.md", type: "reference", content: "# New\n\nbody"}

      assert {:ok, plan} = Plan.build(:create, decide(:create, request), request, nil)

      assert plan.action == {:write, "bike/new.md", "---\ntype: reference\n---\n# New\n\nbody\n"}
      assert plan.message == "create: bike/new.md — # New"
      assert plan.report == %{}
    end

    test "an event carries starts and ends in the frontmatter" do
      request = %{
        path: "bike/race.md",
        type: "event",
        starts: "2026-05-01T08:00:00Z",
        ends: "2026-05-01T18:00:00Z",
        content: "# Race\n"
      }

      assert {:ok, plan} = Plan.build(:create, decide(:create, request), request, nil)

      assert written(plan) =~ "starts: 2026-05-01T08:00:00Z"
      assert written(plan) =~ "ends: 2026-05-01T18:00:00Z"
    end

    test "a normalized path is reported back, so the caller learns where the note landed" do
      request = %{path: "Bike/New Note!!.md", type: "reference", content: "# T\n"}

      assert {:ok, plan} = Plan.build(:create, decide(:create, request), request, nil)

      assert plan.action == {:write, "bike/new-note.md", "---\ntype: reference\n---\n# T\n"}
      assert plan.report == %{path_normalized_from: "Bike/New Note!!.md"}
    end

    test "the commit subject stays a subject" do
      request = %{
        path: "bike/x.md",
        type: "reference",
        content: "# #{String.duplicate("x", 200)}"
      }

      assert {:ok, plan} = Plan.build(:create, decide(:create, request), request, nil)
      assert String.length(plan.message) == String.length("create: bike/x.md — ") + 50
    end
  end

  describe "append" do
    test "at the end of the file" do
      request = %{path: @path, content: "Extra."}

      assert {:ok, plan} = Plan.build(:append, decide(:append, request), request, @note)

      assert String.ends_with?(written(plan), "Gearing body.\n\nExtra.\n")
      assert plan.message == "append: #{@path} — Extra."
    end

    test "into an existing section" do
      request = %{path: @path, heading: "Fueling", content: "More."}
      decision = decide(:append, request, find_section: fn _path, _heading -> fueling() end)

      assert {:ok, plan} = Plan.build(:append, decision, request, @note)

      assert written(plan) =~ "Old body.\nMore.\n\n## Gearing"
    end

    test "in a new section at the end of the file" do
      request = %{path: @path, heading: "Tyres", content: "Tubeless."}

      assert {:ok, plan} = Plan.build(:append, decide(:append, request), request, @note)

      assert String.ends_with?(written(plan), "\n## Tyres\nTubeless.\n")
    end
  end

  describe "replace_section and delete_section" do
    defp section_decision(op, request) do
      decide(op, request, find_chunk: fn _id -> fueling() end)
    end

    test "replace swaps the body and names the chunk in the message" do
      request = %{id: "#{@path}#fueling", content: "New body."}
      decision = section_decision(:replace_section, request)

      assert {:ok, plan} = Plan.build(:replace_section, decision, request, @note)

      assert written(plan) =~ "## Fueling\nNew body.\n\n## Gearing"
      refute written(plan) =~ "Old body."
      assert plan.message == "replace_section: #{@path}#fueling"
    end

    test "delete takes the heading with the body" do
      request = %{id: "#{@path}#fueling"}
      decision = section_decision(:delete_section, request)

      assert {:ok, plan} = Plan.build(:delete_section, decision, request, @note)

      refute written(plan) =~ "Fueling"
      assert written(plan) =~ "## Gearing"
      assert plan.message == "delete_section: #{@path}#fueling"
    end
  end

  describe "rewrite_note" do
    test "keeps the frontmatter and replaces the body" do
      request = %{path: @path, content: "# T\n\nAll new."}

      assert {:ok, plan} =
               Plan.build(:rewrite_note, decide(:rewrite_note, request), request, @note)

      assert written(plan) == "---\ntype: reference\n---\n# T\n\nAll new.\n"
      assert plan.message == "rewrite_note: #{@path}"
    end

    test "a note whose frontmatter cannot be split is an error" do
      request = %{path: @path, content: "# T"}

      assert {:error, message} =
               Plan.build(
                 :rewrite_note,
                 decide(:rewrite_note, request),
                 request,
                 "# No frontmatter"
               )

      assert is_binary(message)
    end
  end

  describe "update_frontmatter" do
    test "replaces the frontmatter and leaves the body alone" do
      request = %{path: @path, type: "decision"}
      decision = decide(:update_frontmatter, request)

      assert {:ok, plan} = Plan.build(:update_frontmatter, decision, request, @note)

      assert String.starts_with?(written(plan), "---\ntype: decision\n---\n")
      assert written(plan) =~ "## Fueling\nOld body."
      assert plan.message == "update_frontmatter: #{@path}"
    end

    test "an event gains its timestamps" do
      request = %{
        path: @path,
        type: "event",
        starts: "2026-05-01T08:00:00Z",
        ends: "2026-05-01T18:00:00Z"
      }

      decision = decide(:update_frontmatter, request)

      assert {:ok, plan} = Plan.build(:update_frontmatter, decision, request, @note)

      assert written(plan) =~ "starts: 2026-05-01T08:00:00Z"
      assert written(plan) =~ "ends: 2026-05-01T18:00:00Z"
    end

    test "a note whose frontmatter cannot be split is an error" do
      request = %{path: @path, type: "reference"}
      decision = decide(:update_frontmatter, request)

      assert {:error, message} =
               Plan.build(:update_frontmatter, decision, request, "# No frontmatter")

      assert is_binary(message)
    end
  end

  test "every plan ends the file the way Vigil.Markdown says a file ends" do
    request = %{path: "bike/x.md", type: "reference", content: "# T\n\nbody\n\n\n"}

    assert {:ok, plan} = Plan.build(:create, decide(:create, request), request, nil)
    assert String.ends_with?(written(plan), "body\n")
    refute String.ends_with?(written(plan), "\n\n")
  end

  describe "the git-level operations" do
    test "delete_note plans a removal and reports the backlinks it is about to break" do
      request = %{path: @path, confirm: true}

      decision =
        decide(:delete_note, request, find_backlinks: fn _path -> ["bike/via-carolina.md"] end)

      assert {:ok, plan} = Plan.build(:delete_note, decision, request, nil)

      assert plan.action == {:delete, @path}
      assert plan.message == "delete: #{@path}"
      assert plan.report == %{broken_backlinks: ["bike/via-carolina.md"]}
    end

    test "move_note plans a move; which references it broke is the executor's to say" do
      request = %{from: @path, to: "bike/terra-40c.md", confirm: true}

      assert {:ok, plan} = Plan.build(:move_note, decide(:move_note, request), request, nil)

      assert plan.action == {:move, @path, "bike/terra-40c.md"}
      assert plan.message == "move: #{@path} -> bike/terra-40c.md"
      assert plan.report == %{}
    end

    test "neither reads the note's content" do
      delete = %{path: @path, confirm: true}
      move = %{from: @path, to: "bike/b.md", confirm: true}

      assert {:ok, _} = Plan.build(:delete_note, decide(:delete_note, delete), delete, nil)
      assert {:ok, _} = Plan.build(:move_note, decide(:move_note, move), move, nil)
    end
  end

  # The policy resolves a section through the index and never hands over a
  # chunk that is nil, so these decisions cannot come from it. Vigil.Vault.Edit
  # checks anyway — a failed write must not take the single writer down — and
  # this is where that defence is exercised.
  describe "a section that is gone" do
    test "is an error from every operation that splices one, not a raise" do
      append = %Decision.Append{path: @path, target: {:section, nil}}
      section = %Decision.Section{path: @path, chunk: nil}

      assert {:error, "no such section"} =
               Plan.build(:append, append, %{content: "More."}, @note)

      assert {:error, "no such section"} =
               Plan.build(:replace_section, section, %{content: "x"}, @note)

      assert {:error, "no such section"} = Plan.build(:delete_section, section, %{}, @note)
    end
  end
end
