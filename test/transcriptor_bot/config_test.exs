defmodule TranscriptorBot.ConfigTest do
  use ExUnit.Case, async: false

  alias TranscriptorBot.Config

  setup do
    previous = Application.get_env(:transcriptor_bot, :owner_telegram_user_id)
    previous_env = System.get_env("OWNER_TELEGRAM_USER_ID")
    System.delete_env("OWNER_TELEGRAM_USER_ID")

    on_exit(fn ->
      Application.put_env(:transcriptor_bot, :owner_telegram_user_id, previous)

      if previous_env do
        System.put_env("OWNER_TELEGRAM_USER_ID", previous_env)
      end
    end)

    :ok
  end

  test "reads an integer owner id" do
    Application.put_env(:transcriptor_bot, :owner_telegram_user_id, 14_977_303)
    assert Config.owner_id() == 14_977_303
  end

  test "accepts a numeric string" do
    Application.put_env(:transcriptor_bot, :owner_telegram_user_id, "14977303")
    assert Config.owner_id() == 14_977_303
  end

  test "falls back to the environment variable when app config is absent" do
    Application.delete_env(:transcriptor_bot, :owner_telegram_user_id)
    System.put_env("OWNER_TELEGRAM_USER_ID", "14977303")

    assert Config.owner_id() == 14_977_303
  end

  test "raises for an invalid owner id" do
    Application.put_env(:transcriptor_bot, :owner_telegram_user_id, "not-a-number")
    assert_raise ArgumentError, fn -> Config.owner_id() end
  end

  test "raises for a non-positive owner id" do
    for invalid <- [0, -1, "0", "-1"] do
      Application.put_env(:transcriptor_bot, :owner_telegram_user_id, invalid)
      assert_raise ArgumentError, fn -> Config.owner_id() end
    end
  end

  test "raises when the owner id is missing" do
    Application.put_env(:transcriptor_bot, :owner_telegram_user_id, nil)
    assert_raise ArgumentError, fn -> Config.owner_id() end
  end
end
