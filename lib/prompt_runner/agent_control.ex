defmodule PromptRunner.AgentControl do
  @moduledoc """
  Agent-directed control for a linear packet run.

  A provider may request that Prompt Runner continue to the next prompt, repeat
  the current prompt in a fresh session, finish the selected sequence, or stop
  because progress is blocked. Requests are scoped to one prompt iteration and
  are consumed only after that iteration satisfies its ordinary verifier.

  The provider may also publish a durable project cursor with `progress/3`.
  Progress is authenticated to the same invocation but stored separately: it
  can be refreshed repeatedly and never consumes the first-wins terminal
  request.

  Successful early finish remains verifier-owned: the packet's
  `completion_verify` contract must pass before the runner accepts `finish`.
  """

  alias PromptRunner.Plan
  alias PromptRunner.Prompt
  alias PromptRunner.Verifier

  @schema "prompt_runner.agent_control/request/v1"
  @progress_schema "prompt_runner.agent_control/progress/v1"
  @actions ~w(continue repeat finish blocked)
  @option_keys ~w(enabled default_action max_iterations completion_verify)
  @env_names ~w(
    PROMPT_RUNNER_AGENT_CONTROL_FILE
    PROMPT_RUNNER_AGENT_CONTROL_TOKEN
    PROMPT_RUNNER_RUN_ID
    PROMPT_RUNNER_PROMPT_ID
    PROMPT_RUNNER_PROMPT_ITERATION
  )
  @progress_env_name "PROMPT_RUNNER_AGENT_PROGRESS_FILE"

  @type action :: :continue | :repeat | :finish | :blocked

  @type config :: %{
          enabled?: boolean(),
          default_action: :continue | :repeat,
          max_iterations: pos_integer(),
          completion_verify: map()
        }

  @type invocation :: %{
          request_file: String.t(),
          progress_file: String.t(),
          token: String.t(),
          run_id: String.t(),
          prompt_id: String.t(),
          iteration: pos_integer()
        }

  @doc "Returns the normalized packet configuration."
  @spec config(Plan.t() | map() | nil) :: {:ok, config()} | {:error, term()}
  def config(%Plan{options: options}), do: config(option(options, :agent_control))

  def config(nil),
    do:
      {:ok,
       %{enabled?: false, default_action: :continue, max_iterations: 20, completion_verify: %{}}}

  def config(options) when is_map(options) do
    options = stringify_keys(options)

    %{
      unknown: Map.keys(options) -- @option_keys,
      enabled?: Map.get(options, "enabled", true),
      default_action: normalize_default_action(Map.get(options, "default_action", "continue")),
      default_action_input: options["default_action"],
      max_iterations: Map.get(options, "max_iterations", 20),
      completion_verify: stringify_keys(Map.get(options, "completion_verify", %{}))
    }
    |> validate_config()
  end

  def config(other), do: {:error, {:invalid_agent_control, other}}

  defp validate_config(%{unknown: [_ | _] = unknown}),
    do: {:error, {:unknown_agent_control_options, Enum.sort(unknown)}}

  defp validate_config(%{enabled?: enabled}) when not is_boolean(enabled),
    do: {:error, {:invalid_agent_control_enabled, enabled}}

  defp validate_config(%{default_action: :error, default_action_input: input}),
    do: {:error, {:invalid_agent_control_default_action, input}}

  defp validate_config(%{max_iterations: max_iterations})
       when not (is_integer(max_iterations) and max_iterations > 0),
       do: {:error, {:invalid_agent_control_max_iterations, max_iterations}}

  defp validate_config(%{enabled?: true, completion_verify: completion_verify})
       when not is_map(completion_verify),
       do: {:error, {:invalid_agent_control_completion_verify, completion_verify}}

  defp validate_config(%{enabled?: true, completion_verify: completion_verify} = config) do
    if Verifier.contract_items(completion_verify) == [] do
      {:error, :agent_control_completion_verify_required}
    else
      {:ok, Map.drop(config, [:unknown, :default_action_input])}
    end
  end

  defp validate_config(config), do: {:ok, Map.drop(config, [:unknown, :default_action_input])}

  @doc "Whether the plan enables agent-directed execution."
  @spec enabled?(Plan.t()) :: boolean()
  def enabled?(%Plan{} = plan) do
    case config(plan) do
      {:ok, %{enabled?: enabled?}} -> enabled?
      _other -> false
    end
  end

  @doc "Creates one fresh request scope for a prompt iteration."
  @spec prepare(String.t(), String.t(), String.t(), pos_integer()) ::
          {:ok, invocation()} | {:error, term()}
  def prepare(run_dir, run_id, prompt_id, iteration)
      when is_binary(run_dir) and is_binary(run_id) and is_binary(prompt_id) and
             is_integer(iteration) and iteration > 0 do
    token = random_token()
    request_dir = Path.join(run_dir, "agent-control")

    request_file =
      Path.join(
        request_dir,
        "#{safe_segment(prompt_id)}-#{iteration}-#{binary_part(token, 0, 12)}.json"
      )

    progress_file =
      Path.join(
        request_dir,
        "#{safe_segment(prompt_id)}-#{iteration}-#{binary_part(token, 0, 12)}.progress.json"
      )

    with :ok <- File.mkdir_p(request_dir) do
      {:ok,
       %{
         request_file: request_file,
         progress_file: progress_file,
         token: token,
         run_id: run_id,
         prompt_id: prompt_id,
         iteration: iteration
       }}
    end
  end

  @doc "Adds the invocation variables to the provider subprocess environment."
  @spec attach_llm(map(), invocation()) :: map()
  def attach_llm(llm, invocation) when is_map(llm) and is_map(invocation) do
    adapter_opts = normalize_map(Map.get(llm, :adapter_opts, %{}))
    env = normalize_map(Map.get(adapter_opts, :env, Map.get(adapter_opts, "env", %{})))

    control_env = %{
      "PROMPT_RUNNER_AGENT_CONTROL_FILE" => invocation.request_file,
      "PROMPT_RUNNER_AGENT_PROGRESS_FILE" => invocation.progress_file,
      "PROMPT_RUNNER_AGENT_CONTROL_TOKEN" => invocation.token,
      "PROMPT_RUNNER_RUN_ID" => invocation.run_id,
      "PROMPT_RUNNER_PROMPT_ID" => invocation.prompt_id,
      "PROMPT_RUNNER_PROMPT_ITERATION" => Integer.to_string(invocation.iteration)
    }

    adapter_opts =
      adapter_opts
      |> Map.delete("env")
      |> Map.put(:env, Map.merge(env, control_env))

    Map.put(llm, :adapter_opts, adapter_opts)
  end

  @doc "Appends the linear-control instructions sent to the provider."
  @spec decorate_prompt(String.t(), invocation(), config(), map() | nil) :: String.t()
  def decorate_prompt(body, invocation, config, finish_failure \\ nil)
      when is_binary(body) and is_map(invocation) and is_map(config) do
    executable = System.find_executable("prompt_runner") || "prompt_runner"

    failure_text =
      case finish_failure do
        %{failures: failures} when is_list(failures) and failures != [] ->
          """

          Your previous `finish` request was rejected because the packet-level
          completion contract did not pass. Resolve these items before requesting
          `finish` again:

          #{Jason.encode!(failures, pretty: true)}
          """

        _other ->
          ""
      end

    body <>
      """

      ## Prompt Runner agent control

      This is iteration #{invocation.iteration} of at most #{config.max_iterations} for
      prompt #{invocation.prompt_id}. After determining the current project cursor,
      report it with `#{executable} agent-control progress --cursor CURSOR --summary
      "exact work now in progress"` (add `--unit UNIT` when useful). Refresh that
      progress after coherent milestones and once more immediately before the terminal
      directive. Progress is informational and does not end the iteration.

      After the work, verification, handoff, commits, and pushes for this iteration are
      complete, choose at most one terminal directive:

      - `#{executable} agent-control continue`
      - `#{executable} agent-control repeat --reason "CURSOR unit COMPLETED is complete; next is CURSOR unit NEXT: exact next action"`
      - `#{executable} agent-control finish --reason "the full packet objective is complete"`
      - `#{executable} agent-control blocked --reason "exact external blocker"`

      `finish` is accepted only when the packet-level `completion_verify` contract
      passes. If you issue no directive, Prompt Runner uses `#{config.default_action}`.
      Do not kill the runner or its parent process.
      #{failure_text}
      """
  end

  @doc "Writes one directive from inside the provider subprocess."
  @spec request(action() | String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def request(action, opts \\ []) do
    env = Keyword.get(opts, :env, System.get_env())
    reason = opts |> Keyword.get(:reason) |> normalize_reason()

    with {:ok, action} <- normalize_action(action),
         :ok <- require_reason(action, reason),
         {:ok, context} <- request_context(env),
         request = request_document(context, action, reason),
         :ok <- write_request(context.request_file, request) do
      {:ok,
       %{
         action: action,
         reason: reason,
         run_id: context.run_id,
         prompt_id: context.prompt_id,
         iteration: context.iteration
       }}
    end
  end

  @doc "Atomically publishes nonterminal progress from inside the provider subprocess."
  @spec progress(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def progress(cursor, summary, opts \\ []) do
    env = Keyword.get(opts, :env, System.get_env())
    cursor = normalize_text(cursor)
    summary = normalize_text(summary)
    unit = opts |> Keyword.get(:unit) |> normalize_text()

    with :ok <- require_progress_value(:cursor, cursor),
         :ok <- require_progress_value(:summary, summary),
         {:ok, context} <- progress_context(env),
         record = progress_document(context, cursor, unit, summary),
         :ok <- write_progress(context.progress_file, record) do
      {:ok,
       %{
         schema: record["schema"],
         run_id: record["run_id"],
         prompt_id: record["prompt_id"],
         iteration: record["iteration"],
         cursor: record["cursor"],
         unit: record["unit"],
         summary: record["summary"],
         updated_at: record["updated_at"]
       }}
    end
  end

  @doc "Reads and authenticates the progress record for one invocation."
  @spec read_progress(invocation()) :: {:ok, map() | nil} | {:error, term()}
  def read_progress(invocation) when is_map(invocation) do
    case File.read(invocation.progress_file) do
      {:error, :enoent} ->
        {:ok, nil}

      {:error, reason} ->
        {:error, {:agent_control_progress_unreadable, reason}}

      {:ok, contents} ->
        with {:ok, record} <- Jason.decode(contents),
             true <- progress_matches?(record, invocation) do
          {:ok, Map.drop(record, ["token"])}
        else
          false -> {:error, :agent_control_progress_mismatch}
          {:error, %Jason.DecodeError{}} -> {:error, :agent_control_progress_invalid_json}
        end
    end
  end

  @doc false
  @spec latest_progress(String.t(), String.t(), String.t()) :: map() | nil
  def latest_progress(run_dir, run_id, prompt_id)
      when is_binary(run_dir) and is_binary(run_id) and is_binary(prompt_id) do
    run_dir
    |> Path.join("agent-control/*.progress.json")
    |> Path.wildcard()
    |> Enum.flat_map(&read_public_progress/1)
    |> Enum.filter(&(&1["run_id"] == run_id and &1["prompt_id"] == prompt_id))
    |> Enum.max_by(&{&1["iteration"] || 0, &1["updated_at"] || ""}, fn -> nil end)
  end

  def latest_progress(_run_dir, _run_id, _prompt_id), do: nil

  @doc "Reads and authenticates the request for one invocation."
  @spec consume(invocation()) :: {:ok, map() | nil} | {:error, term()}
  def consume(invocation) when is_map(invocation) do
    case File.read(invocation.request_file) do
      {:error, :enoent} ->
        {:ok, nil}

      {:error, reason} ->
        {:error, {:agent_control_request_unreadable, reason}}

      {:ok, contents} ->
        with {:ok, request} <- Jason.decode(contents),
             true <- request_matches?(request, invocation),
             {:ok, action} <- normalize_action(request["action"]) do
          {:ok,
           %{
             action: action,
             reason: request["reason"],
             run_id: request["run_id"],
             prompt_id: request["prompt_id"],
             iteration: request["iteration"],
             requested_at: request["requested_at"],
             request_file: invocation.request_file
           }}
        else
          false -> {:error, :agent_control_request_mismatch}
          {:error, %Jason.DecodeError{}} -> {:error, :agent_control_request_invalid_json}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  @doc false
  @spec reset_request(map() | nil) :: :ok | {:error, term()}
  def reset_request(%{request_file: path}) when is_binary(path) do
    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, {:agent_control_request_reset_failed, reason}}
    end
  end

  def reset_request(_invocation), do: :ok

  @doc "Runs the packet-level completion contract."
  @spec completion_report(Plan.t(), config()) :: Verifier.report()
  def completion_report(%Plan{} = plan, %{completion_verify: contract}) do
    target_repos =
      plan.config.target_repos
      |> List.wrap()
      |> Enum.map(& &1.name)

    prompt = %Prompt{
      num: "agent-control-finish",
      phase: 0,
      sp: 0,
      name: "Agent-control completion",
      body: "",
      target_repos: target_repos,
      validation_commands: [],
      verify: contract,
      metadata: %{}
    }

    Verifier.verify_prompt(plan, prompt, amendments: false)
  end

  @doc "Returns the explicit request or the configured default."
  @spec requested_action(map() | nil, config()) :: action()
  def requested_action(nil, config), do: config.default_action
  def requested_action(%{action: action}, _config), do: action

  defp request_context(env) when is_map(env) do
    missing = Enum.reject(@env_names, &present?(Map.get(env, &1)))

    if missing == [] do
      case Integer.parse(env["PROMPT_RUNNER_PROMPT_ITERATION"]) do
        {iteration, ""} ->
          {:ok,
           %{
             request_file: env["PROMPT_RUNNER_AGENT_CONTROL_FILE"],
             progress_file: env["PROMPT_RUNNER_AGENT_PROGRESS_FILE"],
             token: env["PROMPT_RUNNER_AGENT_CONTROL_TOKEN"],
             run_id: env["PROMPT_RUNNER_RUN_ID"],
             prompt_id: env["PROMPT_RUNNER_PROMPT_ID"],
             iteration: iteration
           }}

        _other ->
          {:error, :agent_control_iteration_invalid}
      end
    else
      {:error, {:agent_control_environment_missing, missing}}
    end
  end

  defp request_context(_env), do: {:error, {:agent_control_environment_missing, @env_names}}

  defp progress_context(env) do
    with {:ok, context} <- request_context(env),
         progress_file when is_binary(progress_file) and progress_file != "" <-
           env[@progress_env_name] do
      {:ok, Map.put(context, :progress_file, progress_file)}
    else
      nil -> {:error, {:agent_control_environment_missing, [@progress_env_name]}}
      "" -> {:error, {:agent_control_environment_missing, [@progress_env_name]}}
      {:error, _reason} = error -> error
    end
  end

  defp request_document(context, action, reason) do
    %{
      "schema" => @schema,
      "token" => context.token,
      "run_id" => context.run_id,
      "prompt_id" => context.prompt_id,
      "iteration" => context.iteration,
      "action" => Atom.to_string(action),
      "reason" => reason,
      "requested_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end

  defp progress_document(context, cursor, unit, summary) do
    %{
      "schema" => @progress_schema,
      "token" => context.token,
      "run_id" => context.run_id,
      "prompt_id" => context.prompt_id,
      "iteration" => context.iteration,
      "cursor" => cursor,
      "unit" => unit,
      "summary" => summary,
      "updated_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end

  defp write_request(path, request) do
    if File.dir?(Path.dirname(path)) do
      write_request_file(path, request)
    else
      {:error, :agent_control_request_scope_missing}
    end
  end

  defp write_request_file(path, request) do
    result =
      File.open(path, [:write, :exclusive, :binary], fn io ->
        :ok = IO.binwrite(io, Jason.encode!(request, pretty: true))
        :file.sync(io)
      end)

    case result do
      {:ok, :ok} -> :ok
      {:ok, {:error, reason}} -> {:error, {:agent_control_request_write_failed, reason}}
      {:error, :eexist} -> {:error, :agent_control_request_already_exists}
      {:error, reason} -> {:error, {:agent_control_request_write_failed, reason}}
    end
  end

  defp write_progress(path, record) do
    if File.dir?(Path.dirname(path)) do
      atomic_write(path, Jason.encode!(record, pretty: true))
    else
      {:error, :agent_control_progress_scope_missing}
    end
  end

  defp atomic_write(path, contents) do
    temp = path <> ".tmp.#{System.unique_integer([:positive, :monotonic])}"

    try do
      with :ok <- File.write(temp, contents, [:binary, :sync]),
           :ok <- File.rename(temp, path) do
        :ok
      else
        {:error, reason} -> {:error, {:agent_control_progress_write_failed, reason}}
      end
    after
      _ = File.rm(temp)
    end
  end

  defp request_matches?(request, invocation) do
    request["schema"] == @schema and
      request["token"] == invocation.token and
      request["run_id"] == invocation.run_id and
      request["prompt_id"] == invocation.prompt_id and
      request["iteration"] == invocation.iteration
  end

  defp progress_matches?(record, invocation) do
    record["schema"] == @progress_schema and
      record["token"] == invocation.token and
      record["run_id"] == invocation.run_id and
      record["prompt_id"] == invocation.prompt_id and
      record["iteration"] == invocation.iteration and
      present?(record["cursor"]) and present?(record["summary"])
  end

  defp read_public_progress(path) do
    with {:ok, contents} <- File.read(path),
         {:ok, %{"schema" => @progress_schema} = record} <- Jason.decode(contents),
         true <- present?(record["token"]),
         true <- progress_filename_matches?(path, record["token"]),
         true <- present?(record["run_id"]),
         true <- present?(record["prompt_id"]),
         true <- is_integer(record["iteration"]) and record["iteration"] > 0,
         true <- present?(record["cursor"]),
         true <- present?(record["summary"]) do
      [Map.drop(record, ["token"])]
    else
      _other -> []
    end
  end

  defp progress_filename_matches?(path, token) do
    String.ends_with?(
      Path.basename(path),
      "-#{binary_part(token, 0, min(byte_size(token), 12))}.progress.json"
    )
  end

  defp require_progress_value(name, value) do
    if present?(value), do: :ok, else: {:error, {:agent_control_progress_required, name}}
  end

  defp require_reason(action, reason) when action in [:finish, :blocked] do
    if present?(reason), do: :ok, else: {:error, :agent_control_reason_required}
  end

  defp require_reason(_action, _reason), do: :ok

  defp normalize_action(action) when is_atom(action), do: normalize_action(Atom.to_string(action))

  defp normalize_action(action) when is_binary(action) do
    case action |> String.trim() |> String.downcase() |> String.replace("_", "-") do
      "continue" -> {:ok, :continue}
      "repeat" -> {:ok, :repeat}
      "finish" -> {:ok, :finish}
      "blocked" -> {:ok, :blocked}
      "stop-blocked" -> {:ok, :blocked}
      other -> {:error, {:invalid_agent_control_action, other, @actions}}
    end
  end

  defp normalize_action(other), do: {:error, {:invalid_agent_control_action, other, @actions}}

  defp normalize_default_action(value) do
    case normalize_action(value) do
      {:ok, action} when action in [:continue, :repeat] -> action
      _other -> :error
    end
  end

  defp normalize_reason(nil), do: nil
  defp normalize_reason(reason), do: reason |> to_string() |> String.trim() |> blank_to_nil()

  defp normalize_text(nil), do: nil
  defp normalize_text(value), do: value |> to_string() |> String.trim() |> blank_to_nil()

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  defp option(options, key) when is_map(options),
    do: Map.get(options, key, Map.get(options, Atom.to_string(key)))

  defp normalize_map(value) when is_map(value), do: value
  defp normalize_map(_value), do: %{}

  defp stringify_keys(value) when is_map(value) do
    Map.new(value, fn {key, child} -> {to_string(key), stringify_keys(child)} end)
  end

  defp stringify_keys(value) when is_list(value), do: Enum.map(value, &stringify_keys/1)
  defp stringify_keys(value), do: value

  defp safe_segment(value) do
    value |> to_string() |> String.replace(~r/[^A-Za-z0-9_.-]/, "-")
  end

  defp random_token, do: :crypto.strong_rand_bytes(24) |> Base.url_encode64(padding: false)
end
