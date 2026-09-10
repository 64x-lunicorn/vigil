defmodule Vigil.Vault.FactsTest do
  use ExUnit.Case, async: true

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
end
