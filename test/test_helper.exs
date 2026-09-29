# Every test builds its temp dirs from System.tmp_dir!() plus
# System.unique_integer/1, which is unique only within one VM. Two suites
# running at once (two checkouts, or CI jobs sharing a runner) can pick the
# same name and delete each other's vaults. A temp root of this run's own
# makes the names unique across processes, and is removed when the suite ends.
run_tmp =
  Path.join(System.tmp_dir!(), "vigil_test_run_#{System.pid()}_#{System.system_time()}")

File.mkdir_p!(run_tmp)
System.put_env("TMPDIR", run_tmp)
ExUnit.after_suite(fn _ -> File.rm_rf(run_tmp) end)

# A file name that is not UTF-8 is one Linux keeps as the bytes it was given
# and APFS refuses outright (EILSEQ). The tests that need such a file on disk
# are tagged `:non_utf8_file_names` and run only where the filesystem the
# suite writes to will hold one; the functions they reach are also tested
# with the name as data, which runs everywhere.
non_utf8_probe = Path.join(run_tmp, "probe-caf" <> <<0xE9>> <> ".md")

exclude =
  case File.write(non_utf8_probe, "") do
    :ok ->
      File.rm(non_utf8_probe)
      []

    {:error, _} ->
      [:non_utf8_file_names]
  end

ExUnit.start(exclude: exclude)
