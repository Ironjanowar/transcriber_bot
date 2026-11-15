defmodule TranscriptorBot.WorkerTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias TranscriptorBot.{FakeMedia, FakeTelegram, FakeTranscriber, Formatting, Store, Worker}

  setup do
    dir = Path.join(System.tmp_dir!(), "worker_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    telegram = FakeTelegram.client()
    {:ok, dir: dir, telegram: telegram, deps: deps(dir, telegram)}
  end

  defp deps(dir, telegram, overrides \\ []) do
    Keyword.merge(
      [
        telegram: telegram,
        media: FakeMedia,
        transcriber: FakeTranscriber,
        media_opts: [test: self()],
        transcriber_opts: [test: self()],
        work_dir: dir,
        max_file_bytes: 500 * 1024 * 1024,
        max_duration_ms: 3_600_000,
        reaction_emoji: "👀",
        send_interval_ms: 0
      ],
      overrides
    )
  end

  defp job(attrs \\ []) do
    struct!(
      Store.Job,
      Enum.into(attrs, %{
        id: System.unique_integer([:positive]),
        chat_id: -100,
        message_id: 77,
        file_id: "voice-file",
        file_unique_id: "unique",
        kind: "voice",
        requested_by: 42,
        status: "running"
      })
    )
  end

  defp texts(telegram) do
    telegram |> FakeTelegram.sent_html() |> Enum.map(fn {_chat, html, opts} -> {html, opts} end)
  end

  test "downloads, validates, normalizes and transcribes in order", %{
    deps: deps,
    telegram: telegram,
    dir: dir
  } do
    job = job()

    assert :ok = Worker.perform(job, deps)
    assert_received {:probe, downloaded}
    assert downloaded =~ dir
    assert_received {:normalize, ^downloaded, wav}
    assert wav =~ dir
    assert String.ends_with?(wav, "audio.wav")
    assert_received {:transcribe, ^wav, 1_000}

    assert [
             {:get_file, "voice-file"},
             {:download_file, "voice/file_1.ogg", ^downloaded},
             {:send_html, -100, html, opts},
             {:remove_reaction, -100, 77}
           ] = FakeTelegram.calls(telegram)

    assert html == "<blockquote expandable>Hola mundo.</blockquote>"
    assert opts[:message_id] == 77
    assert File.ls!(dir) == []
  end

  test "sends the Spanish empty-transcript message", %{deps: deps, telegram: telegram} do
    deps = deps |> Keyword.put(:transcriber_opts, fun: fn _, _ -> {:ok, "   "} end)
    assert :ok = Worker.perform(job(), deps)

    assert [{html, _opts}] = texts(telegram)
    assert html == "No se detectó voz en el audio."
  end

  test "rejects a file whose actual size exceeds the limit", %{deps: deps, telegram: telegram} do
    deps = Keyword.put(deps, :max_file_bytes, 5)

    assert {:error, :too_large, :permanent} = Worker.perform(job(), deps)
    refute_received {:probe, _}
    assert [{html, _}] = texts(telegram)
    assert html =~ "No se pudo transcribir"
    assert {:remove_reaction, -100, 77} in FakeTelegram.reactions(telegram)
  end

  test "rejects audio longer than one hour", %{deps: deps, telegram: telegram} do
    deps = Keyword.put(deps, :media_opts, test: self(), probe: fn _ -> {:ok, 3_600_001} end)

    assert {:error, :too_long, :permanent} = Worker.perform(job(), deps)
    refute_received {:normalize, _, _}
    assert [{_html, _}] = texts(telegram)
  end

  test "retries a download failure without sending a final message", %{
    deps: deps,
    telegram: telegram
  } do
    FakeTelegram.put(telegram, :download, {:error, :timeout})

    assert {:error, :timeout, :retryable} = Worker.perform(job(), deps)
    assert texts(telegram) == []
    refute {:remove_reaction, -100, 77} in FakeTelegram.reactions(telegram)
  end

  test "retries ffmpeg failures", %{deps: deps} do
    deps = Keyword.put(deps, :media_opts, test: self(), normalize: fn _, _ -> {:error, :boom} end)

    assert {:error, :boom, :retryable} = Worker.perform(job(), deps)
  end

  test "retries transcriber failures and timeouts", %{deps: deps} do
    deps = Keyword.put(deps, :transcriber_opts, fun: fn _, _ -> {:error, :timeout} end)
    assert {:error, :timeout, :retryable} = Worker.perform(job(), deps)

    deps = Keyword.put(deps, :transcriber_opts, fun: fn _, _ -> {:error, {:exit, 2}} end)
    assert {:error, {:exit, 2}, :retryable} = Worker.perform(job(), deps)
  end

  test "treats a missing transcriber command as permanent", %{deps: deps, telegram: telegram} do
    deps = Keyword.put(deps, :transcriber_opts, fun: fn _, _ -> {:error, :not_configured} end)

    assert {:error, :not_configured, :permanent} = Worker.perform(job(), deps)
    assert [{_html, _}] = texts(telegram)
  end

  test "sends multipart transcripts numbered and replying to the source", %{
    deps: deps,
    telegram: telegram
  } do
    transcript = String.duplicate("Frase larga para dividir en varios mensajes. ", 200)
    deps = Keyword.put(deps, :transcriber_opts, fun: fn _, _ -> {:ok, transcript} end)

    assert :ok = Worker.perform(job(), deps)

    sends = texts(telegram)
    assert length(sends) > 1
    assert Enum.all?(sends, fn {_html, opts} -> opts[:message_id] == 77 end)

    {first, _} = hd(sends)
    assert first =~ "(1/"
  end

  test "resumes multipart delivery at the first unsent part", %{deps: deps, telegram: telegram} do
    transcript = String.duplicate("Frase larga para dividir en varios mensajes. ", 200)
    {:ok, parts} = Formatting.render(transcript)
    deps = Keyword.put(deps, :transcriber_opts, fun: fn _, _ -> {:ok, transcript} end)

    assert :ok = Worker.perform(job(delivered_parts: 1), deps)

    sends = texts(telegram)
    assert length(sends) == length(parts) - 1
    assert {first, _} = hd(sends)
    assert first =~ "(2/#{length(parts)})"
  end

  test "never logs the transcript", %{deps: deps} do
    deps = Keyword.put(deps, :transcriber_opts, fun: fn _, _ -> {:ok, "CONTENIDO SECRETO"} end)

    log = capture_log(fn -> assert :ok = Worker.perform(job(), deps) end)

    refute log =~ "CONTENIDO SECRETO"
  end

  test "cleans the temporary directory when transcription raises", %{deps: deps, dir: dir} do
    deps = Keyword.put(deps, :transcriber_opts, fun: fn _, _ -> raise "boom" end)

    assert_raise RuntimeError, fn -> Worker.perform(job(), deps) end
    assert File.ls!(dir) == []
  end

  test "treats a Telegram send failure as retryable", %{deps: deps, telegram: telegram} do
    FakeTelegram.put(telegram, :send_html, {:error, :telegram_down})

    assert {:error, :send_failed, :retryable} = Worker.perform(job(), deps)
  end

  test "notifies a final failure with a short Spanish message", %{deps: deps, telegram: telegram} do
    assert :ok = Worker.notify_final_failure(job(), deps)
    assert [{html, opts}] = texts(telegram)
    assert html == "No se pudo transcribir el audio. Inténtalo de nuevo más tarde."
    assert opts[:message_id] == 77
    assert {:remove_reaction, -100, 77} in FakeTelegram.reactions(telegram)
  end

  test "makes final failure notification errors observable", %{deps: deps, telegram: telegram} do
    FakeTelegram.put(telegram, :send_html, {:error, :telegram_down})
    assert {:error, :send_failed} = Worker.notify_final_failure(job(), deps)
    refute {:remove_reaction, -100, 77} in FakeTelegram.reactions(telegram)
  end
end
