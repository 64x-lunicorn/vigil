defmodule Vigil.Vault.PolicyTest do
  use ExUnit.Case, async: true

  alias Vigil.Vault.{Facts, Policy}

  defp facts(overrides \\ []) do
    struct!(
      %Facts{
        vault_path: "/vault",
        domains: ["bike", "journal", "projects", "training"],
        exclude: ["work"],
        project_dirs: ["vigil"],
        today: ~D[2026-09-09]
      },
      overrides
    )
  end

  defp create(path, opts \\ []) do
    Policy.check(
      :create,
      Enum.into(opts, %{path: path, type: "reference", content: "# Title\n\nbody"}),
      facts(Keyword.get(opts, :facts, []))
    )
  end

  describe "path rules on :create" do
    test "traversal, absolute and backslash paths are rejected" do
      for bad <- ["../../etc/passwd", "/etc/passwd", "bike/../../x.md", "bike\\x.md"] do
        assert {:error, "Invalid path"} = create(bad)
      end
    end

    test "a NUL byte is rejected" do
      assert {:error, "Invalid path"} = create("bike/x\0.md")
    end

    test "dot- and underscore-prefixed segments are rejected at every level" do
      assert {:error, "Invalid path"} = create("projects/.evil/x.md")
      assert {:error, "Invalid path"} = create("projects/_evil/x.md")
      assert {:error, "Invalid path"} = create(".hidden/x.md")
    end

    test "skills/ is not writable as a note" do
      assert {:error, "Invalid path"} = create("skills/x.md")
    end

    test "an excluded domain is not writable" do
      assert {:error, "Invalid path"} = create("work/x.md")
    end

    test "an unknown domain names the ones that exist" do
      assert {:error, msg} = create("nosuch/x.md")
      assert msg =~ "Available domains: bike, journal, projects, training"
    end

    test "notes nest one level deep, except under projects" do
      assert {:ok, _} = create("bike/x.md")
      assert {:error, "Invalid path"} = create("bike/deeper/x.md")
      assert {:ok, _} = create("projects/vigil/x.md")
      assert {:error, "Invalid path"} = create("projects/vigil/deeper/x.md")
    end

    test "a non-markdown extension is rejected" do
      assert {:error, "Invalid path"} = create("bike/x.txt")
    end
  end

  describe "project directories on :create" do
    test "an unknown project directory is rejected without create_dirs" do
      assert {:error, msg} = create("projects/newthing/x.md")
      assert msg =~ "Project directory does not exist: newthing"
    end

    test "create_dirs authorises the directory but the policy does not create it" do
      assert {:ok, %{create_project_dir: "newthing"}} =
               create("projects/newthing/x.md", create_dirs: true)
    end

    test "an existing project directory needs no creation" do
      assert {:ok, %{create_project_dir: nil}} = create("projects/vigil/x.md")
    end
  end

  describe "normalization on :create" do
    test "an unclean path is slugified and the original is reported" do
      assert {:ok, %{path: "bike/cafe-overview.md", normalized_from: "bike/Café Overview!!.md"}} =
               create("bike/Café Overview!!.md")
    end

    test "an already-canonical path reports no normalization" do
      assert {:ok, %{path: "bike/clean.md", normalized_from: nil}} = create("bike/clean.md")
    end

    test "a path with no derivable filename is rejected" do
      assert {:error, msg} = create("bike/———.md")
      assert msg =~ "No valid filename can be derived"
    end
  end

  describe "content and type rules on :create" do
    test "content must start with an H1" do
      assert {:error, msg} = create("bike/x.md", content: "no heading here")
      assert msg =~ "must start with an H1"
    end

    test "content must not carry its own frontmatter" do
      assert {:error, msg} = create("bike/x.md", content: "---\ntype: x\n---\n# T")
      assert msg =~ "must not contain its own frontmatter"
    end

    test "an unknown type is rejected" do
      assert {:error, "Invalid type"} = create("bike/x.md", type: "nonsense")
    end

    test "an event needs both starts and ends" do
      assert {:error, msg} = create("bike/x.md", type: "event")
      assert msg =~ "starts/ends"
    end

    test "a non-event may not carry starts or ends" do
      assert {:error, msg} = create("bike/x.md", starts: "2026-09-09T10:00:00+02:00")
      assert msg =~ "nur bei type: event"
    end

    test "event timestamps must be ISO8601 with an offset" do
      assert {:error, msg} =
               create("bike/x.md", type: "event", starts: "yesterday", ends: "tomorrow")

      assert msg =~ "ISO8601"
    end

    test "a valid event yields parsed timestamps" do
      assert {:ok, %{type: :event, starts: %DateTime{}, ends: %DateTime{}}} =
               create("bike/x.md",
                 type: "event",
                 starts: "2026-09-09T10:00:00+02:00",
                 ends: "2026-09-09T12:00:00+02:00"
               )
    end
  end

  describe "existence rules" do
    test ":create refuses to overwrite" do
      f = facts(path_exists?: fn p -> p == "bike/taken.md" end)

      assert {:error, msg} =
               Policy.check(
                 :create,
                 %{path: "bike/taken.md", type: "reference", content: "# T\nx"},
                 f
               )

      assert msg =~ "File already exists"
    end

    test ":append requires the file to exist" do
      assert {:error, msg} = Policy.check(:append, %{path: "bike/ghost.md"}, facts())
      assert msg =~ "File not found"
    end
  end

  describe "the writable-path rules apply to every write, not just create" do
    # Before Vigil.Vault.Policy these four paths checked only traversal and
    # reserved segments, so a caller could append to a skill or overwrite a
    # note in an excluded domain, and the write was then indexed as a note.
    setup do
      %{f: facts(path_exists?: fn _ -> true end)}
    end

    test "append cannot reach into skills/ or an excluded domain", %{f: f} do
      assert {:error, "Invalid path"} = Policy.check(:append, %{path: "skills/tdd.md"}, f)
      assert {:error, "Invalid path"} = Policy.check(:append, %{path: "work/secret.md"}, f)
    end

    test "rewrite_note cannot reach into skills/ or an excluded domain", %{f: f} do
      req = %{content: "# T\n\nx", confirm: false}

      assert {:error, "Invalid path"} =
               Policy.check(:rewrite_note, Map.put(req, :path, "skills/tdd.md"), f)

      assert {:error, "Invalid path"} =
               Policy.check(:rewrite_note, Map.put(req, :path, "work/secret.md"), f)
    end

    test "update_frontmatter cannot reach into skills/ or an excluded domain", %{f: f} do
      req = %{type: "reference"}

      assert {:error, "Invalid path"} =
               Policy.check(:update_frontmatter, Map.put(req, :path, "skills/tdd.md"), f)

      assert {:error, "Invalid path"} =
               Policy.check(:update_frontmatter, Map.put(req, :path, "work/secret.md"), f)
    end

    test "delete_note cannot reach into skills/ or an excluded domain", %{f: f} do
      req = %{confirm: true}

      assert {:error, "Invalid path"} =
               Policy.check(:delete_note, Map.put(req, :path, "skills/tdd.md"), f)

      assert {:error, "Invalid path"} =
               Policy.check(:delete_note, Map.put(req, :path, "work/secret.md"), f)
    end
  end

  describe "confirm gates" do
    test "delete_note without confirm names the backlinks" do
      f =
        facts(
          path_exists?: fn _ -> true end,
          find_backlinks: fn _ -> ["bike/a.md#x", "bike/b.md#y"] end
        )

      assert {:error, msg} = Policy.check(:delete_note, %{path: "bike/x.md", confirm: false}, f)
      assert msg =~ "Destructive operation"
      assert msg =~ "2 incoming references"
      assert msg =~ "bike/a.md#x"
    end

    test "delete_note with confirm passes" do
      f = facts(path_exists?: fn _ -> true end)

      assert {:ok, %{path: "bike/x.md"}} =
               Policy.check(:delete_note, %{path: "bike/x.md", confirm: true}, f)
    end

    test "move_note requires confirm" do
      f = facts(path_exists?: fn p -> p == "bike/a.md" end)

      assert {:error, msg} =
               Policy.check(:move_note, %{from: "bike/a.md", to: "bike/b.md", confirm: false}, f)

      assert msg =~ "Destructive operation"
    end
  end

  describe "rewrite_note shrink threshold" do
    test "removing more than half the headings requires confirm" do
      f = facts(path_exists?: fn _ -> true end, count_headings: fn _ -> 10 end)
      req = %{path: "bike/x.md", content: "# T\n\n## One\n## Two\n", confirm: false}

      assert {:error, msg} = Policy.check(:rewrite_note, req, f)
      assert msg =~ "removes 8 of 10 headings"
    end

    test "a modest shrink goes through without confirm" do
      f = facts(path_exists?: fn _ -> true end, count_headings: fn _ -> 10 end)

      req = %{
        path: "bike/x.md",
        content: "# T\n\n## 1\n## 2\n## 3\n## 4\n## 5\n## 6\n",
        confirm: false
      }

      assert {:ok, _} = Policy.check(:rewrite_note, req, f)
    end
  end

  describe "replace_section" do
    test "the id must carry a fragment" do
      assert {:error, msg} =
               Policy.check(:replace_section, %{id: "bike/x.md", content: "text"}, facts())

      assert msg =~ "must contain a fragment"
    end

    test "replacement content may not introduce headings" do
      f = facts(find_chunk: fn _ -> %{heading: "S", path: "bike/x.md"} end)

      assert {:error, msg} =
               Policy.check(:replace_section, %{id: "bike/x.md#s", content: "## Nope"}, f)

      assert msg =~ "must not contain headings"
    end
  end

  describe "duplicate detection on :create" do
    test "a strong match in the same domain is reported unless forced" do
      f =
        facts(find_similar: fn _q, _d -> [%{id: "bike/terra-speed.md", score: 15}] end)

      assert {:error, msg} =
               Policy.check(
                 :create,
                 %{path: "bike/terra-speed-notes.md", type: "reference", content: "# T\nx"},
                 f
               )

      assert msg =~ "Possible duplicates found: bike/terra-speed.md"

      assert {:ok, _} =
               Policy.check(
                 :create,
                 %{
                   path: "bike/terra-speed-notes.md",
                   type: "reference",
                   content: "# T\nx",
                   force: true
                 },
                 f
               )
    end

    test "a weak match is not a duplicate" do
      f = facts(find_similar: fn _q, _d -> [%{id: "bike/other.md", score: 3}] end)

      assert {:ok, _} =
               Policy.check(
                 :create,
                 %{path: "bike/terra-speed-notes.md", type: "reference", content: "# T\nx"},
                 f
               )
    end

    test "notes inside the same project folder are not duplicates of each other" do
      f =
        facts(
          find_similar: fn _q, _d -> [%{id: "projects/vigil/vigil-ranking.md", score: 20}] end
        )

      assert {:ok, _} =
               Policy.check(
                 :create,
                 %{path: "projects/vigil/vigil-scoring.md", type: "reference", content: "# T\nx"},
                 f
               )
    end
  end

  describe "naming conventions" do
    test "a filename that does not match the domain pattern is rejected with a suggestion" do
      f =
        facts(
          naming: %{
            "journal" => %{
              pattern: ~r/^\d{4}-\d{2}-\d{2}\.md$/,
              scope: :filename,
              hint: "journal notes are named by date",
              suggestion: :date,
              max_depth: nil
            }
          }
        )

      assert {:error, msg} =
               Policy.check(
                 :create,
                 %{path: "journal/ride.md", type: "reference", content: "# Ride\nx"},
                 f
               )

      assert msg =~ "does not match the schema for domain journal"
      assert msg =~ "journal notes are named by date"
      assert msg =~ "Suggestion: journal/2026-09-09.md"
    end

    test "a slug suggestion is derived from the content H1" do
      f =
        facts(
          naming: %{
            "bike" => %{
              pattern: ~r/^never-matches$/,
              scope: :filename,
              hint: "use a slug",
              suggestion: :slug,
              max_depth: nil
            }
          }
        )

      assert {:error, msg} =
               Policy.check(
                 :create,
                 %{path: "bike/x.md", type: "reference", content: "# Café Overview\nx"},
                 f
               )

      assert msg =~ "Suggestion: bike/cafe-overview.md"
    end

    test "max_depth limits nesting inside a domain" do
      f =
        facts(
          naming: %{
            "projects" => %{
              pattern: ~r/.*/,
              scope: :relpath,
              hint: "",
              suggestion: :slug,
              max_depth: 1
            }
          }
        )

      assert {:error, msg} =
               Policy.check(
                 :create,
                 %{path: "projects/vigil/x.md", type: "reference", content: "# T\nx"},
                 f
               )

      assert msg =~ "allows at most 1 nesting level"
    end
  end

  describe "safe_path/1" do
    test "the read paths get the traversal rule without the write rules" do
      assert Policy.safe_path("bike/x.md") == :ok
      assert Policy.safe_path("work/secret.md") == :ok
      assert Policy.safe_path("skills/tdd.md") == :ok
      assert Policy.safe_path("../../etc/passwd") == {:error, "Invalid path"}
      assert Policy.safe_path("/etc/passwd") == {:error, "Invalid path"}
      assert Policy.safe_path(".hidden/x.md") == {:error, "Invalid path"}
    end
  end

  describe "section ops resolve through the index, not the filesystem" do
    test "an id without a fragment is refused before anything else" do
      assert {:error, msg} =
               Policy.check(:replace_section, %{id: "bike/x.md", content: "text"}, facts())

      assert msg =~ "must contain a fragment"
    end

    test "an unknown section is reported as unknown, not as bad content" do
      # Ordering regression: the chunk must be resolved before the replacement
      # content is judged, or a bad id gets reported as a content problem.
      assert {:error, "Not found: bike/x.md#nope"} =
               Policy.check(:replace_section, %{id: "bike/x.md#nope", content: "## H"}, facts())
    end

    test "a section without a heading cannot be replaced or deleted" do
      f = facts(find_chunk: fn _ -> %{heading: nil, path: "bike/x.md"} end)

      assert {:error, msg} =
               Policy.check(:replace_section, %{id: "bike/x.md#pre", content: "text"}, f)

      assert msg == "A section without a heading cannot be replaced: bike/x.md#pre"

      assert {:error, msg} = Policy.check(:delete_section, %{id: "bike/x.md#pre"}, f)
      assert msg == "A section without a heading cannot be deleted: bike/x.md#pre"
    end

    test "content rules apply once the section is known" do
      f = facts(find_chunk: fn _ -> %{heading: "Fueling", path: "bike/x.md"} end)

      assert {:error, msg} =
               Policy.check(:replace_section, %{id: "bike/x.md#fueling", content: "## Nope"}, f)

      assert msg =~ "must not contain headings"

      assert {:ok, %{path: "bike/x.md"}} =
               Policy.check(:replace_section, %{id: "bike/x.md#fueling", content: "text"}, f)
    end

    test "the writable-path rules still apply to a section id" do
      f = facts(find_chunk: fn _ -> %{heading: "H", path: "bike/x.md"} end)
      assert {:error, "Invalid path"} = Policy.check(:delete_section, %{id: "skills/tdd.md#h"}, f)
      assert {:error, "Invalid path"} = Policy.check(:delete_section, %{id: "work/x.md#h"}, f)
    end
  end

  describe "move_note cannot launder a note across the boundary" do
    test "a note cannot be moved out of skills/ or an excluded domain" do
      f = facts(path_exists?: fn _ -> true end)

      assert {:error, "Invalid path"} =
               Policy.check(
                 :move_note,
                 %{from: "skills/tdd.md", to: "bike/tdd.md", confirm: true},
                 f
               )

      assert {:error, "Invalid path"} =
               Policy.check(
                 :move_note,
                 %{from: "work/secret.md", to: "bike/s.md", confirm: true},
                 f
               )
    end

    test "a note cannot be moved into skills/ or an excluded domain" do
      f = facts(path_exists?: fn p -> p == "bike/a.md" end)

      assert {:error, "Invalid path"} =
               Policy.check(:move_note, %{from: "bike/a.md", to: "skills/a.md", confirm: true}, f)

      assert {:error, "Invalid path"} =
               Policy.check(:move_note, %{from: "bike/a.md", to: "work/a.md", confirm: true}, f)
    end

    test "an ordinary move is allowed" do
      f = facts(path_exists?: fn p -> p == "bike/a.md" end)

      assert {:ok, %{from: "bike/a.md", to: "training/b.md"}} =
               Policy.check(
                 :move_note,
                 %{from: "bike/a.md", to: "training/b.md", confirm: true},
                 f
               )
    end
  end
end
