defmodule Vigil.MarkdownTest do
  use ExUnit.Case, async: true

  alias Vigil.Markdown

  describe "split_lines/1" do
    test "drops exactly one trailing empty line" do
      assert Markdown.split_lines("a\nb\n") == ["a", "b"]
      assert Markdown.split_lines("a\nb") == ["a", "b"]
      assert Markdown.split_lines("a\nb\n\n") == ["a", "b", ""]
    end

    test "an empty string yields no lines" do
      assert Markdown.split_lines("") == []
    end
  end

  describe "heading/1" do
    test "H2 through H4 are headings, with rank and trimmed text" do
      assert Markdown.heading("## Fueling") == {2, "Fueling"}
      assert Markdown.heading("### Deep  ") == {3, "Deep"}
      assert Markdown.heading("#### Deepest") == {4, "Deepest"}
    end

    test "H1 and H5 are not headings" do
      assert Markdown.heading("# Title") == nil
      assert Markdown.heading("##### Too deep") == nil
    end

    test "a hash without a space is not a heading" do
      assert Markdown.heading("##NoSpace") == nil
      assert Markdown.heading("not a heading") == nil
    end
  end

  describe "heading?/1" do
    test "agrees with heading/1" do
      assert Markdown.heading?("## X")
      refute Markdown.heading?("# X")
      refute Markdown.heading?("text")
    end
  end

  describe "h1/1 and first_h1/1" do
    test "h1 extracts the trimmed title" do
      assert Markdown.h1("# Café Overview ") == "Café Overview"
      assert Markdown.h1("## Not an H1") == nil
    end

    test "first_h1 finds the first H1 anywhere in the content" do
      assert Markdown.first_h1("---\ntype: reference\n---\n# Title\n\nbody") == "Title"
      assert Markdown.first_h1("no title here") == nil
    end
  end

  describe "count_headings/1" do
    test "counts H2 through H4 only" do
      assert Markdown.count_headings("# A\n## B\n### C\n#### D\n##### E\n") == 3
    end
  end

  describe "headings/1" do
    test "returns rank and text in document order" do
      assert Markdown.headings("# A\n## B\ntext\n### C\n") == [{2, "B"}, {3, "C"}]
    end
  end

  describe "starts_with_h1?/1 and starts_with_frontmatter?/1" do
    test "leading whitespace is ignored" do
      assert Markdown.starts_with_h1?("\n\n# Title\nbody")
      refute Markdown.starts_with_h1?("body\n# Title")
      assert Markdown.starts_with_frontmatter?("  \n---\ntype: x\n---\n")
      refute Markdown.starts_with_frontmatter?("# Title\n")
    end
  end

  describe "frontmatter/1" do
    test "returns the yaml text, the body lines and the number of lines consumed" do
      content = "---\ntype: reference\n---\n# Title\nbody\n"

      assert {:ok, yaml, body_lines, offset} = Markdown.frontmatter(content)
      assert yaml == "type: reference"
      assert body_lines == ["# Title", "body"]
      assert offset == 3
    end

    test "an empty frontmatter block is still a block" do
      assert {:ok, "", ["# T"], 2} = Markdown.frontmatter("---\n---\n# T\n")
    end

    test "content without a leading marker has no frontmatter" do
      assert Markdown.frontmatter("# Title\nbody\n") == :none
    end

    test "a block that never closes is unterminated, not missing" do
      assert Markdown.frontmatter("---\ntype: reference\n# Title\n") == :unterminated
    end
  end

  describe "split_frontmatter/1" do
    test "splits into a frontmatter block and a body, both newline-terminated" do
      assert {:ok, "---\ntype: reference\n---\n", "# Title\nbody\n"} =
               Markdown.split_frontmatter("---\ntype: reference\n---\n# Title\nbody\n")
    end

    test "a frontmatter block whose only line is blank round-trips unchanged" do
      assert {:ok, "---\n\n---\n", "body\n"} = Markdown.split_frontmatter("---\n\n---\nbody\n")
    end

    test "an empty block round-trips as an empty block" do
      assert {:ok, "---\n---\n", "body\n"} = Markdown.split_frontmatter("---\n---\nbody\n")
    end

    test "reports the two failure modes distinctly" do
      assert Markdown.split_frontmatter("# Title\n") == {:error, "No frontmatter found"}
      assert Markdown.split_frontmatter("---\na: 1\n") == {:error, "Unterminated frontmatter"}
    end
  end
end
