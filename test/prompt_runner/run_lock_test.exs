defmodule PromptRunner.RunLockTest do
  use ExUnit.Case, async: true

  alias PromptRunner.RunLock

  test "parses process state and start time without being confused by spaces in comm" do
    prefix = "123 (provider process) S"
    fields_4_through_21 = Enum.map_join(4..21, " ", &Integer.to_string/1)
    stat = "#{prefix} #{fields_4_through_21} 987654 23 24\n"

    assert RunLock.parse_process_stat(stat) == {"S", "987654"}
  end

  test "exposes zombie state so stale lock handling cannot call it alive" do
    prefix = "123 (dead child) Z"
    fields_4_through_21 = Enum.map_join(4..21, " ", &Integer.to_string/1)
    stat = "#{prefix} #{fields_4_through_21} 123456 23 24\n"

    assert RunLock.parse_process_stat(stat) == {"Z", "123456"}
  end
end
