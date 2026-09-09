defmodule Vigil.Vault.RulesTest do
  use ExUnit.Case, async: true

  alias Vigil.Vault.Rules

  describe "sentence_heading?/1" do
    test "a heading longer than the threshold reads as a sentence" do
      refute Rules.sentence_heading?(String.duplicate("a", 60))
      assert Rules.sentence_heading?(String.duplicate("a", 61))
    end

    test "trailing sentence punctuation reads as a sentence at any length" do
      assert Rules.sentence_heading?("Why.")
      assert Rules.sentence_heading?("Why!")
      assert Rules.sentence_heading?("Why?")
      refute Rules.sentence_heading?("Why")
    end
  end

  describe "slug_changes/1" do
    test "reports every H2-H4 heading whose slug would change" do
      content = "# Title\n## Café Overview\n## already-clean\n"

      assert [%{text: "Café Overview", old: old, new: new}] = Rules.slug_changes(content)
      assert old != new
      assert new == "cafe-overview"
    end

    test "H1 is not a heading and never appears in the diff" do
      assert Rules.slug_changes("# Café Title\n\nbody\n") == []
    end

    test "a heading with no derivable slug reports new: nil" do
      assert [%{text: "———", new: nil}] = Rules.slug_changes("## ———\n")
    end
  end
end
