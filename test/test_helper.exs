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

ExUnit.start()
