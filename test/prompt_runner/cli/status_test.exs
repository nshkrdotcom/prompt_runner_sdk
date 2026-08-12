defmodule PromptRunner.CLI.StatusTest do
  use ExUnit.Case, async: true

  alias PromptRunner.CLI.Status

  @now ~U[2026-08-12 04:00:00Z]

  test "ordinary runs show prompt progress without loop-only noise" do
    output =
      Status.render_workspace(
        workspace_status(%{
          progress: %{
            selected: 5,
            completed: 2,
            running: 1,
            failed: 1,
            blocked: 0,
            pending: 1,
            current_position: 3,
            last_verifier: "passed"
          }
        }),
        now: @now,
        color: false
      )

    assert output =~ "demo — RUNNING · healthy"
    assert output =~ "progress   2/5 prompts complete · 1 running · 1 failed · 1 pending"
    assert output =~ "current    03 — Build the runtime · 3 of 5"
    assert output =~ "activity   15m13s this prompt · updated 8s ago · 78 tools · 719 events"
    assert output =~ "last check passed"
    refute output =~ "iteration"
    refute output =~ "attempt"
    refute output =~ "tokens"
  end

  test "agent-controlled runs show iteration progress only while configured" do
    output =
      Status.render_workspace(
        workspace_status(%{
          progress: %{
            selected: 1,
            completed: 0,
            running: 1,
            failed: 0,
            blocked: 0,
            pending: 0,
            current_position: 1
          },
          agent_control: %{
            enabled: true,
            looping: true,
            current_iteration: 2,
            completed_iterations: 1,
            max_iterations: 20,
            last_action: "repeat",
            last_reason: "P09R.2 unit B complete; next unit C",
            progress: %{
              run_id: "run-123",
              prompt_id: "01",
              iteration: 2,
              cursor: "P09R.2",
              unit: "C",
              summary: "generic runtime session ownership is in progress",
              updated_at: "2026-08-12T03:59:55Z",
              stale: false
            }
          },
          control: control(%{"prompt_id" => "01"})
        }),
        now: @now,
        color: false
      )

    assert output =~ "current    01 — Build the runtime"

    assert output =~
             "cursor     P09R.2 · unit C — generic runtime session ownership is in progress"

    assert output =~ "iteration  2 of 20 · 1 verified · last action repeat"
    assert output =~ "reason     P09R.2 unit B complete; next unit C"
    refute output =~ "0/1 prompts complete"
  end

  test "prior-iteration progress is clearly marked stale" do
    output =
      Status.render_workspace(
        workspace_status(%{
          agent_control: %{
            enabled: true,
            looping: true,
            current_iteration: 3,
            completed_iterations: 2,
            max_iterations: 20,
            last_action: "repeat",
            last_reason: "next iteration",
            progress: %{
              cursor: "P09R.2",
              unit: "B",
              summary: "unit B completed",
              iteration: 2,
              stale: true
            }
          }
        }),
        now: @now,
        color: false
      )

    assert output =~ "cursor     P09R.2 · unit B · previous iteration — unit B completed"
  end

  test "linear agent control does not show iteration fields until it actually loops" do
    output =
      Status.render_workspace(
        workspace_status(%{
          progress: %{
            selected: 3,
            completed: 1,
            running: 1,
            failed: 0,
            blocked: 0,
            pending: 1,
            current_position: 2
          },
          agent_control: %{
            enabled: true,
            looping: false,
            current_iteration: 1,
            completed_iterations: 0,
            max_iterations: 20,
            last_action: nil,
            last_reason: nil
          }
        }),
        now: @now,
        color: false
      )

    assert output =~ "progress   1/3 prompts complete · 1 running · 1 pending"
    assert output =~ "current    03 — Build the runtime · 2 of 3"
    refute output =~ "iteration"
  end

  test "a loop inside a longer sequence keeps both prompt and iteration progress" do
    output =
      Status.render_workspace(
        workspace_status(%{
          progress: %{
            selected: 3,
            completed: 1,
            running: 1,
            failed: 0,
            blocked: 0,
            pending: 1,
            current_position: 2
          },
          agent_control: %{
            enabled: true,
            looping: true,
            current_iteration: 4,
            completed_iterations: 3,
            max_iterations: 20,
            last_action: "repeat",
            last_reason: "current prompt still has work"
          }
        }),
        now: @now,
        color: false
      )

    assert output =~ "progress   1/3 prompts complete · 1 running · 1 pending"
    assert output =~ "current    03 — Build the runtime · 2 of 3"
    assert output =~ "iteration  4 of 20 · 3 verified · last action repeat"
  end

  test "retry and failure details appear only when they need operator attention" do
    output =
      Status.render_workspace(
        workspace_status(%{
          state: "failed",
          healthy?: false,
          control: control(%{"status" => "failed", "attempt" => 3, "mode" => "repair"}),
          progress: %{
            selected: 4,
            completed: 2,
            running: 0,
            failed: 1,
            blocked: 0,
            pending: 1,
            current_position: 3,
            last_verifier: "failed",
            reason: "completion verifier did not pass"
          },
          containment: %{state: :inactive, populated?: false, unit: "demo.service"},
          lease: %{state: :down, pid: nil}
        }),
        now: @now,
        color: false
      )

    assert output =~ "demo — FAILED · needs attention"
    assert output =~ "stopped at 03 — Build the runtime · 3 of 4"
    assert output =~ "attempt    repair 3"
    assert output =~ "last check failed"
    assert output =~ "reason     completion verifier did not pass"
    assert output =~ "service    inactive · process down"
  end

  defp workspace_status(overrides) do
    Map.merge(
      %{
        workspace: "demo",
        state: "running",
        healthy?: true,
        run_id: "run-123",
        control: control(),
        progress: %{},
        agent_control: nil,
        containment: %{state: :active, populated?: true, unit: "demo.service"},
        lease: %{state: :up, pid: 1234},
        last_progress_at: "2026-08-12T03:59:52Z"
      },
      overrides
    )
  end

  defp control(overrides \\ %{}) do
    Map.merge(
      %{
        "status" => "running",
        "prompt_id" => "03",
        "prompt_name" => "Build the runtime",
        "attempt" => 1,
        "mode" => "run",
        "provider" => "claude",
        "model" => "claude-opus-5",
        "prompt_elapsed_ms" => 913_506,
        "elapsed_ms" => 4_015_290,
        "tool_count" => 78,
        "event_count" => 719,
        "input_tokens" => 0,
        "output_tokens" => 0,
        "updated_at" => "2026-08-12T03:59:52Z"
      },
      overrides
    )
  end
end
