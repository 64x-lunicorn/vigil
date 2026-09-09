defmodule Vigil.Vault.DomainsTest do
  use ExUnit.Case, async: true

  alias Vigil.Vault.Domains
  alias Vigil.Vault.Domains.Naming

  describe "parse/1 — entry shapes" do
    test "a bare description string declares the domain and carries no naming rule" do
      assert {%{"bike" => nil}, []} = Domains.parse(~s(bike: "Gear: bike, components"\n))
    end

    test "a map entry without a naming block declares the domain and carries no rule" do
      yaml = """
      journal:
        description: "Chronological"
      """

      assert {%{"journal" => nil}, []} = Domains.parse(yaml)
    end

    test "an entry that is neither a string nor a map is still a declared domain" do
      assert {%{"odd" => nil}, []} = Domains.parse("odd:\n  - a\n  - b\n")
    end

    test "every declared domain appears, whether or not it has a rule" do
      yaml = """
      bike: "Gear"
      journal:
        naming:
          pattern: '^\\d{4}\\.md$'
      """

      {domains, []} = Domains.parse(yaml)
      assert Map.keys(domains) |> Enum.sort() == ["bike", "journal"]
      assert domains["bike"] == nil
      assert %Naming{} = domains["journal"]
    end
  end

  describe "parse/1 — naming rules" do
    test "a full naming block parses into a Naming struct" do
      yaml = """
      journal:
        naming:
          pattern: '^\\d{4}-\\d{2}-\\d{2}\\.md$'
          scope: relpath
          suggestion: date
          hint: "Journal notes are named YYYY-MM-DD.md"
          max_depth: 2
      """

      assert {%{"journal" => naming}, []} = Domains.parse(yaml)

      assert %Naming{
               scope: :relpath,
               suggestion: :date,
               hint: "Journal notes are named YYYY-MM-DD.md",
               max_depth: 2
             } = naming

      assert Regex.match?(naming.pattern, "2026-09-09.md")
      refute Regex.match?(naming.pattern, "notes.md")
    end

    test "scope defaults to :filename and suggestion to :slug" do
      yaml = """
      bike:
        naming:
          pattern: '.*'
      """

      assert {%{"bike" => %Naming{scope: :filename, suggestion: :slug}}, []} = Domains.parse(yaml)
    end

    test "an unrecognized scope or suggestion falls back to the default" do
      yaml = """
      bike:
        naming:
          pattern: '.*'
          scope: sideways
          suggestion: telepathy
      """

      assert {%{"bike" => %Naming{scope: :filename, suggestion: :slug}}, []} = Domains.parse(yaml)
    end

    test "hint defaults to an empty string" do
      yaml = """
      bike:
        naming:
          pattern: '.*'
      """

      assert {%{"bike" => %Naming{hint: ""}}, []} = Domains.parse(yaml)
    end

    test "max_depth is nil when absent" do
      yaml = """
      bike:
        naming:
          pattern: '.*'
      """

      assert {%{"bike" => %Naming{max_depth: nil}}, []} = Domains.parse(yaml)
    end

    test "a naming block without a pattern constrains nothing, so it is not a rule" do
      yaml = """
      bike:
        naming:
          hint: "no pattern here"
      """

      assert {%{"bike" => nil}, []} = Domains.parse(yaml)
    end

    test "German key aliases are accepted for hint and suggestion" do
      yaml = """
      journal:
        naming:
          pattern: '.*'
          hinweis: "Hinweistext"
          vorschlag: date
      """

      assert {%{"journal" => %Naming{hint: "Hinweistext", suggestion: :date}}, []} =
               Domains.parse(yaml)
    end
  end

  describe "parse/1 — a broken file degrades, never blocks" do
    test "an invalid pattern drops that domain's rule and warns, leaving the domain declared" do
      yaml = """
      journal:
        naming:
          pattern: '^([unclosed'
      """

      assert {%{"journal" => nil}, [{:invalid_pattern, "journal", _reason}]} = Domains.parse(yaml)
    end

    test "one domain's invalid pattern does not affect another's" do
      yaml = """
      bike:
        naming:
          pattern: '^([unclosed'
      journal:
        naming:
          pattern: '^\\d{4}\\.md$'
      """

      {domains, warnings} = Domains.parse(yaml)

      assert domains["bike"] == nil
      assert %Naming{} = domains["journal"]
      assert [{:invalid_pattern, "bike", _}] = warnings
    end

    test "a non-string pattern warns rather than raising" do
      assert {%{"bike" => nil}, [{:invalid_pattern, "bike", _}]} =
               Domains.parse("bike:\n  naming:\n    pattern: 42\n")
    end

    test "unparsable YAML yields no domains and one warning" do
      assert {%{}, [{:unparsable, _reason}]} =
               Domains.parse("bike: Gear\n  journal: Chronology\n")
    end

    test "a document that is not a mapping yields no domains and one warning" do
      assert {%{}, [{:unparsable, {:not_a_mapping, _}}]} = Domains.parse("- just\n- a list\n")
    end

    test "an empty file is a vault that has not described itself yet, not an error" do
      assert {%{}, []} = Domains.parse("")
    end
  end

  describe "mismatches/2" do
    test "reports a key without a matching directory" do
      assert Domains.mismatches(%{"phantom" => nil}, ["bike"]) == [
               {:key_without_directory, "phantom"},
               {:directory_without_key, "bike"}
             ]
    end

    test "reports a directory without an entry" do
      assert Domains.mismatches(%{"bike" => nil}, ["bike", "garden"]) == [
               {:directory_without_key, "garden"}
             ]
    end

    test "says nothing when the file and the vault agree" do
      assert Domains.mismatches(%{"bike" => nil, "journal" => nil}, ["bike", "journal"]) == []
    end

    test "a domain carrying a naming rule counts as declared" do
      {domains, []} = Domains.parse("bike:\n  naming:\n    pattern: '.*'\n")
      assert Domains.mismatches(domains, ["bike"]) == []
    end
  end

  describe "naming_rules/1" do
    test "keeps only the domains that carry a rule" do
      yaml = """
      bike: "Gear"
      journal:
        naming:
          pattern: '^\\d{4}\\.md$'
      """

      {domains, []} = Domains.parse(yaml)

      assert %{"journal" => %Naming{}} = Domains.naming_rules(domains)
      refute Map.has_key?(Domains.naming_rules(domains), "bike")
    end

    test "is empty when no domain carries a rule" do
      assert Domains.naming_rules(%{"bike" => nil}) == %{}
    end
  end

  describe "format/1" do
    test "renders each warning for the log" do
      assert Domains.format({:key_without_directory, "phantom"}) =~
               "key 'phantom' has no matching directory"

      assert Domains.format({:directory_without_key, "garden"}) =~
               "domain 'garden' has no entry"

      assert Domains.format({:invalid_pattern, "journal", :bad}) =~
               "naming.pattern for 'journal' is not a valid regex"

      assert Domains.format({:unparsable, :bad}) =~ "_domains.yml is not parsable"
    end
  end
end
