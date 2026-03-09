defmodule PromptRunner.Observer.PubSub do
  @moduledoc """
  Convenience helpers for broadcasting PromptRunner events through `Phoenix.PubSub`.
  """

  @spec callback(module(), String.t()) :: (map() -> term())
  def callback(pubsub, topic) do
    fn event -> broadcast(pubsub, topic, event) end
  end

  @spec broadcast(module(), String.t(), map()) :: :ok | {:error, term()}
  def broadcast(pubsub, topic, event) do
    if Code.ensure_loaded?(Phoenix.PubSub) do
      apply(Phoenix.PubSub, :broadcast, [pubsub, topic, {:prompt_runner, event}])
    else
      {:error, :phoenix_pubsub_not_available}
    end
  end
end
