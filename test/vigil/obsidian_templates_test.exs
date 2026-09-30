defmodule Vigil.ObsidianTemplatesTest do
  @moduledoc """
  The Obsidian templates `init_vault.sh` installs write notes vigil reads the
  way their author meant them.

  Three things are held here. The slug `_templates/_scripts/vigil_title.js`
  names a note by is a JavaScript copy of `Vigil.Slug.slugify/1`; the table in
  `test/fixtures/slug_examples.json` is checked against the Elixir here and
  against the JavaScript by `scripts/test/slug_js_test.mjs`, so the two cannot
  drift apart unnoticed. A note made from each template — its Templater
  expressions replaced by what Templater would put there — parses as the type
  the template names, and an event's timestamps carry the offset vigil
  requires. And a vault fresh from `init_vault.sh` gives the doctor nothing to
  warn about.
  """
  use ExUnit.Case, async: true

  alias Vigil.{Parser, Slug, VaultCheck}

  @scripts Path.expand("../../scripts", __DIR__)
  @templates Path.join(@scripts, "templates/obsidian/_templates")
  @examples Path.expand("../fixtures/slug_examples.json", __DIR__)

  describe "the shared slug table" do
    test "Vigil.Slug.slugify/1 answers every example" do
      examples = @examples |> File.read!() |> Jason.decode!()
      assert length(examples) > 20

      for %{"input" => input, "expected" => expected, "why" => why} <- examples do
        answer = if expected, do: {:ok, expected}, else: {:error, :empty}
        assert Slug.slugify(input) == answer, "#{why}: #{inspect(input)}"
      end
    end
  end

  describe "a note made from a template" do
    # 17:00 on a summer day in Berlin, the zone Templater's moment.js would
    # format in on the maintainer's machine.
    @now ~N[2026-07-10 17:00:00]
    @offset "+02:00"

    test "an event parses as an event, its timestamps with their offset" do
      content = instantiate("event.md", "Race day")

      assert content =~ "starts: 2026-07-10T17:00:00+02:00\n"
      assert content =~ "ends: 2026-07-10T18:00:00+02:00\n"

      assert {:ok, note} = Parser.parse("training/race-day.md", content)
      assert note.type == :event
      assert note.title == "Race day"
      assert DateTime.compare(note.starts, ~U[2026-07-10 15:00:00Z]) == :eq
      assert DateTime.compare(note.ends, ~U[2026-07-10 16:00:00Z]) == :eq
    end

    test "a decision parses as a decision with its four sections" do
      assert {:ok, note} =
               Parser.parse("gear/tubeless.md", instantiate("decision.md", "Tubeless"))

      assert note.type == :decision
      assert note.title == "Tubeless"

      assert Enum.map(note.chunks, & &1.heading) ==
               ["Context", "Decision", "Alternatives", "Consequences"]
    end

    test "a reference parses as a reference" do
      assert {:ok, note} = Parser.parse("gear/chain.md", instantiate("reference.md", "Chain"))
      assert note.type == :reference
      assert note.title == "Chain"
    end
  end

  test "a vault fresh from init_vault.sh gives the doctor nothing to warn about" do
    vault = Path.join(System.tmp_dir!(), "vigil_obsidian_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(vault) end)

    {output, status} =
      System.cmd("bash", [Path.join(@scripts, "init_vault.sh"), vault],
        env: [
          {"GIT_CONFIG_COUNT", "3"},
          {"GIT_CONFIG_KEY_0", "commit.gpgsign"},
          {"GIT_CONFIG_VALUE_0", "false"},
          {"GIT_CONFIG_KEY_1", "user.name"},
          {"GIT_CONFIG_VALUE_1", "obsidian templates test"},
          {"GIT_CONFIG_KEY_2", "user.email"},
          {"GIT_CONFIG_VALUE_2", "test@localhost"}
        ],
        stderr_to_stdout: true
      )

    assert status == 0, output
    assert File.regular?(Path.join(vault, "_templates/_scripts/vigil_title.js"))

    report = VaultCheck.run(vault)

    assert report.b7_ignored_files == [
             %{
               path: "Dashboard.md",
               reason: "root",
               severity: "info",
               message: "at the vault root, in no domain, so the server ignores this file"
             }
           ]

    for {check, findings} <- Map.drop(report, [:overview, :b3_chunk_diff, :b7_ignored_files]) do
      assert findings == [], "#{check}: #{inspect(findings)}"
    end
  end

  # The template as Templater leaves it: the script call gone (its line ends
  # in `-%>`, which takes the newline with it), the title in the H1, the
  # cursor marker empty, and every `tp.date.now` formatted.
  defp instantiate(template, title) do
    content =
      @templates
      |> Path.join(template)
      |> File.read!()
      |> String.replace(~r/^<%\*.*-%>\n/, "")
      |> String.replace("<% title %>", title)
      |> String.replace("<% tp.file.cursor() %>", "")
      |> String.replace(~r/<% tp\.date\.now\("([^"]+)"(?:, "PT(\d+)H")?\) %>/, &date_now/1)

    refute content =~ "<%"
    content
  end

  defp date_now(call) do
    [_call, format | hours] = Regex.run(~r/tp\.date\.now\("([^"]+)"(?:, "PT(\d+)H")?\)/, call)
    shift = hours |> List.first("0") |> String.to_integer()
    moment_format(NaiveDateTime.add(@now, shift * 3600), format)
  end

  # The moment.js tokens the templates use, and nothing else: a token this
  # does not know stays in the output and fails the parse.
  defp moment_format(time, format) do
    pad = &String.pad_leading(Integer.to_string(&1), &2, "0")

    Regex.replace(~r/YYYY|MM|DD|HH|mm|ss|Z/, format, fn
      "YYYY" -> pad.(time.year, 4)
      "MM" -> pad.(time.month, 2)
      "DD" -> pad.(time.day, 2)
      "HH" -> pad.(time.hour, 2)
      "mm" -> pad.(time.minute, 2)
      "ss" -> pad.(time.second, 2)
      "Z" -> @offset
    end)
  end
end
