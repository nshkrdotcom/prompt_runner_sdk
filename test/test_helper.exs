Logger.configure(level: :warning)

Mox.defmock(PromptRunner.LLMMock, for: PromptRunner.LLM)

ExUnit.start()
