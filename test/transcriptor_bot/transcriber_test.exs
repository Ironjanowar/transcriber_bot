defmodule TranscriptorBot.TranscriberTest do
  use ExUnit.Case, async: true

  alias TranscriptorBot.Transcriber

  @deps [command: "/usr/bin/transcriptor", args: ["--model", "large-v3"]]

  describe "timeout_for/2" do
    test "uses a floor of fifteen minutes" do
      assert Transcriber.timeout_for(0) == 15 * 60 * 1000
      assert Transcriber.timeout_for(60_000) == 15 * 60 * 1000
    end

    test "doubles the media duration when that is larger" do
      assert Transcriber.timeout_for(10 * 60 * 1000) == 20 * 60 * 1000
      assert Transcriber.timeout_for(30 * 60 * 1000) == 60 * 60 * 1000
    end

    test "caps the timeout at two hours" do
      assert Transcriber.timeout_for(60 * 60 * 1000) == 2 * 60 * 60 * 1000
      assert Transcriber.timeout_for(4 * 60 * 60 * 1000) == 2 * 60 * 60 * 1000
    end
  end

  describe "transcribe/3" do
    test "runs a fresh process with the PCM path appended and trims output" do
      parent = self()

      runner = fn command, args, timeout ->
        send(parent, {:invoked, command, args, timeout})
        {:ok, "  Hola mundo.\n"}
      end

      assert {:ok, "Hola mundo."} =
               Transcriber.transcribe(
                 "/tmp/audio.pcm",
                 10 * 60 * 1000,
                 Keyword.merge(@deps, runner: runner)
               )

      assert_received {:invoked, "/usr/bin/transcriptor",
                       ["--model", "large-v3", "/tmp/audio.pcm"], 1_200_000}
    end

    test "returns an error for a non-zero exit" do
      runner = fn _, _, _ -> {:error, {:exit, 2}} end

      assert {:error, {:exit, 2}} =
               Transcriber.transcribe("/tmp/a.pcm", 1_000, Keyword.merge(@deps, runner: runner))
    end

    test "returns a timeout error when the adaptive timeout expires" do
      runner = fn _, _, _ -> {:error, :timeout} end

      assert {:error, :timeout} =
               Transcriber.transcribe("/tmp/a.pcm", 1_000, Keyword.merge(@deps, runner: runner))
    end

    test "accepts empty output so the caller can answer in Spanish" do
      runner = fn _, _, _ -> {:ok, " \n "} end

      assert {:ok, ""} =
               Transcriber.transcribe("/tmp/a.pcm", 1_000, Keyword.merge(@deps, runner: runner))
    end

    test "refuses to run without a configured command" do
      assert {:error, :not_configured} =
               Transcriber.transcribe("/tmp/a.pcm", 1_000,
                 command: nil,
                 runner: fn _, _, _ -> :ok end
               )
    end

    test "returns command_not_found when the executable does not exist" do
      assert {:error, :command_not_found} =
               Transcriber.transcribe("/tmp/a.pcm", 1_000,
                 command: "definitely-not-a-real-transcriber",
                 min_timeout: 50,
                 max_timeout: 50
               )
    end

    test "runs a real process and captures stdout" do
      assert {:ok, "real-output"} =
               Transcriber.transcribe("/tmp/a.pcm", 1_000,
                 command: "sh",
                 args: ["-c", "printf real-output"],
                 min_timeout: 1_000,
                 max_timeout: 1_000
               )
    end

    test "terminates a hanging process at the adaptive timeout" do
      {elapsed_us, result} =
        :timer.tc(fn ->
          Transcriber.transcribe("/tmp/a.pcm", 0,
            command: "sh",
            args: ["-c", "sleep 5"],
            min_timeout: 50,
            max_timeout: 50
          )
        end)

      assert {:error, :timeout} = result
      assert elapsed_us < 2_000_000
    end

    test "kills a TERM-ignoring process and confirms it is dead" do
      pid_file =
        Path.join(System.tmp_dir!(), "transcriber_pid_#{System.unique_integer([:positive])}")

      on_exit(fn -> File.rm(pid_file) end)

      assert {:error, :timeout} =
               Transcriber.transcribe("/tmp/a.pcm", 0,
                 command: "sh",
                 args: ["-c", "trap '' TERM; echo $$ > '#{pid_file}'; while :; do sleep 1; done"],
                 min_timeout: 100,
                 max_timeout: 100,
                 term_grace_ms: 50
               )

      pid = pid_file |> File.read!() |> String.trim()
      {_output, status} = System.cmd("kill", ["-0", pid], stderr_to_stdout: true)
      assert status != 0
    end
  end
end
