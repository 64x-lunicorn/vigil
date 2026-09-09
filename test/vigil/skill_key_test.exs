defmodule Vigil.SkillKeyTest do
  use ExUnit.Case, async: true

  alias Vigil.SkillKey

  @key %{secret: "test-secret-not-for-prod", window: 3600}

  test "a key validates inside its window" do
    now = 1_700_003_600
    token = SkillKey.current(@key, now)

    assert SkillKey.valid?(token, @key, now)
  end

  test "the immediately previous window still validates (grace period)" do
    now = 1_700_003_600
    prev_window_now = now - @key.window
    token = SkillKey.current(@key, prev_window_now)

    assert SkillKey.valid?(token, @key, now)
  end

  test "the window before that does not validate" do
    now = 1_700_003_600
    two_windows_back = now - 2 * @key.window
    token = SkillKey.current(@key, two_windows_back)

    refute SkillKey.valid?(token, @key, now)
  end

  test "a wrong key never validates" do
    now = 1_700_003_600
    wrong_key = %{@key | secret: "a-different-secret"}
    token = SkillKey.current(wrong_key, now)

    refute SkillKey.valid?(token, @key, now)
    refute SkillKey.valid?("0000000000000000", @key, now)
  end

  test "rotation behaves correctly at a non-default window" do
    key = %{secret: "test-secret-not-for-prod", window: 30}

    # now=90 is bucket 3 (90 / 30).
    token_current = SkillKey.current(key, 90)
    assert SkillKey.valid?(token_current, key, 90)

    # now=60 is bucket 2, the immediately preceding window — still valid.
    token_prev = SkillKey.current(key, 60)
    assert SkillKey.valid?(token_prev, key, 90)

    # now=29 is bucket 0, two windows back — no longer valid.
    token_two_back = SkillKey.current(key, 29)
    refute SkillKey.valid?(token_two_back, key, 90)
  end

  test "current/2 defaults `now` to the real clock" do
    token = SkillKey.current(@key)
    assert SkillKey.valid?(token, @key)
  end
end
