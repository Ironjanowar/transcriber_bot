defmodule TranscriptorBot.MediaTest do
  use ExUnit.Case, async: true

  alias TranscriptorBot.Media

  describe "probe/2" do
    test "returns duration in milliseconds from ffprobe JSON" do
      runner = fn "ffprobe", args ->
        assert "-show_entries" in args
        assert Enum.any?(args, &String.contains?(&1, "format=duration"))
        assert List.last(args) == "/tmp/audio.ogg"
        {~s({"streams":[{"codec_type":"audio"}],"format":{"duration":"12.53"}}), 0}
      end

      assert {:ok, 12_530} = Media.probe("/tmp/audio.ogg", runner: runner)
    end

    test "rejects media without a usable duration" do
      assert {:error, :invalid_media} =
               Media.probe("/tmp/a", runner: fn _, _ -> {~s({"format":{}}), 0} end)

      assert {:error, :invalid_media} =
               Media.probe("/tmp/a",
                 runner: fn _, _ -> {~s({"format":{"duration":"N/A"}}), 0} end
               )

      assert {:error, :invalid_media} =
               Media.probe("/tmp/a", runner: fn _, _ -> {"not json", 0} end)

      assert {:error, :invalid_media} =
               Media.probe("/tmp/a", runner: fn _, _ -> {~s({"format":{"duration":"1"}}), 1} end)
    end

    test "rejects a container with duration but no audio stream" do
      output = ~s({"streams":[{"codec_type":"video"}],"format":{"duration":"1.0"}})

      assert {:error, :invalid_media} =
               Media.probe("/tmp/video", runner: fn _, _ -> {output, 0} end)
    end

    test "times out and kills a hanging ffprobe process" do
      dir = Path.join(System.tmp_dir!(), "probe_hang_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      script = Path.join(dir, "ffprobe")
      pid_file = Path.join(dir, "pid")

      File.write!(
        script,
        "#!/bin/sh\ntrap '' TERM\necho $$ > '#{pid_file}'\nwhile :; do sleep 1; done\n"
      )

      File.chmod!(script, 0o755)
      on_exit(fn -> File.rm_rf!(dir) end)

      assert {:error, :invalid_media} =
               Media.probe("/tmp/audio", command: script, timeout_ms: 100, term_grace_ms: 50)

      pid = pid_file |> File.read!() |> String.trim()
      {_output, status} = System.cmd("kill", ["-0", pid], stderr_to_stdout: true)
      assert status != 0
    end
  end

  describe "normalize/3" do
    test "invokes ffmpeg with 16 kHz mono 16-bit PCM WAV settings" do
      output =
        Path.join(System.tmp_dir!(), "normalized_#{System.unique_integer([:positive])}.wav")

      on_exit(fn -> File.rm(output) end)

      runner = fn "ffmpeg", args ->
        assert "-ar" in args
        assert "16000" in args
        assert "-ac" in args
        assert "1" in args
        assert "pcm_s16le" in args
        assert "-f" in args
        assert "wav" in args
        assert List.last(args) == output

        File.write!(
          output,
          "RIFF" <>
            <<40::little-32>> <>
            "WAVEfmt " <>
            String.duplicate(<<0>>, 28) <>
            "data" <> <<4::little-32>> <> <<1, 2, 3, 4>>
        )

        {"", 0}
      end

      assert :ok = Media.normalize("/tmp/in.ogg", output, runner: runner)
    end

    test "returns an error when ffmpeg fails" do
      assert {:error, {:ffmpeg_failed, 1}} =
               Media.normalize("/tmp/in", "/tmp/out", runner: fn _, _ -> {"boom", 1} end)
    end

    test "returns an error when the output file is empty" do
      tmp = Path.join(System.tmp_dir!(), "media_#{System.unique_integer([:positive])}.pcm")
      File.write!(tmp, "")
      on_exit(fn -> File.rm(tmp) end)

      assert {:error, :empty_output} =
               Media.normalize("/tmp/in", tmp, runner: fn _, _ -> {"", 0} end)
    end

    test "rejects a non-audio ffmpeg output" do
      tmp = Path.join(System.tmp_dir!(), "media_#{System.unique_integer([:positive])}.wav")
      on_exit(fn -> File.rm(tmp) end)

      runner = fn _, _ ->
        File.write!(tmp, String.duplicate("x", 100))
        {"", 0}
      end

      assert {:error, :invalid_output} = Media.normalize("/tmp/in", tmp, runner: runner)
    end

    test "rejects a WAV header without audio samples" do
      tmp = Path.join(System.tmp_dir!(), "media_#{System.unique_integer([:positive])}.wav")
      on_exit(fn -> File.rm(tmp) end)

      runner = fn _, _ ->
        File.write!(tmp, "RIFF" <> <<36::little-32>> <> "WAVEfmt " <> String.duplicate(<<0>>, 36))
        {"", 0}
      end

      assert {:error, :invalid_output} = Media.normalize("/tmp/in", tmp, runner: runner)
    end
  end

  describe "validate_size/2" do
    setup do
      path = Path.join(System.tmp_dir!(), "size_#{System.unique_integer([:positive])}")
      File.write!(path, String.duplicate("a", 100))
      on_exit(fn -> File.rm(path) end)
      {:ok, path: path}
    end

    test "accepts files at the limit", %{path: path} do
      assert :ok = Media.validate_size(path, 100)
    end

    test "rejects files over the limit using the real size", %{path: path} do
      assert {:error, :too_large} = Media.validate_size(path, 99)
    end

    test "rejects missing files" do
      assert {:error, :missing_file} = Media.validate_size("/nonexistent/file", 100)
    end
  end

  describe "validate_duration/2" do
    test "accepts one hour exactly and rejects longer media" do
      assert :ok = Media.validate_duration(3_600_000, 3_600_000)
      assert {:error, :too_long} = Media.validate_duration(3_600_001, 3_600_000)
    end
  end

  describe "real ffmpeg integration" do
    test "probes and normalizes a generated audio file" do
      if System.find_executable("ffmpeg") && System.find_executable("ffprobe") do
        dir = Path.join(System.tmp_dir!(), "media_real_#{System.unique_integer([:positive])}")
        File.mkdir_p!(dir)
        on_exit(fn -> File.rm_rf!(dir) end)

        wav = Path.join(dir, "tone.wav")
        pcm_wav = Path.join(dir, "tone-normalized.wav")

        {_, 0} =
          System.cmd("ffmpeg", [
            "-v",
            "error",
            "-f",
            "lavfi",
            "-i",
            "sine=frequency=440:duration=0.5",
            "-ar",
            "44100",
            wav
          ])

        assert {:ok, duration_ms} = Media.probe(wav)
        assert_in_delta duration_ms, 500, 75

        assert :ok = Media.normalize(wav, pcm_wav)
        assert File.stat!(pcm_wav).size > 10_000
        assert {:ok, ^duration_ms} = Media.probe(pcm_wav)
      else
        :ok
      end
    end
  end
end
