defmodule TranscriptorBot.RouterTest do
  use ExUnit.Case, async: true

  alias ExGram.Model.{Chat, Document, Message, Update, User, Voice}
  alias TranscriptorBot.{FakeQueue, FakeTelegram, Router, Store}

  @owner 14_977_303
  @admin 500
  @member 900

  setup do
    dir = Path.join(System.tmp_dir!(), "router_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    store = start_supervised!({Store, database_path: Path.join(dir, "db.sqlite3")})
    :ok = Store.ensure_owner(store, @owner)
    :ok = Store.add_admin(store, @admin)
    queue = start_supervised!({FakeQueue, []})
    telegram = FakeTelegram.client()

    on_exit(fn -> File.rm_rf!(dir) end)

    {:ok, deps: %{store: store, queue: queue, telegram: telegram, owner_id: @owner}, store: store}
  end

  defp user(id) do
    %User{id: id, is_bot: false, first_name: "User #{id}", username: "user#{id}"}
  end

  defp message(chat_id, chat_type, from_id, attrs \\ []) do
    %Message{
      message_id: Keyword.get(attrs, :message_id, 10),
      date: DateTime.utc_now(),
      chat: %Chat{id: chat_id, type: chat_type, title: "Chat"},
      from: user(from_id),
      text: Keyword.get(attrs, :text),
      voice: Keyword.get(attrs, :voice),
      audio: Keyword.get(attrs, :audio),
      document: Keyword.get(attrs, :document),
      reply_to_message: Keyword.get(attrs, :reply_to_message)
    }
  end

  defp update(message),
    do: %Update{update_id: System.unique_integer([:positive]), message: message}

  defp handle(deps, message), do: Router.handle(update(message), deps)

  defp texts(telegram) do
    telegram |> FakeTelegram.sent_html() |> Enum.map(fn {_chat, html, _opts} -> html end)
  end

  defp last_text(telegram), do: List.last(texts(telegram))

  defp voice_message(chat_id, chat_type, from_id, attrs \\ []) do
    voice = %Voice{
      file_id: "voice-file",
      file_unique_id: "voice-unique",
      duration: 3,
      mime_type: "audio/ogg",
      file_size: 1_000
    }

    message(chat_id, chat_type, from_id, Keyword.put(attrs, :voice, voice))
  end

  describe "group authorization commands" do
    test "an admin allows a group, activating it", %{deps: deps, store: store} do
      handle(deps, message(-100, "group", @admin, text: "/allow"))

      assert %{allowed: true, enabled: true} = Store.chat_state(store, -100)
      assert last_text(deps.telegram) =~ "autorizado"
    end

    test "a non-admin cannot allow a group", %{deps: deps, store: store} do
      handle(deps, message(-100, "group", @member, text: "/allow"))

      assert Store.chat_state(store, -100) == nil
      assert last_text(deps.telegram) =~ "administradores"
    end

    test "deny revokes authorization", %{deps: deps, store: store} do
      :ok = Store.allow(store, -100)

      handle(deps, message(-100, "group", @admin, text: "/deny"))

      assert %{allowed: false, enabled: false} = Store.chat_state(store, -100)
    end

    test "disable keeps authorization and enable restores it", %{deps: deps, store: store} do
      :ok = Store.allow(store, -100)

      handle(deps, message(-100, "group", @admin, text: "/disable"))
      assert %{allowed: true, enabled: false} = Store.chat_state(store, -100)
      assert last_text(deps.telegram) =~ "desactivado"

      handle(deps, message(-100, "group", @admin, text: "/enable"))
      assert %{allowed: true, enabled: true} = Store.chat_state(store, -100)
      assert last_text(deps.telegram) =~ "activado"
    end

    test "enable on an unauthorized group explains /allow", %{deps: deps, store: store} do
      handle(deps, message(-100, "group", @admin, text: "/enable"))

      assert Store.chat_state(store, -100) == nil
      assert last_text(deps.telegram) =~ "/allow"
    end

    test "group commands are rejected in private chat", %{deps: deps, store: store} do
      handle(deps, message(@admin, "private", @admin, text: "/allow"))

      assert Store.chat_state(store, @admin) == nil
      assert last_text(deps.telegram) =~ "solo funciona en grupos"
    end

    test "commands accept a bot username suffix", %{deps: deps, store: store} do
      handle(deps, message(-100, "group", @admin, text: "/allow@transcriptor_bot"))

      assert %{allowed: true} = Store.chat_state(store, -100)
    end
  end

  describe "administrator management" do
    test "the owner adds a user by replying to their message", %{deps: deps, store: store} do
      reply = message(-100, "group", @member)

      handle(
        deps,
        message(-100, "group", @owner,
          text: "/admin_add",
          reply_to_message: reply
        )
      )

      assert Store.admin?(store, @member)
      assert last_text(deps.telegram) =~ "Administrador añadido"
    end

    test "admin_add without a reply explains how to use it", %{deps: deps, store: store} do
      handle(deps, message(-100, "group", @owner, text: "/admin_add"))

      refute Store.admin?(store, @member)
      assert last_text(deps.telegram) =~ "Responde"
    end

    test "only the owner can manage administrators", %{deps: deps, store: store} do
      reply = message(-100, "group", @member)

      handle(
        deps,
        message(-100, "group", @admin, text: "/admin_add", reply_to_message: reply)
      )

      refute Store.admin?(store, @member)
      assert last_text(deps.telegram) =~ "propietario"
    end

    test "the owner can remove an administrator", %{deps: deps, store: store} do
      reply = message(-100, "group", @admin)

      handle(
        deps,
        message(-100, "group", @owner,
          text: "/admin_remove",
          reply_to_message: reply
        )
      )

      refute Store.admin?(store, @admin)
      assert last_text(deps.telegram) =~ "eliminado"
    end

    test "the owner cannot be removed", %{deps: deps, store: store} do
      reply = message(-100, "group", @owner)

      handle(
        deps,
        message(-100, "group", @owner,
          text: "/admin_remove",
          reply_to_message: reply
        )
      )

      assert Store.admin?(store, @owner)
      assert last_text(deps.telegram) =~ "no se puede eliminar"
    end
  end

  describe "private audio" do
    test "preserves Telegram's update_id when enqueueing", %{deps: deps} do
      message = voice_message(@admin, "private", @admin)
      assert :ok = Router.handle(%Update{update_id: 987_654, message: message}, deps)

      assert [%{update_id: 987_654, message_id: 10}] = FakeQueue.enqueued(deps.queue)
    end

    test "an administrator can enqueue private audio", %{deps: deps} do
      handle(deps, voice_message(@admin, "private", @admin))

      assert [job] = FakeQueue.enqueued(deps.queue)
      assert job.file_id == "voice-file"
      assert job.kind == "voice"
      assert job.chat_id == @admin
      assert {:react, @admin, 10, "👀"} in FakeTelegram.reactions(deps.telegram)
    end

    test "a non-administrator cannot enqueue private audio", %{deps: deps} do
      handle(deps, voice_message(@member, "private", @member))

      assert FakeQueue.enqueued(deps.queue) == []
      assert last_text(deps.telegram) =~ "Solo los administradores"
    end

    test "the owner is an administrator", %{deps: deps} do
      handle(deps, voice_message(@owner, "private", @owner))

      assert [_job] = FakeQueue.enqueued(deps.queue)
    end
  end

  describe "group audio" do
    setup %{store: store} do
      :ok = Store.allow(store, -100)
      :ok
    end

    test "any member can enqueue audio in an authorized active group", %{deps: deps} do
      handle(deps, voice_message(-100, "supergroup", @member))

      assert [job] = FakeQueue.enqueued(deps.queue)
      assert job.chat_id == -100
      assert job.requested_by == @member
    end

    test "audio is rejected when the group is disabled", %{deps: deps, store: store} do
      :ok = Store.disable(store, -100)

      handle(deps, voice_message(-100, "group", @member))

      assert FakeQueue.enqueued(deps.queue) == []
      assert last_text(deps.telegram) =~ "desactivado"
    end

    test "audio is rejected when the group is not authorized", %{deps: deps, store: store} do
      :ok = Store.deny(store, -100)

      handle(deps, voice_message(-100, "group", @member))

      assert FakeQueue.enqueued(deps.queue) == []
      assert last_text(deps.telegram) =~ "no está autorizado"
    end

    test "audio files sent as documents are accepted", %{deps: deps} do
      document = %Document{
        file_id: "doc-file",
        file_unique_id: "doc-unique",
        file_name: "recording.mp3",
        mime_type: "audio/mpeg",
        file_size: 2_000
      }

      handle(deps, message(-100, "group", @member, document: document))

      assert [job] = FakeQueue.enqueued(deps.queue)
      assert job.kind == "document"
      assert job.mime_type == "audio/mpeg"
    end

    test "audio messages are accepted in an authorized group", %{deps: deps} do
      audio = %ExGram.Model.Audio{
        file_id: "audio-file",
        file_unique_id: "audio-unique",
        duration: 5,
        mime_type: "audio/mpeg",
        file_name: "song.mp3"
      }

      handle(deps, message(-100, "group", @member, audio: audio))

      assert [job] = FakeQueue.enqueued(deps.queue)
      assert job.kind == "audio"
      assert job.file_id == "audio-file"
      assert job.duration_ms == 5_000
    end

    test "non-audio documents are ignored", %{deps: deps} do
      document = %Document{
        file_id: "doc-file",
        file_unique_id: "doc-unique",
        file_name: "notes.pdf",
        mime_type: "application/pdf",
        file_size: 2_000
      }

      assert :ignored = handle(deps, message(-100, "group", @member, document: document))
      assert FakeQueue.enqueued(deps.queue) == []
    end

    test "a full queue produces a short Spanish reply", %{deps: deps} do
      :ok = FakeQueue.set_full(deps.queue, true)

      handle(deps, voice_message(-100, "group", @member))

      assert last_text(deps.telegram) =~ "cola está llena"
      assert FakeTelegram.reactions(deps.telegram) == []
    end
  end

  describe "status" do
    test "reports queue state in a group", %{deps: deps, store: store} do
      :ok = Store.allow(store, -100)

      handle(deps, message(-100, "group", @member, text: "/status"))

      text = last_text(deps.telegram)
      assert text =~ "autorizado"
      assert text =~ "activo"
      assert text =~ "Pendientes: 0"
    end

    test "reports queue state in private", %{deps: deps} do
      handle(deps, message(@admin, "private", @admin, text: "/status"))

      assert last_text(deps.telegram) =~ "Pendientes: 0"
    end
  end

  describe "unrelated updates" do
    test "plain text is ignored", %{deps: deps} do
      assert :ignored = handle(deps, message(-100, "group", @member, text: "hola"))
      assert texts(deps.telegram) == []
    end

    test "updates without a message are ignored", %{deps: deps} do
      assert :ignored = Router.handle(%Update{update_id: 1}, deps)
    end
  end
end
