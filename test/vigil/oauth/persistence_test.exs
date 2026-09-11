defmodule Vigil.OAuth.PersistenceTest do
  @moduledoc """
  The persistence contract itself, and the one adapter behind it so far.

  What is pinned here is the rule the seam is built on: every question has to
  be answered where the adapter is built. Each of these guards something — a
  token's existence, a lockout, an expiry — and every plausible answer to a
  question nobody wired sits on the permissive side of the gate it feeds.
  """
  use ExUnit.Case, async: true

  alias Vigil.OAuth.{Persistence, Store}

  # The whole contract, with the arity each question is asked at. Written out
  # rather than read off the struct, because a test that derives the list from
  # the thing it checks passes whatever that thing says.
  @questions [
    put_client: 2,
    get_client: 1,
    put_code: 2,
    take_code: 1,
    put_token: 2,
    get_token: 1,
    delete_token: 1,
    revoke_grant: 1,
    rate_limited?: 2,
    record_failure: 2,
    reset_rate_limit: 1,
    cimd_cache_get: 2,
    cimd_cache_put: 3,
    sweep_expired: 1
  ]

  defp every_answer, do: for({question, _arity} <- @questions, do: {question, fn -> :ok end})

  describe "new/1" do
    test "builds a persistence when every question is answered" do
      assert %Persistence{} = Persistence.new(every_answer())
    end

    test "a question left unwired raises where the adapter is built" do
      for {question, _arity} <- @questions do
        missing = Keyword.delete(every_answer(), question)

        assert_raise ArgumentError, ~r/#{question}/, fn -> Persistence.new(missing) end
      end
    end

    test "a field the contract does not declare raises" do
      assert_raise KeyError, fn ->
        Persistence.new(Keyword.put(every_answer(), :put_session, fn -> :ok end))
      end
    end
  end

  describe "the :dets adapter" do
    test "answers every question, at the arity it is asked at" do
      adapter = Store.over_tables()

      for {question, arity} <- @questions do
        assert is_function(Map.fetch!(adapter, question), arity),
               "#{question} is not answered at arity #{arity}"
      end
    end
  end
end
