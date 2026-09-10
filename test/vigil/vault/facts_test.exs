defmodule Vigil.Vault.FactsTest do
  use ExUnit.Case, async: true

  alias Vigil.{Index, Parser}
  alias Vigil.Vault.{AbsentFacts, Facts}

  # What a complete answer set looks like, as a keyword list, so a test can
  # take one question back out of it.
  defp every_fact do
    AbsentFacts.answering_nothing()
    |> Map.from_struct()
    |> Enum.to_list()
  end

  describe "new/1" do
    test "builds a Facts when every question is answered" do
      assert %Facts{} = Facts.new(every_fact())
    end

    test "a question left unanswered raises rather than answering permissively" do
      for {field, _answer} <- every_fact() do
        missing = Keyword.delete(every_fact(), field)

        assert_raise ArgumentError, ~r/#{field}/, fn -> Facts.new(missing) end
      end
    end

    test "a field the struct does not have raises" do
      assert_raise KeyError, fn ->
        Facts.new(Keyword.put(every_fact(), :find_nothing, fn -> nil end))
      end
    end
  end

  describe "Vigil.Vault.AbsentFacts" do
    test "answers nothing to every question" do
      facts = AbsentFacts.answering_nothing()

      refute facts.path_exists?.("bike/x.md")
      assert facts.read_note.("bike/x.md") == :error
      assert facts.find_similar.("terra", "bike", 25) == []
      assert facts.count_headings.("bike/x.md") == 0
      assert facts.find_backlinks.("bike/x.md") == []
      assert facts.find_chunk.("bike/x.md#h") == nil
      assert facts.find_section.("bike/x.md", "Gear") == nil
    end

    test "overrides replace an answer" do
      facts = AbsentFacts.answering_nothing(path_exists?: fn _ -> true end)

      assert facts.path_exists?.("bike/x.md")
    end
  end

  # The production adapter, decided against an in-memory index and no git.
  # Every question it answers over the index is reachable here; the two it
  # answers over the filesystem get a throwaway directory.
  describe "over_vault/3" do
    # An `event` needs its timestamps or the parser downgrades it
    # (Vigil.Vault.Frontmatter), and what a chunk's type ends up being is half
    # of what this describe block is about.
    @frontmatter %{
      reference: "type: reference",
      decision: "type: decision",
      event: "type: event\nstarts: 2026-01-01T10:00:00+01:00\nends: 2026-01-02T10:00:00+01:00"
    }

    defp note(path, title, type, body) do
      {:ok, file} = Parser.parse(path, "---\n#{@frontmatter[type]}\n---\n# #{title}\n\n#{body}\n")
      file
    end

    defp facts_over(notes, vault_overrides \\ [], now \\ ~U[2026-01-01 10:00:00Z]) do
      vault =
        Enum.into(vault_overrides, %{
          layout: AbsentFacts.layout(domains: ["gear"]),
          naming: %{}
        })

      Facts.over_vault(Index.build(notes), vault, now)
    end

    defp terra_speed,
      do: note("gear/terra-speed.md", "Terra Speed", :reference, "## Dimensions\n\nBody.")

    test "the plain answers are the vault's own" do
      facts =
        facts_over([],
          layout:
            AbsentFacts.layout(
              domains: ["gear", "training"],
              exclude: ["private"],
              project_dirs: ["vigil"]
            ),
          naming: %{"journal" => %{pattern: :date}}
        )

      assert facts.layout.domains == ["gear", "training"]
      assert facts.layout.exclude == ["private"]
      assert facts.layout.project_dirs == ["vigil"]
      assert facts.naming == %{"journal" => %{pattern: :date}}
    end

    # The claim Vigil.Vault.Policy's duplicate gate rests on: a hit reaching
    # Index.strength(:title) means the query names the note, and that reading
    # holds only for a search with no preferred type. A `prefer` hint has two
    # effects (Vigil.Index.strength/1), and the scores are asserted in full so
    # that either one fails this: it lifts a chunk of the preferred type above
    # zero without the query matching it anywhere, and it lifts a chunk the
    # query does match by the same amount again. Whichever type were preferred,
    # one of the three passes through here would see it.
    test "the similarity search carries no preferred type" do
      for type <- [:reference, :decision, :event] do
        facts =
          facts_over([
            terra_speed(),
            note("gear/rennrad.md", "Rennrad", type, "## Specs\n\nNothing of the sort."),
            note("gear/laufrad.md", "Laufrad", type, "## Specs\n\nOne terra mention.")
          ])

        hits = Map.new(facts.find_similar.("terra", "gear", 25), &{&1.id, &1.score})

        assert hits == %{
                 "gear/terra-speed.md#dimensions" => Index.strength(:title),
                 "gear/laufrad.md#specs" => Index.strength(:body_occurrence)
               }
      end
    end

    test "the similarity search honours the domain it is asked about" do
      facts =
        facts_over([
          terra_speed(),
          note("training/terra.md", "Terra", :reference, "## Plan\n\nBody.")
        ])

      assert [%{id: "gear/terra-speed.md#dimensions"}] = facts.find_similar.("terra", "gear", 25)
      assert [%{id: "training/terra.md#plan"}] = facts.find_similar.("terra", "training", 25)
    end

    test "the depth it is asked with is the search's limit" do
      facts =
        facts_over([
          terra_speed(),
          note("gear/terra-x.md", "Terra X", :reference, "## Specs\n\nBody.")
        ])

      assert length(facts.find_similar.("terra", "gear", 25)) == 2
      assert length(facts.find_similar.("terra", "gear", 1)) == 1
    end

    # The surface of the bug bd7e842 fixed: a clock read of its own, behind the
    # writer, can land in a different day than the response the write belongs
    # to.
    test "the write's date is the instant handed in, in that instant's own zone" do
      berlin = DateTime.shift_zone!(~U[2026-06-30 23:30:00Z], "Europe/Berlin")

      assert facts_over([], [], berlin).today == ~D[2026-07-01]
    end

    test "the write's date does not come from the machine clock" do
      # A day the machine cannot be on, so this says "not today" without
      # pinning a date the suite would eventually run on.
      not_today = DateTime.add(DateTime.utc_now(), 40, :day)

      assert facts_over([], [], not_today).today == DateTime.to_date(not_today)
    end

    test "the three index lookups reach the index" do
      facts =
        facts_over([
          note(
            "gear/terra-speed.md",
            "Terra Speed",
            :reference,
            "## Dimensions\n\nBody.\n\n## Weight\n\nMore."
          )
        ])

      assert facts.count_headings.("gear/terra-speed.md") == 2
      assert facts.count_headings.("gear/unknown.md") == 0

      assert %Index.Chunk{heading: "Weight"} = facts.find_chunk.("gear/terra-speed.md#weight")
      assert facts.find_chunk.("gear/terra-speed.md#nope") == nil

      assert %Index.Chunk{id: "gear/terra-speed.md#weight"} =
               facts.find_section.("gear/terra-speed.md", "Weight")

      assert facts.find_section.("gear/terra-speed.md", "Nope") == nil
    end

    test "backlinks reach the index" do
      facts =
        facts_over([
          terra_speed(),
          note("gear/rennrad.md", "Rennrad", :reference, "## Specs\n\nSee [[terra-speed]].")
        ])

      assert facts.find_backlinks.("gear/terra-speed.md") == ["gear/rennrad.md#specs"]
      assert facts.find_backlinks.("gear/rennrad.md") == []
    end

    test "the two filesystem questions are asked relative to the vault" do
      tmp = Path.join(System.tmp_dir!(), "vigil_facts_#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(tmp, "gear"))
      File.write!(Path.join(tmp, "gear/terra-speed.md"), "# Terra Speed\n")
      on_exit(fn -> File.rm_rf(tmp) end)

      facts = facts_over([], layout: AbsentFacts.layout(vault_path: tmp, domains: ["gear"]))

      assert facts.path_exists?.("gear/terra-speed.md")
      refute facts.path_exists?.("gear/nope.md")
      assert {:ok, "# Terra Speed\n"} = facts.read_note.("gear/terra-speed.md")
      assert {:error, :enoent} = facts.read_note.("gear/nope.md")
    end
  end
end
