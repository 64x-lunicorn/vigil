defmodule Mix.Tasks.Vigil.SlugDiffTest do
  @moduledoc """
  The task walks the vault it is handed with the exclusions the environment
  names — `VIGIL_EXCLUDE` is the hard boundary (docs/design.md), and a
  migration check that listed the filenames and headings of an excluded
  directory would breach it.
  """
  # Reads the application environment, which is global.
  use ExUnit.Case, async: false

  alias Mix.Tasks.Vigil.SlugDiff

  setup do
    vault =
      Path.join(System.tmp_dir!(), "vigil_slug_diff_#{System.unique_integer([:positive])}")

    # Both filenames slug differently under legacy_slugify/1 ("caf") and
    # slugify/1 ("cafe"), so each would be a difference if it were walked.
    File.mkdir_p!(Path.join(vault, "geheim"))
    File.mkdir_p!(Path.join(vault, "projects/geheim"))
    File.write!(Path.join(vault, "geheim/café.md"), "# T\n")
    File.write!(Path.join(vault, "projects/geheim/café.md"), "# T\n")

    previous = Application.fetch_env(:vigil, :exclude)
    Mix.shell(Mix.Shell.Process)

    on_exit(fn ->
      Mix.shell(Mix.Shell.IO)

      case previous do
        {:ok, value} -> Application.put_env(:vigil, :exclude, value)
        :error -> Application.delete_env(:vigil, :exclude)
      end

      File.rm_rf!(vault)
    end)

    %{vault: vault}
  end

  test "an excluded directory is not walked, at any depth", %{vault: vault} do
    Application.put_env(:vigil, :exclude, ["geheim"])

    assert SlugDiff.run([vault]) == :ok

    assert_received {:mix_shell, :info,
                     ["No difference between legacy_slugify/1 and slugify/1 (0 files checked)."]}
  end

  # The other half: the silence above is the exclusion's doing.
  test "the same vault with nothing excluded has a difference in each", %{vault: vault} do
    Application.put_env(:vigil, :exclude, [])

    assert catch_exit(SlugDiff.run([vault])) == {:shutdown, 1}
    assert_received {:mix_shell, :info, ["2 difference(s) found:\n"]}
  end

  describe "--against, the comparison update.sh runs before a switch" do
    # A vault whose ids this build derives: the note's own (its preamble), and
    # one per heading, a colliding heading numbered.
    setup %{vault: vault} do
      Application.put_env(:vigil, :exclude, ["geheim"])
      File.mkdir_p!(Path.join(vault, "home"))

      File.write!(
        Path.join(vault, "home/heating.md"),
        "---\ntype: reference\n---\n# Heating\n\nIntro.\n\n## Oil\n\n## Oil\n\n## Gas\n"
      )

      %{ids_file: Path.join(vault, "ids.txt")}
    end

    test "the same list is no change", %{vault: vault, ids_file: ids_file} do
      File.write!(
        ids_file,
        "home/heating.md\nhome/heating.md#gas\nhome/heating.md#oil\nhome/heating.md#oil-2\n"
      )

      assert SlugDiff.run(["--against", ids_file, vault]) == :ok
      assert_received {:mix_shell, :info, ["No chunk id changes (4 ids compared)."]}
    end

    test "an id only one side derives is listed, and the task exits 1", %{
      vault: vault,
      ids_file: ids_file
    } do
      # What another build said: it numbered the colliding heading otherwise.
      File.write!(
        ids_file,
        "home/heating.md\nhome/heating.md#gas\nhome/heating.md#oil\nhome/heating.md#oil-1\n"
      )

      assert catch_exit(SlugDiff.run(["--against", ids_file, vault])) == {:shutdown, 1}
      assert_received {:mix_shell, :info, ["2 chunk id change(s):\n"]}
      assert_received {:mix_shell, :info, ["  - home/heating.md#oil-1"]}
      assert_received {:mix_shell, :info, ["  + home/heating.md#oil-2"]}
    end

    test "an excluded directory contributes no id", %{vault: vault, ids_file: ids_file} do
      File.write!(
        Path.join(vault, "geheim/cafe.md"),
        "---\ntype: reference\n---\n# Cafe\n\nSecret.\n"
      )

      File.write!(
        ids_file,
        Enum.join(Vigil.Vault.Rules.chunk_ids(vault, ["home/heating.md"]), "\n")
      )

      assert SlugDiff.run(["--against", ids_file, vault]) == :ok

      # The other half: walked, the excluded note would be a change.
      Application.put_env(:vigil, :exclude, [])
      assert catch_exit(SlugDiff.run(["--against", ids_file, vault])) == {:shutdown, 1}
      assert_received {:mix_shell, :info, ["  + geheim/cafe.md"]}
    end
  end

  describe "Vigil.Release.chunk_ids/0, the running release's half" do
    setup %{vault: vault} do
      File.mkdir_p!(Path.join(vault, "home"))

      File.write!(
        Path.join(vault, "home/heating.md"),
        "---\ntype: reference\n---\n# Heating\n\nIntro.\n\n## Oil\n"
      )

      on_exit(fn ->
        System.delete_env("VIGIL_VAULT_PATH")
        System.delete_env("VIGIL_EXCLUDE")
      end)

      :ok
    end

    test "prints the ids the task compares, one per line, with the exclusions named", %{
      vault: vault
    } do
      System.put_env("VIGIL_VAULT_PATH", vault)
      System.put_env("VIGIL_EXCLUDE", " geheim , ")

      printed = ExUnit.CaptureIO.capture_io(fn -> Vigil.Release.chunk_ids() end)

      assert printed == "home/heating.md\nhome/heating.md#oil\n"

      # What the task reads back is exactly this: no change.
      ids_file = Path.join(vault, "ids.txt")
      File.write!(ids_file, printed)
      Application.put_env(:vigil, :exclude, ["geheim"])
      assert SlugDiff.run(["--against", ids_file, vault]) == :ok
    end
  end
end
