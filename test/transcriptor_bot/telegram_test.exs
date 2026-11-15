defmodule TranscriptorBot.TelegramTest do
  use ExUnit.Case, async: false
  use ExGram.Test

  alias TranscriptorBot.Telegram

  defp client(opts \\ []) do
    Telegram.client(
      Keyword.merge(
        [
          token: "test_token",
          base_url: "http://127.0.0.1:8081"
        ],
        opts
      )
    )
  end

  describe "send_html/4" do
    test "sends HTML and replies to the source message" do
      ExGram.Test.expect(:send_message, fn body ->
        assert body[:chat_id] == -100
        assert body[:text] == "<blockquote expandable>Hola.</blockquote>"
        assert body[:parse_mode] == "HTML"
        assert body[:reply_parameters].message_id == 77

        {:ok, %{message_id: 99}}
      end)

      assert {:ok, %{message_id: 99}} =
               Telegram.send_html(client(), -100, "<blockquote expandable>Hola.</blockquote>",
                 message_id: 77
               )
    end
  end

  describe "reactions" do
    test "adds and removes the eyes reaction" do
      ExGram.Test.expect(:set_message_reaction, fn body ->
        assert body[:chat_id] == -100
        assert body[:message_id] == 77
        assert [%{type: "emoji", emoji: "👀"}] = body[:reaction]
        {:ok, true}
      end)

      ExGram.Test.expect(:set_message_reaction, fn body ->
        assert body[:reaction] == []
        {:ok, true}
      end)

      assert :ok = Telegram.react(client(), -100, 77, "👀")
      assert :ok = Telegram.remove_reaction(client(), -100, 77)
    end

    test "swallows reaction errors because the reaction is best effort" do
      ExGram.Test.stub(:set_message_reaction, {:error, %ExGram.Error{message: "no reaction"}})

      assert :ok = Telegram.react(client(), -100, 77, "👀")
      assert :ok = Telegram.remove_reaction(client(), -100, 77)
    end
  end

  describe "file download" do
    test "uses the configured local Bot API base URL" do
      assert Telegram.file_url(client(), "voice/file_1.ogg") ==
               "http://127.0.0.1:8081/file/bottest_token/voice/file_1.ogg"
    end

    test "downloads to disk without loading the file into memory" do
      dest =
        Path.join(System.tmp_dir!(), "telegram_download_#{System.unique_integer([:positive])}")

      on_exit(fn -> File.rm(dest) end)

      Req.Test.stub(TranscriptorBot.TelegramStub, fn conn ->
        assert conn.request_path == "/file/bottest_token/voice/file_1.ogg"

        conn
        |> Plug.Conn.put_resp_content_type("application/octet-stream")
        |> Plug.Conn.send_resp(200, "audio-bytes")
      end)

      assert :ok =
               Telegram.download_file(
                 client(req_options: [plug: {Req.Test, TranscriptorBot.TelegramStub}]),
                 "voice/file_1.ogg",
                 dest
               )

      assert File.read!(dest) == "audio-bytes"
    end

    test "aborts a streaming download and deletes it immediately over the byte limit" do
      dest =
        Path.join(System.tmp_dir!(), "telegram_download_#{System.unique_integer([:positive])}")

      on_exit(fn -> File.rm(dest) end)

      Req.Test.stub(TranscriptorBot.TelegramStub, fn conn ->
        Plug.Conn.send_resp(conn, 200, String.duplicate("x", 100))
      end)

      assert {:error, :too_large} =
               Telegram.download_file(
                 client(req_options: [plug: {Req.Test, TranscriptorBot.TelegramStub}]),
                 "large.ogg",
                 dest,
                 10
               )

      refute File.exists?(dest)
    end

    test "returns an error for a non-200 response" do
      dest =
        Path.join(System.tmp_dir!(), "telegram_download_#{System.unique_integer([:positive])}")

      on_exit(fn -> File.rm(dest) end)

      Req.Test.stub(TranscriptorBot.TelegramStub, fn conn ->
        Plug.Conn.send_resp(conn, 404, "not found")
      end)

      assert {:error, {:http_status, 404}} =
               Telegram.download_file(
                 client(req_options: [plug: {Req.Test, TranscriptorBot.TelegramStub}]),
                 "missing.ogg",
                 dest
               )

      refute File.exists?(dest)
    end
  end

  describe "get_file/2" do
    test "returns the Telegram file path" do
      ExGram.Test.expect(:get_file, fn body ->
        assert body[:file_id] == "abc"
        {:ok, %{file_id: "abc", file_path: "voice/file_1.ogg", file_size: 10}}
      end)

      assert {:ok, %{file_path: "voice/file_1.ogg"}} = Telegram.get_file(client(), "abc")
    end
  end
end
