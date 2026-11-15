defmodule TranscriptorBot.ApplicationTest do
  use ExUnit.Case, async: false

  alias TranscriptorBot.Application

  setup do
    previous = Elixir.Application.get_env(:transcriptor_bot, :start_bot)
    on_exit(fn -> Elixir.Application.put_env(:transcriptor_bot, :start_bot, previous) end)
    :ok
  end

  test "starts no bot children when start_bot is false" do
    Elixir.Application.put_env(:transcriptor_bot, :start_bot, false)
    assert Application.children() == []
  end

  test "production runtime requires OWNER_TELEGRAM_USER_ID" do
    runtime = File.read!(Path.join(File.cwd!(), "config/runtime.exs"))
    assert runtime =~ "System.fetch_env!(\"OWNER_TELEGRAM_USER_ID\")"
    refute runtime =~ "System.get_env(\"OWNER_TELEGRAM_USER_ID\","
  end

  test "starts store, ExGram, queue and bot in order when enabled" do
    Elixir.Application.put_env(:transcriptor_bot, :start_bot, true)
    children = Application.children()

    ids =
      Enum.map(children, fn
        {module, _opts} -> module
        module -> module
      end)

    assert TranscriptorBot.Store in ids
    assert ExGram in ids
    assert TranscriptorBot.Queue in ids
    assert TranscriptorBot.Bot in ids

    assert Enum.find_index(ids, &(&1 == TranscriptorBot.Store)) <
             Enum.find_index(ids, &(&1 == TranscriptorBot.Queue))

    assert Enum.find_index(ids, &(&1 == TranscriptorBot.Queue)) <
             Enum.find_index(ids, &(&1 == TranscriptorBot.Bot))

    bot_entry =
      Enum.find(children, fn
        {module, _opts} -> module == TranscriptorBot.Bot
        module -> module == TranscriptorBot.Bot
      end)

    {_module, bot_opts} = bot_entry
    assert bot_opts[:method] == :polling
    assert bot_opts[:token] == "test_token"
  end
end
