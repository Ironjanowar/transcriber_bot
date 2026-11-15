defmodule TranscriptorBot.Media do
  @moduledoc """
  Bounded ffprobe/ffmpeg wrappers used to validate and normalize Telegram audio.
  """

  @default_timeout_ms 120_000
  @default_term_grace_ms 1_000
  @default_output_limit 1_048_576

  @type runner :: (String.t(), [String.t()] -> {String.t(), non_neg_integer()})

  @spec probe(Path.t(), keyword()) :: {:ok, non_neg_integer()} | {:error, :invalid_media}
  def probe(path, opts \\ []) do
    runner = runner(opts)
    command = Keyword.get(opts, :command, "ffprobe")

    args = [
      "-v",
      "error",
      "-show_entries",
      "format=duration:stream=codec_type",
      "-of",
      "json",
      path
    ]

    case runner.(command, args) do
      {output, 0} ->
        with {:ok, %{"format" => %{"duration" => duration}, "streams" => streams}} <-
               Jason.decode(output),
             true <- Enum.any?(streams, &(&1["codec_type"] == "audio")),
             {seconds, ""} <- Float.parse(duration),
             true <- seconds > 0 do
          {:ok, round(seconds * 1000)}
        else
          _ -> {:error, :invalid_media}
        end

      _ ->
        {:error, :invalid_media}
    end
  end

  @spec normalize(Path.t(), Path.t(), keyword()) ::
          :ok
          | {:error, {:ffmpeg_failed, non_neg_integer()}}
          | {:error, :empty_output | :invalid_output}
  def normalize(input, output, opts \\ []) do
    runner = runner(opts)
    command = Keyword.get(opts, :command, "ffmpeg")

    args = [
      "-nostdin",
      "-y",
      "-i",
      input,
      "-vn",
      "-ac",
      "1",
      "-ar",
      "16000",
      "-acodec",
      "pcm_s16le",
      "-f",
      "wav",
      output
    ]

    case runner.(command, args) do
      {_, 0} -> validate_wav_output(output)
      {_, status} -> {:error, {:ffmpeg_failed, status}}
    end
  end

  @spec validate_size(Path.t(), non_neg_integer()) ::
          :ok | {:error, :too_large | :missing_file}
  def validate_size(path, max_bytes) do
    case File.stat(path) do
      {:ok, %{size: size}} when size <= max_bytes -> :ok
      {:ok, _} -> {:error, :too_large}
      {:error, _} -> {:error, :missing_file}
    end
  end

  @spec validate_duration(non_neg_integer(), non_neg_integer()) ::
          :ok | {:error, :too_long}
  def validate_duration(duration_ms, max_duration_ms) when duration_ms <= max_duration_ms, do: :ok
  def validate_duration(_duration_ms, _max_duration_ms), do: {:error, :too_long}

  defp runner(opts) do
    Keyword.get(opts, :runner, fn command, args ->
      run_port(command, args,
        timeout_ms: Keyword.get(opts, :timeout_ms, @default_timeout_ms),
        term_grace_ms: Keyword.get(opts, :term_grace_ms, @default_term_grace_ms),
        output_limit: Keyword.get(opts, :output_limit, @default_output_limit)
      )
    end)
  end

  defp validate_wav_output(path) do
    case File.open(path, [:read, :binary]) do
      {:ok, file} ->
        result =
          case IO.binread(file, 12) do
            <<"RIFF", _size::little-32, "WAVE">> -> find_audio_data(file)
            :eof -> {:error, :empty_output}
            _ -> {:error, :invalid_output}
          end

        File.close(file)
        result

      {:error, _} ->
        {:error, :empty_output}
    end
  end

  defp find_audio_data(file) do
    case IO.binread(file, 8) do
      <<"data", size::little-32>> when size > 0 ->
        if IO.binread(file, 1) in [:eof, {:error, :terminated}],
          do: {:error, :invalid_output},
          else: :ok

      <<_chunk_id::binary-size(4), size::little-32>> ->
        {:ok, _} = :file.position(file, {:cur, size + rem(size, 2)})
        find_audio_data(file)

      _ ->
        {:error, :invalid_output}
    end
  end

  defp run_port(command, args, opts) do
    case System.find_executable(command) do
      nil ->
        {"command not found", 127}

      executable ->
        port =
          Port.open({:spawn_executable, executable}, [
            :binary,
            :exit_status,
            :stderr_to_stdout,
            args: args
          ])

        timer = Process.send_after(self(), {:media_timeout, port}, opts[:timeout_ms])
        collect(port, [], 0, timer, opts)
    end
  end

  defp collect(port, chunks, size, timer, opts) do
    receive do
      {^port, {:data, data}} ->
        if size + byte_size(data) <= opts[:output_limit] do
          collect(port, [data | chunks], size + byte_size(data), timer, opts)
        else
          Process.cancel_timer(timer)
          terminate(port, opts[:term_grace_ms])
          {chunks |> Enum.reverse() |> IO.iodata_to_binary(), 125}
        end

      {^port, {:exit_status, status}} ->
        Process.cancel_timer(timer)
        {chunks |> Enum.reverse() |> IO.iodata_to_binary(), status}

      {:media_timeout, ^port} ->
        terminate(port, opts[:term_grace_ms])
        {chunks |> Enum.reverse() |> IO.iodata_to_binary(), 124}
    end
  end

  defp terminate(port, grace_ms) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} ->
        signal(pid, "TERM")

        receive do
          {^port, {:exit_status, _}} -> :ok
        after
          grace_ms ->
            signal(pid, "KILL")

            receive do
              {^port, {:exit_status, _}} -> :ok
            after
              1_000 -> close_port(port)
            end
        end

      _ ->
        :ok
    end
  end

  defp signal(pid, signal) do
    System.cmd("kill", ["-#{signal}", Integer.to_string(pid)], stderr_to_stdout: true)
  rescue
    _ -> :ok
  end

  defp close_port(port) do
    Port.close(port)
  rescue
    ArgumentError -> :ok
  end
end
