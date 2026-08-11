defmodule Mix.Tasks.PromptRunner.MigrateContracts do
  @moduledoc "Migrates safely tokenizable legacy verifier commands to structured argv contracts."

  use Mix.Task

  alias PromptRunner.ContractMigration

  @shortdoc "Convert safely tokenizable legacy verifier commands to argv contracts"

  @impl Mix.Task
  def run(args) do
    {opts, remaining, invalid} = OptionParser.parse(args, strict: [write: :boolean])

    case {remaining, invalid} do
      {[packet], []} ->
        packet
        |> ContractMigration.migrate_packet(write: opts[:write] == true)
        |> report_migration()

      _other ->
        Mix.raise("usage: mix prompt_runner.migrate_contracts PACKET [--write]")
    end
  end

  defp report_migration({:ok, report}) do
    Mix.shell().info(Jason.encode!(report, pretty: true))

    if report.unresolved != [] do
      Mix.raise(
        "#{length(report.unresolved)} command(s) require an intentional typed replacement"
      )
    end
  end

  defp report_migration({:error, reason}), do: Mix.raise(inspect(reason))
end
