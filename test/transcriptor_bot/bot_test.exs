defmodule TranscriptorBot.BotTest do
  use ExUnit.Case, async: false
  use ExGram.Test

  alias ExGram.Model.{Chat, Message, Update, User, Voice}
  alias TranscriptorBot.{Bot, FakeQueue, FakeTelegram, Store}

  @owner 14_977_303

  setup context do
    dir = Path.join(System.tmp_dir!(), "bot_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    store = start_supervised!({Store, database_path: Path.join(dir, "db.sqlite3")})
    :ok = Store.ensure_owner(store, @owner)
    queue = start_supervised!({FakeQueue, []})
    telegram = FakeTelegram.client()

    previous = Application.get_env(:transcriptor_bot, :router_deps)

    Application.put_env(:transcriptor_bot, :router_deps, %{
      store: store,
      queue: queue,
      telegram: telegram,
      owner_id: @owner
    })

    {bot_name, _} = ExGram.Test.start_bot(context, Bot)

    on_exit(fn ->
      if previous do
        Application.put_env(:transcriptor_bot, :router_deps, previous)
      else
        Application.delete_env(:transcriptor_bot, :router_deps)
      end

      File.rm_rf!(dir)
    end)

    {:ok, bot_name: bot_name, telegram: telegram, queue: queue}
  end

  defp message(attrs) do
    %Message{
      message_id: 10,
      date: DateTime.utc_now(),
      chat: %Chat{id: attrs[:chat_id], type: attrs[:type], title: "Chat"},
      from: %User{id: attrs[:from], is_bot: false, first_name: "User"},
      text: attrs[:text],
      voice: attrs[:voice]
    }
  end

  defp update(message),
    do: %Update{update_id: System.unique_integer([:positive]), message: message}

  test "dispatches commands through ExGram to the router", %{bot_name: bot, telegram: telegram} do
    ExGram.Test.push_update(
      bot,
      update(message(chat_id: -100, type: "group", from: @owner, text: "/status"))
    )

    assert [{_chat, html, _opts}] = FakeTelegram.sent_html(telegram)
    assert html =~ "Pendientes"
  end

  test "enqueues private audio from an administrator", %{bot_name: bot, queue: queue} do
    voice = %Voice{file_id: "f", file_unique_id: "u", duration: 2, mime_type: "audio/ogg"}

    ExGram.Test.push_update(
      bot,
      update(message(chat_id: @owner, type: "private", from: @owner, voice: voice))
    )

    assert [_job] = FakeQueue.enqueued(queue)
  end

  test "ignores unrelated text", %{bot_name: bot, telegram: telegram} do
    ExGram.Test.push_update(
      bot,
      update(message(chat_id: -100, type: "group", from: @owner, text: "hola"))
    )

    assert FakeTelegram.sent_html(telegram) == []
  end
end
