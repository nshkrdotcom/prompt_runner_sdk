defmodule PromptRunner.Phase5PrelimCommonRuntimeTest do
  use ExUnit.Case, async: false

  alias PromptRunner.Session

  @config_app :cli_subprocess_core
  @config_key :provider_runtime_profiles

  setup do
    previous = Application.get_env(@config_app, @config_key)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(@config_app, @config_key)
        value -> Application.put_env(@config_app, @config_key, value)
      end
    end)

    Application.delete_env(@config_app, @config_key)
    :ok
  end

  test "prompt runner streams through ASM and CLI core configured runtime profiles" do
    profiles =
      Map.new(provider_cases(), fn {provider, scenario_ref, line, _content} ->
        {provider,
         [
           scenario_ref: scenario_ref,
           stdout_frames: [line],
           exit: :normal,
           observability: %{packet: :phase5prelim}
         ]}
      end)

    Application.put_env(@config_app, @config_key, profiles: profiles)

    Enum.each(provider_cases(), fn {provider, _scenario_ref, _line, content} ->
      llm = %{
        provider: Atom.to_string(provider),
        model: model_for(provider),
        cwd: File.cwd!(),
        permission_mode: :bypass,
        timeout: 5_000
      }

      assert {:ok, stream, close_fun, meta} =
               Session.start_stream(llm, "phase5prelim common runtime")

      events = Enum.take(stream, 10)
      close_fun.()

      assert meta.session_opts[:provider] == provider
      assert meta.session_opts[:lane] == :core

      assert Enum.any?(events, fn
               %{type: :run_started, data: %{command: command}} ->
                 command == "cli-subprocess-core-lower-simulation-#{provider}"

               _event ->
                 false
             end)

      assert Enum.any?(events, fn
               %{type: :message_streamed, data: %{delta: ^content}} -> true
               _event -> false
             end)
    end)
  end

  test "required common runtime profiles fail before provider CLI spawn" do
    Application.put_env(@config_app, @config_key, required?: true, profiles: %{})

    assert {:ok, stream, close_fun, _meta} =
             Session.start_stream(
               %{
                 provider: "gemini",
                 model: model_for(:gemini),
                 cwd: File.cwd!(),
                 permission_mode: :bypass
               },
               "must not spawn"
             )

    try do
      assert_raise ASM.Error, ~r/provider runtime profile required/, fn ->
        Enum.take(stream, 1)
      end
    after
      close_fun.()
    end
  end

  defp provider_cases do
    [
      {:claude, "phase5prelim://prompt-runner/claude",
       ~s({"type":"assistant_delta","delta":"claude prompt runner","session_id":"claude-pr"}\n),
       "claude prompt runner"},
      {:codex, "phase5prelim://prompt-runner/codex",
       ~s({"type":"response.output_text.delta","delta":"codex prompt runner","session_id":"codex-pr"}\n),
       "codex prompt runner"},
      {:gemini, "phase5prelim://prompt-runner/gemini",
       ~s({"type":"message","role":"assistant","delta":true,"content":"gemini prompt runner","session_id":"gemini-pr"}\n),
       "gemini prompt runner"},
      {:amp, "phase5prelim://prompt-runner/amp",
       ~s({"type":"message_streamed","delta":"amp prompt runner","session_id":"amp-pr"}\n),
       "amp prompt runner"}
    ]
  end

  defp model_for(:claude), do: "sonnet"
  defp model_for(:codex), do: "gpt-5.4"
  defp model_for(:gemini), do: "gemini-2.5-pro"
  defp model_for(:amp), do: "amp-1"
end
