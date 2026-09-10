defmodule Vigil.MCP.ToolsDispatchTest do
  # The stub registers itself under `Vigil.Store`'s name, so this file cannot
  # run beside anything that starts the real one — including the one describe
  # below that starts the real Store itself, which is why nothing here is
  # async.
  use ExUnit.Case, async: false

  alias Vigil.MCP.Tools

  # The instant the response's envelope was decided at. Only the two rows that
  # declare `now:` are supposed to see it; every other assertion here is about
  # a call that must not carry it.
  @now ~U[2026-07-09 11:20:00Z]

  # Answers every `{op, params}` the way the tool layer's caller does — by
  # forwarding it to the test and replying with whatever the test asked for.
  # Nothing about a tool is known here: that is the point, since what dispatch
  # sends is supposed to come from the table alone.
  defmodule StoreStub do
    use GenServer

    def start_link({test, reply}),
      do: GenServer.start_link(__MODULE__, {test, reply}, name: Vigil.Store)

    @impl true
    def init(state), do: {:ok, state}

    @impl true
    def handle_call(message, _from, {test, reply} = state) do
      send(test, {:store_call, message})
      {:reply, reply, state}
    end
  end

  defp start_store(reply \\ :stub_result) do
    start_supervised!({StoreStub, {self(), reply}})
    :ok
  end

  defp skill_key, do: Vigil.SkillKey.current(Vigil.SkillKey.config())

  describe "the call each tool makes comes from the table" do
    test "search sends its declared operation with every declared parameter" do
      start_store()

      assert {:ok, :stub_result} = Tools.dispatch("search", %{"query" => "tires"}, @now)

      assert_receive {:store_call, {:search, params}}

      assert params == %{
               query: "tires",
               domain: nil,
               type: nil,
               prefer: nil,
               limit: 10
             }
    end

    test "a parameterless tool sends an empty params map" do
      start_store()

      assert {:ok, :stub_result} = Tools.dispatch("reload", %{}, @now)
      assert_receive {:store_call, {:reload, %{}}}
    end

    # The instant is the response's, not one the operation reads for itself
    # on the far side of the writer — which is how `current` came to report a
    # time its own envelope could contradict. It travels with the params
    # because the Store's tool-facing interface has one shape.
    test "a tool declaring now: is handed the response's instant" do
      start_store()

      assert {:ok, :stub_result} = Tools.dispatch("current", %{}, @now)
      assert_receive {:store_call, {:current, %{now: @now}}}

      assert {:ok, :stub_result} = Tools.dispatch("lint", %{}, @now)
      assert_receive {:store_call, {:lint, %{now: @now}}}
    end

    test "a tool that declares no instant is not handed one" do
      start_store()

      Tools.dispatch("search", %{"query" => "tires"}, @now)
      assert_receive {:store_call, {:search, params}}
      refute Map.has_key?(params, :now)
    end

    test "move_note's two same-typed paths travel under the names the table gives them" do
      start_store({:ok, %{moved: true}})

      assert {:ok, %{moved: true}} =
               Tools.dispatch(
                 "move_note",
                 %{
                   "from" => "training/a.md",
                   "to" => "training/b.md",
                   "confirm" => true,
                   "skill_key" => skill_key()
                 },
                 @now
               )

      assert_receive {:store_call, {:move_note, params}}
      assert params.from == "training/a.md"
      assert params.to == "training/b.md"
    end
  end

  describe "enum parameters arrive in their internal form" do
    test "search's type and prefer are atoms, not the strings the schema publishes" do
      start_store()

      Tools.dispatch(
        "search",
        %{
          "query" => "tires",
          "type" => "decision",
          "prefer" => "reference"
        },
        @now
      )

      assert_receive {:store_call, {:search, params}}
      assert params.type == :decision
      assert params.prefer == :reference
    end

    test "links' direction default converts on the same path a supplied value does" do
      start_store()

      Tools.dispatch("links", %{"id" => "bike/x.md"}, @now)
      assert_receive {:store_call, {:links, %{direction: :both, depth: 1}}}

      Tools.dispatch("links", %{"id" => "bike/x.md", "direction" => "out"}, @now)
      assert_receive {:store_call, {:links, %{direction: :out}}}
    end

    test "create's type is converted too, not left a string for one clause only" do
      start_store({:ok, %{created: true}})

      Tools.dispatch(
        "create",
        %{
          "path" => "bike/x.md",
          "type" => "event",
          "content" => "# X",
          "starts" => "2026-01-01T00:00:00Z",
          "ends" => "2026-01-02T00:00:00Z",
          "skill_key" => skill_key()
        },
        @now
      )

      assert_receive {:store_call, {:create, params}}
      assert params.type == :event
    end

    test "update_frontmatter's type is converted on the same rule" do
      start_store({:ok, %{updated: true}})

      Tools.dispatch(
        "update_frontmatter",
        %{
          "path" => "bike/x.md",
          "type" => "reference",
          "skill_key" => skill_key()
        },
        @now
      )

      assert_receive {:store_call, {:update_frontmatter, params}}
      assert params.type == :reference
    end
  end

  describe "skill_key authorizes the call and does not travel with it" do
    test "create's params carry no skill_key" do
      start_store({:ok, %{created: true}})

      Tools.dispatch(
        "create",
        %{
          "path" => "bike/x.md",
          "type" => "reference",
          "content" => "# X",
          "skill_key" => skill_key()
        },
        @now
      )

      assert_receive {:store_call, {:create, params}}
      refute Map.has_key?(params, :skill_key)
    end

    test "skill_write's params carry no skill_key either" do
      start_store({:ok, %{written: true}})

      Tools.dispatch(
        "skill_write",
        %{
          "name" => "x",
          "content" => "---\nname: x\n---\n# X\n",
          "skill_key" => skill_key()
        },
        @now
      )

      assert_receive {:store_call, {:skill_write, params}}
      assert Map.keys(params) |> Enum.sort() == [:content, :name]
    end
  end

  # docs/design.md, "skills/ — one repository, two systems": the two skill
  # reads are answered in the caller's process, against the vault path the
  # writer publishes. Suspending the writer is the whole claim in one line —
  # a GenServer.call would block until it timed out, and a skill read is the
  # mandatory bootstrap (AP-4) in front of every write, so it would otherwise
  # be queued behind the push at the end of the write before it.
  describe "a skill read does not enter the writer's mailbox" do
    setup do
      vault = Vigil.FixtureVault.build()
      on_exit(fn -> Vigil.FixtureVault.cleanup(vault) end)

      start_supervised!(
        {Vigil.Store,
         vault_path: vault, exclude: [], git_remote: "origin", git: Vigil.Git.CommitLog.new(vault)}
      )

      writer = Process.whereis(Vigil.Store)
      :sys.suspend(writer)
      on_exit(fn -> if Process.alive?(writer), do: :sys.resume(writer) end)

      %{vault: vault}
    end

    test "skill_list answers while the writer is suspended" do
      assert {:ok, [%{name: "tdd"}]} = Tools.dispatch("skill_list", %{}, @now)
    end

    test "skill_read answers while the writer is suspended, key and all" do
      assert {:ok, %{name: "tdd", content: content}} =
               Tools.dispatch("skill_read", %{"name" => "tdd"}, @now)

      assert content =~ "SkillKey:"
    end

    test "a missing skill still hands back the bootstrap key" do
      assert {:error, message} = Tools.dispatch("skill_read", %{"name" => "does-not-exist"}, @now)
      assert message =~ "tdd"
      assert message =~ "SkillKey:"
    end
  end

  describe "the Store's answer is lifted into a result without a flag per tool" do
    test "an operation that cannot fail answers with its value, which becomes {:ok, value}" do
      start_store([%{id: "bike/x.md#a"}])

      assert Tools.dispatch("search", %{"query" => "tires"}, @now) ==
               {:ok, [%{id: "bike/x.md#a"}]}
    end

    test "an operation that can fail answers with a result tuple, passed through unchanged" do
      start_store({:error, "no such note"})

      assert Tools.dispatch("read", %{"id" => "bike/nope.md"}, @now) == {:error, "no such note"}
    end

    test "an {:ok, value} answer is not wrapped twice" do
      start_store({:ok, %{title: "X"}})

      assert Tools.dispatch("read", %{"id" => "bike/x.md"}, @now) == {:ok, %{title: "X"}}
    end
  end
end
