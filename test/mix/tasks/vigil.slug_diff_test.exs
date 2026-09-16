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
end
