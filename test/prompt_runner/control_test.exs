defmodule PromptRunner.ControlTest do
  @moduledoc """
  The control plane, exercised the way a consumer reaches it: through
  `PromptRunner.Control` and the files under `.prompt_runner/control/`.

  Nothing here calls the runner internals, on purpose. If a test needed to,
  the boundary would already have failed.
  """

  use ExUnit.Case, async: false

  alias PromptRunner.Control
  alias PromptRunner.Control.Plane
  alias PromptRunner.Control.Snapshot
  alias PromptRunner.Control.Store
  alias PromptRunner.Test.FSHelpers

  setup do
    packet_dir = FSHelpers.tmp_dir("prompt_runner_control")
    on_exit(fn -> File.rm_rf!(packet_dir) end)
    {:ok, packet_dir: packet_dir}
  end

  defp open(packet_dir, opts \\ []) do
    plane = Plane.open(packet_dir, Keyword.merge([packet: "demo"], opts))
    {plane, {packet_dir, Plane.run_id(plane)}}
  end

  describe "current_run/1" do
    test "reports no run for a packet nothing has ever run", %{packet_dir: packet_dir} do
      assert Control.current_run(packet_dir) == {:error, :no_run}
    end

    test "finds the run the runner opened", %{packet_dir: packet_dir} do
      {plane, _ref} = open(packet_dir)

      assert {:ok, {^packet_dir, run_id}} = Control.current_run(packet_dir)
      assert run_id == Plane.run_id(plane)
    end
  end

  describe "operator-owned runtime state" do
    test "an explicit state root keeps mutable control files out of the packet", %{
      packet_dir: packet_dir
    } do
      state_root = FSHelpers.tmp_dir("prompt_runner_control_state")
      on_exit(fn -> File.rm_rf!(state_root) end)

      plane = Plane.open(packet_dir, packet: "demo", state_root: state_root)
      plane = Plane.observe(plane, %{type: :run_started, data: %{}})
      Plane.boundary(plane)

      root = Store.state_root(state_root)
      assert Plane.store_root(plane) == root
      assert File.exists?(Store.snapshot_path(root))
      assert File.exists?(Store.events_path(root))
      refute File.exists?(Path.join(packet_dir, ".prompt_runner/control"))
    end

    test "legacy callers retain the packet-local layout", %{packet_dir: packet_dir} do
      plane = Plane.open(packet_dir, packet: "demo")

      assert Plane.store_root(plane) == packet_dir
      assert File.exists?(Store.snapshot_path(packet_dir))
    end
  end

  describe "snapshot/1" do
    test "carries everything a dashboard header needs", %{packet_dir: packet_dir} do
      {plane, run_ref} = open(packet_dir)

      plane
      |> Plane.prompt_started(%{num: "03", name: "Write the guide"}, :repair, 2, %{
        sdk: :codex,
        model: "gpt-5.6-luna"
      })
      |> Plane.observe(%{type: :tool_call_started, data: %{tool_name: "Bash"}})
      |> Plane.observe(%{type: :token_usage_updated, data: %{input_tokens: 10, output_tokens: 4}})
      |> Plane.boundary()

      assert {:ok, snapshot} = Control.snapshot(run_ref)
      assert snapshot.packet == "demo"
      assert snapshot.status == :running
      assert snapshot.prompt_id == "03"
      assert snapshot.prompt_name == "Write the guide"
      assert snapshot.attempt == 2
      assert snapshot.mode == :repair
      assert snapshot.provider == :codex
      assert snapshot.model == "gpt-5.6-luna"
      assert snapshot.tool_count == 1
      assert snapshot.input_tokens == 10
      assert snapshot.output_tokens == 4
      assert snapshot.view.log_mode == :compact
    end

    test "refuses a run_ref naming a run that is no longer current", %{packet_dir: packet_dir} do
      {_plane, _ref} = open(packet_dir)

      assert {:error, {:stale_run, _current}} =
               Control.snapshot({packet_dir, "20200101T000000Z-1"})
    end

    test "survives the runner dying mid-run", %{packet_dir: packet_dir} do
      {plane, run_ref} = open(packet_dir)
      Plane.prompt_started(plane, %{num: "01", name: "One"}, :run, 1, %{sdk: :claude})

      # No close/2: this is what the files look like after a SIGKILL.
      assert {:ok, snapshot} = Control.snapshot(run_ref)
      assert snapshot.status == :running
      assert snapshot.prompt_id == "01"
    end

    test "records how a run ended", %{packet_dir: packet_dir} do
      {plane, run_ref} = open(packet_dir)
      Plane.close(plane, :failed)

      assert {:ok, %Snapshot{status: :failed}} = Control.snapshot(run_ref)
    end
  end

  describe "set_view/3" do
    test "is applied at the next boundary and recorded as applied", %{packet_dir: packet_dir} do
      {plane, run_ref} = open(packet_dir)

      assert :ok = Control.set_view(run_ref, %{tool_output: "full"}, author: "ada")

      {plane, commands} = Plane.boundary(plane)

      assert commands == [{:set_view, %{tool_output: :full}}]
      assert Plane.view(plane).tool_output == :full

      assert {:ok, [entry]} = Control.log(run_ref)
      assert entry.command == "set_view"
      assert entry.outcome == :applied
      assert entry.author == "ada"
      assert entry.params == %{"tool_output" => "full"}
    end

    test "the new setting is visible in the snapshot", %{packet_dir: packet_dir} do
      {plane, run_ref} = open(packet_dir)
      :ok = Control.set_view(run_ref, %{log_mode: :verbose})
      Plane.boundary(plane)

      assert {:ok, snapshot} = Control.snapshot(run_ref)
      assert snapshot.view.log_mode == :verbose
    end

    test "refuses an unknown setting before it is ever written", %{packet_dir: packet_dir} do
      {_plane, run_ref} = open(packet_dir)

      assert {:error, {:unknown_view_key, "colour"}} =
               Control.set_view(run_ref, %{colour: "green"})

      assert Store.take_requests(packet_dir) == []
    end

    test "refuses a value the setting does not take", %{packet_dir: packet_dir} do
      {_plane, run_ref} = open(packet_dir)

      assert {:error, {:invalid_view_value, "tool_output", "everything"}} =
               Control.set_view(run_ref, %{tool_output: "everything"})
    end

    test "a request naming a stale run is rejected and logged", %{packet_dir: packet_dir} do
      {plane, run_ref} = open(packet_dir)

      Store.write_request(packet_dir, %{
        "command" => "set_view",
        "params" => %{"tool_output" => "full"},
        "run_id" => "20200101T000000Z-1",
        "author" => "ada"
      })

      {plane, commands} = Plane.boundary(plane)

      assert commands == []
      assert Plane.view(plane).tool_output == :summary

      assert {:ok, [entry]} = Control.log(run_ref)
      assert entry.outcome == :rejected
      assert entry.reason =~ "targets run"
    end
  end

  describe "malformed requests" do
    test "a file that is not JSON is logged, removed, and not fatal", %{packet_dir: packet_dir} do
      {plane, run_ref} = open(packet_dir)
      path = Path.join(Store.requests_dir(packet_dir), "20260810-000000-000000-1.json")
      File.write!(path, "this is not json")

      assert {_plane, []} = Plane.boundary(plane)
      refute File.exists?(path)

      assert {:ok, [entry]} = Control.log(run_ref)
      assert entry.outcome == :rejected
      assert entry.command == "unparseable"
    end

    test "a JSON object with no command is logged and removed", %{packet_dir: packet_dir} do
      {plane, run_ref} = open(packet_dir)
      Store.write_request(packet_dir, %{"params" => %{}})

      assert {_plane, []} = Plane.boundary(plane)
      assert Store.take_requests(packet_dir) == []

      assert {:ok, [entry]} = Control.log(run_ref)
      assert entry.outcome == :rejected
      assert entry.reason =~ "no command"
    end

    test "an unknown command is logged and removed", %{packet_dir: packet_dir} do
      {plane, run_ref} = open(packet_dir)
      Store.write_request(packet_dir, %{"command" => "self_destruct", "params" => %{}})

      assert {_plane, []} = Plane.boundary(plane)

      assert {:ok, [entry]} = Control.log(run_ref)
      assert entry.command == "self_destruct"
      assert entry.reason == "unknown command"
    end

    test "requests are consumed in arrival order", %{packet_dir: packet_dir} do
      {plane, run_ref} = open(packet_dir)

      :ok = Control.set_view(run_ref, %{tool_output: "full"})
      :ok = Control.set_view(run_ref, %{tool_output: "none"})

      {plane, _commands} = Plane.boundary(plane)

      assert Plane.view(plane).tool_output == :none
      assert {:ok, [first, second]} = Control.log(run_ref)
      assert first.params == %{"tool_output" => "full"}
      assert second.params == %{"tool_output" => "none"}
    end

    test "pending reads do not delete a request", %{packet_dir: packet_dir} do
      {_plane, run_ref} = open(packet_dir)
      :ok = Control.set_view(run_ref, %{tool_output: "full"})

      [{name, {:ok, _request}}] = Store.pending_requests(packet_dir)

      assert File.exists?(Path.join(Store.requests_dir(packet_dir), name))
      assert Store.pending_requests(packet_dir) |> length() == 1
    end

    test "a request is removed only after its durable outcome exists", %{packet_dir: packet_dir} do
      {plane, run_ref} = open(packet_dir)
      :ok = Control.set_view(run_ref, %{tool_output: "full"})
      [{name, {:ok, _request}}] = Store.pending_requests(packet_dir)

      assert {_plane, [{:set_view, %{tool_output: :full}}]} = Plane.boundary(plane)

      refute File.exists?(Path.join(Store.requests_dir(packet_dir), name))
      outcome_path = Store.request_outcome_path(packet_dir, name)
      assert File.exists?(outcome_path)
      assert Jason.decode!(File.read!(outcome_path))["outcome"] == "applied"
    end

    test "a request remains pending when its audit entry cannot be persisted", %{
      packet_dir: packet_dir
    } do
      {plane, run_ref} = open(packet_dir)
      :ok = File.mkdir_p(Store.log_path(packet_dir))
      :ok = Control.set_view(run_ref, %{tool_output: "full"})
      [{name, {:ok, _request}}] = Store.pending_requests(packet_dir)

      assert {same_plane, []} = Plane.boundary(plane)
      assert Plane.view(same_plane).tool_output == :summary
      assert File.exists?(Path.join(Store.requests_dir(packet_dir), name))
      refute File.exists?(Store.request_outcome_path(packet_dir, name))

      File.rmdir!(Store.log_path(packet_dir))
      assert {_plane, [{:set_view, %{tool_output: :full}}]} = Plane.boundary(same_plane)
      assert File.exists?(Store.request_outcome_path(packet_dir, name))
    end

    test "a command is not emitted when its durable outcome cannot be written", %{
      packet_dir: packet_dir
    } do
      {plane, run_ref} = open(packet_dir)
      :ok = Control.set_view(run_ref, %{tool_output: "full"})
      [{name, {:ok, _request}}] = Store.pending_requests(packet_dir)

      File.rm_rf!(Store.outcomes_dir(packet_dir))
      File.write!(Store.outcomes_dir(packet_dir), "not a directory")

      assert {same_plane, []} = Plane.boundary(plane)
      assert Plane.view(same_plane).tool_output == :summary
      assert File.exists?(Path.join(Store.requests_dir(packet_dir), name))
      refute File.exists?(Store.request_outcome_path(packet_dir, name))
    end

    test "a steer is accepted durably before its command is emitted", %{packet_dir: packet_dir} do
      {plane, run_ref} = open(packet_dir, max_steers: 1)

      plane =
        Plane.prompt_started(
          plane,
          %{num: "01", name: "One"},
          :run,
          1,
          %{sdk: :simulated}
        )

      :ok = Control.steer(run_ref, "look here", author: "ada")
      [{name, {:ok, _request}}] = Store.pending_requests(packet_dir)

      assert {_plane, [{:steer, "look here", "ada"}]} = Plane.boundary(plane)

      outcome = Store.request_outcome_path(packet_dir, name) |> File.read!() |> Jason.decode!()
      assert outcome["outcome"] == "accepted"
      refute File.exists?(Path.join(Store.requests_dir(packet_dir), name))
    end
  end

  describe "subscribe/3" do
    test "delivers the run's events and the terminal notice", %{packet_dir: packet_dir} do
      {plane, run_ref} = open(packet_dir)

      plane =
        plane
        |> Plane.observe(%{type: :run_started, data: %{model: "haiku"}})
        |> Plane.observe(%{type: :message_streamed, data: %{delta: "hi"}})

      assert {:ok, ref} = Control.subscribe(run_ref, self(), interval_ms: 20)

      assert_receive {:prompt_runner_event, ^ref, %{"type" => "run_started"}}, 2_000
      assert_receive {:prompt_runner_event, ^ref, %{"type" => "message_streamed"}}, 2_000

      plane
      |> Plane.observe(%{type: :run_completed, data: %{stop_reason: "end_turn"}})
      |> Plane.close(:completed)

      assert_receive {:prompt_runner_event, ^ref, %{"type" => "run_completed"}}, 2_000
      assert_receive {:prompt_runner_control, ^ref, {:run_finished, :completed}}, 2_000
    end

    test "from: :current skips what happened before subscribing", %{packet_dir: packet_dir} do
      {plane, run_ref} = open(packet_dir)
      plane = Plane.observe(plane, %{type: :run_started, data: %{}})

      assert {:ok, ref} = Control.subscribe(run_ref, self(), from: :current, interval_ms: 20)

      plane
      |> Plane.observe(%{type: :message_streamed, data: %{delta: "later"}})
      |> Plane.close(:completed)

      assert_receive {:prompt_runner_event, ^ref, %{"type" => "message_streamed"}}, 2_000
      refute_received {:prompt_runner_event, ^ref, %{"type" => "run_started"}}
    end

    test "unsubscribe stops delivery", %{packet_dir: packet_dir} do
      {plane, run_ref} = open(packet_dir)

      assert {:ok, ref} = Control.subscribe(run_ref, self(), interval_ms: 20)
      assert :ok = Control.unsubscribe(run_ref, ref)

      Plane.observe(plane, %{type: :run_started, data: %{}})

      refute_receive {:prompt_runner_event, ^ref, _event}, 300
    end

    test "a fresh run archives rather than truncates the prior stream", %{packet_dir: packet_dir} do
      {plane, first_ref} = open(packet_dir)
      Plane.observe(plane, %{type: :run_started, data: %{model: "first"}})
      previous = File.read!(Store.events_path(packet_dir))

      {_plane, run_ref} = open(packet_dir)

      assert File.read!(Store.archived_events_path(packet_dir, elem(first_ref, 1))) == previous

      assert {:ok, ref} = Control.subscribe(run_ref, self(), interval_ms: 20)
      refute_receive {:prompt_runner_event, ^ref, %{"data" => %{"model" => "first"}}}, 300
    end

    test "reopening the same run id only appends and preserves the existing prefix", %{
      packet_dir: packet_dir
    } do
      run_id = "20260810T120000Z-resume"
      plane = Plane.open(packet_dir, packet: "demo", run_id: run_id)

      Plane.observe(plane, %{type: :message_streamed, data: %{delta: String.duplicate("x", 4096)}})

      prefix = File.read!(Store.events_path(packet_dir))

      resumed = Plane.open(packet_dir, packet: "demo", run_id: run_id)
      Plane.observe(resumed, %{type: :message_streamed, data: %{delta: "later"}})
      after_resume = File.read!(Store.events_path(packet_dir))

      assert byte_size(after_resume) > byte_size(prefix)
      assert binary_part(after_resume, 0, byte_size(prefix)) == prefix
    end
  end

  describe "the event stream" do
    test "encodes atoms, structs, and tuples rather than dropping the event", %{
      packet_dir: packet_dir
    } do
      {plane, run_ref} = open(packet_dir)

      Plane.observe(plane, %{
        type: :tool_call_completed,
        data: %{
          tool_name: :bash,
          result: {:ok, "done"},
          at: ~U[2026-08-10 12:00:00Z]
        }
      })

      assert {:ok, ref} = Control.subscribe(run_ref, self(), interval_ms: 20)
      assert_receive {:prompt_runner_event, ^ref, event}, 2_000

      assert event["type"] == "tool_call_completed"
      assert event["data"]["tool_name"] == "bash"
      assert event["data"]["result"] == ["ok", "done"]
    end
  end

  describe "a disabled plane" do
    test "writes nothing for a run with no state directory" do
      plane = Plane.open(nil, packet: "memory")

      assert Plane.run_id(plane) == nil
      refute Plane.enabled?(plane)

      plane = Plane.prompt_started(plane, %{num: "01", name: "One"}, :run, 1, %{sdk: :simulated})
      plane = Plane.observe(plane, %{type: :run_started, data: %{}})

      assert {^plane, []} = Plane.boundary(plane)
      assert Plane.close(plane, :completed) == plane
    end
  end
end
