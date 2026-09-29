defmodule Vigil.OAuth.StoreSchemaVersionTest do
  @moduledoc """
  The state dir says which version of its format it holds, and the store reads
  it before it opens anything (docs/compatibility.md, "The OAuth state").

  Backward: a state dir written by an earlier release — without a version, as
  0.2.0 and everything before it wrote, or with an older one — is read,
  migrated, and marked with this release's version. Forward: a state dir a
  newer release has marked is refused with a message that says so, and left
  byte for byte as it was, so running that newer release again still finds
  what it wrote. That second case is what `update.sh --rollback` produces
  after a newer release has booted once.
  """
  # The Store is a named singleton with named tables.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Vigil.OAuth.{Store, Token}

  @pre_seam Path.expand("../../fixtures/oauth_store_pre_seam", __DIR__)

  setup do
    state_dir =
      Path.join(System.tmp_dir!(), "vigil_oauth_schema_#{System.unique_integer([:positive])}")

    File.mkdir_p!(state_dir)
    on_exit(fn -> File.rm_rf(state_dir) end)

    %{state_dir: state_dir}
  end

  # The version as it is on disk, read the way an operator's tooling would:
  # the file, not the process.
  defp stored_version(state_dir) do
    path = String.to_charlist(Path.join(state_dir, "oauth_meta.dets"))
    {:ok, meta} = :dets.open_file(make_ref(), file: path, access: :read)
    found = :dets.lookup(meta, :schema_version)
    :ok = :dets.close(meta)
    found
  end

  defp mark(state_dir, version) do
    path = String.to_charlist(Path.join(state_dir, "oauth_meta.dets"))
    {:ok, meta} = :dets.open_file(make_ref(), file: path, type: :set)
    :ok = :dets.insert(meta, {:schema_version, version})
    :ok = :dets.close(meta)
  end

  defp copy_pre_seam(state_dir) do
    for file <- Path.wildcard(Path.join(@pre_seam, "*.dets")) do
      File.cp!(file, Path.join(state_dir, Path.basename(file)))
    end
  end

  defp token_keys(state_dir) do
    path = String.to_charlist(Path.join(state_dir, "oauth_tokens.dets"))
    {:ok, table} = :dets.open_file(make_ref(), file: path, access: :read)
    keys = :dets.foldl(fn {key, _attrs}, acc -> [key | acc] end, [], table)
    :ok = :dets.close(table)
    keys
  end

  defp files(state_dir) do
    state_dir
    |> File.ls!()
    |> Map.new(fn name -> {name, File.read!(Path.join(state_dir, name))} end)
  end

  defp refused_start(state_dir) do
    Process.flag(:trap_exit, true)
    with_log(fn -> Store.start_link(state_dir: state_dir) end)
  end

  test "this release's version is 2: codes and tokens under their digest" do
    assert Store.schema_version() == 2
  end

  test "a new state dir is marked with this release's version", %{state_dir: state_dir} do
    start_supervised!({Store, state_dir: state_dir})

    assert stored_version(state_dir) == [schema_version: Store.schema_version()]
  end

  test "the version file is readable by its owner alone", %{state_dir: state_dir} do
    start_supervised!({Store, state_dir: state_dir})

    {:ok, %File.Stat{mode: mode}} = File.stat(Path.join(state_dir, "oauth_meta.dets"))
    assert Bitwise.band(mode, 0o077) == 0
  end

  describe "backward: state an earlier release wrote" do
    test "without a version (0.2.0 and before) is migrated and marked", %{state_dir: state_dir} do
      copy_pre_seam(state_dir)
      raw = Enum.find(token_keys(state_dir), &is_binary/1)
      assert raw

      capture_log(fn -> start_supervised!({Store, state_dir: state_dir}) end)

      assert stored_version(state_dir) == [schema_version: 2]
      assert Enum.all?(token_keys(state_dir), &match?({:sha256, _}, &1))
      assert {:ok, _record} = Store.over_tables().get_token.(raw)
    end

    test "marked with version 1 is migrated the same way", %{state_dir: state_dir} do
      copy_pre_seam(state_dir)
      mark(state_dir, 1)
      raw = Enum.find(token_keys(state_dir), &is_binary/1)

      capture_log(fn -> start_supervised!({Store, state_dir: state_dir}) end)

      assert stored_version(state_dir) == [schema_version: 2]
      assert {:ok, _record} = Store.over_tables().get_token.(raw)
    end

    test "marked with this version is read as it is", %{state_dir: state_dir} do
      start_supervised!({Store, state_dir: state_dir})

      token =
        Token.issue_out_of_band(Store.over_tables(), "https://r.example/mcp", "vault", 60, 0)

      stop_supervised!(Store)
      start_supervised!({Store, state_dir: state_dir})

      assert {:ok, _record} = Store.over_tables().get_token.(token)
      assert stored_version(state_dir) == [schema_version: 2]
    end
  end

  describe "forward: state a newer release wrote" do
    setup %{state_dir: state_dir} do
      copy_pre_seam(state_dir)
      mark(state_dir, Store.schema_version() + 1)
      :ok
    end

    test "is refused, and the message names both versions", %{state_dir: state_dir} do
      {result, log} = refused_start(state_dir)

      assert result == {:error, {:oauth_store_init_failed, {:newer_schema_version, 3}}}
      assert log =~ "schema version 3, written by a newer vigil"
      assert log =~ "this release reads versions up to 2"
      assert log =~ state_dir
    end

    test "is left byte for byte as it was", %{state_dir: state_dir} do
      before = files(state_dir)

      {{:error, _reason}, _log} = refused_start(state_dir)

      assert files(state_dir) == before
    end
  end

  test "a version that is not a number is refused rather than guessed at", %{
    state_dir: state_dir
  } do
    mark(state_dir, "two")

    {result, _log} = refused_start(state_dir)

    assert result == {:error, {:oauth_store_init_failed, {:unknown_schema_version, "two"}}}
  end
end
