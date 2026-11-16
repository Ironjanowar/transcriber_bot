defmodule TranscriptorBot.Worker do
  @moduledoc """
  Executes one transcription job end to end.

  Downloads the original file through the local Bot API, validates the real
  file size and duration, normalizes to 16 kHz mono 16-bit PCM WAV, runs a fresh
  external transcriber process, replies with Telegram HTML, and always removes its
  temporary directory. Transcript and audio contents are never logged.
  """

  @behaviour TranscriptorBot.WorkerBehaviour
  require Logger

  alias TranscriptorBot.{Formatting, Media, Store, Telegram, Transcriber}

  @empty_message "No se detectó voz en el audio."
  @failure_message "No se pudo transcribir el audio. Inténtalo de nuevo más tarde."

  @impl true
  def perform(%Store.Job{} = job, opts) do
    deps = build_deps(opts)
    tmp = Path.join(deps.work_dir, "job-#{job.id}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)

    try do
      job
      |> run(deps, tmp)
      |> finish(job, deps)
    after
      File.rm_rf(tmp)
    end
  end

  @doc "Sends the final failure message and removes the best-effort reaction."
  @spec notify_final_failure(Store.Job.t(), keyword()) :: :ok | {:error, :send_failed}
  def notify_final_failure(%Store.Job{} = job, opts) do
    deps = build_deps(opts)

    case send_message(deps, job, @failure_message) do
      :ok ->
        Telegram.remove_reaction(deps.telegram, job.chat_id, job.message_id)
        :ok

      {:error, _} = error ->
        error
    end
  end

  def empty_message, do: @empty_message
  def failure_message, do: @failure_message

  defp build_deps(opts) do
    %{
      telegram: Keyword.fetch!(opts, :telegram),
      media: Keyword.get(opts, :media, Media),
      transcriber: Keyword.get(opts, :transcriber, Transcriber),
      media_opts: Keyword.get(opts, :media_opts, []),
      transcriber_opts: Keyword.get(opts, :transcriber_opts, []),
      store: Keyword.get(opts, :store),
      work_dir: Keyword.get(opts, :work_dir, default(:work_dir, System.tmp_dir!())),
      max_file_bytes:
        Keyword.get(opts, :max_file_bytes, default(:max_file_bytes, 500 * 1024 * 1024)),
      max_duration_ms:
        Keyword.get(opts, :max_duration_ms, default(:max_duration_ms, 60 * 60 * 1000)),
      send_interval_ms: Keyword.get(opts, :send_interval_ms, 1_000)
    }
  end

  defp run(job, deps, tmp) do
    with {:ok, %{file_path: file_path}} when is_binary(file_path) <-
           Telegram.get_file(deps.telegram, job.file_id),
         dest = Path.join(tmp, safe_name(file_path)),
         :ok <- Telegram.download_file(deps.telegram, file_path, dest, deps.max_file_bytes),
         :ok <- deps.media.validate_size(dest, deps.max_file_bytes),
         {:ok, duration_ms} <- deps.media.probe(dest, deps.media_opts),
         :ok <- deps.media.validate_duration(duration_ms, deps.max_duration_ms),
         pcm_wav = Path.join(tmp, "audio.wav"),
         :ok <- deps.media.normalize(dest, pcm_wav, deps.media_opts),
         {:ok, transcript} <-
           deps.transcriber.transcribe(pcm_wav, duration_ms, deps.transcriber_opts) do
      {:ok, transcript}
    else
      {:ok, _file} -> {:error, :invalid_media}
      {:error, reason} -> {:error, reason}
    end
  end

  defp finish({:ok, transcript}, job, deps) do
    case deliver(transcript, job, deps) do
      :ok ->
        Telegram.remove_reaction(deps.telegram, job.chat_id, job.message_id)
        :ok

      {:error, reason} ->
        {:error, reason, :retryable}
    end
  end

  defp finish({:error, reason}, job, deps) do
    case classify(reason) do
      :permanent ->
        Logger.warning("Transcription job #{job.id} failed permanently: #{inspect(reason)}")

        case send_message(deps, job, @failure_message) do
          :ok ->
            Telegram.remove_reaction(deps.telegram, job.chat_id, job.message_id)
            {:error, reason, :permanent}

          {:error, :send_failed} ->
            {:error, :send_failed, :retryable}
        end

      :retryable ->
        {:error, reason, :retryable}
    end
  end

  defp deliver(transcript, job, deps) do
    case Formatting.render(transcript) do
      :empty -> send_message(deps, job, @empty_message)
      {:ok, parts} -> send_parts(deps, job, parts)
    end
  end

  defp send_parts(deps, job, parts) do
    parts
    |> Enum.with_index()
    |> Enum.drop(job.delivered_parts || 0)
    |> Enum.reduce_while(:ok, fn {html, index}, :ok ->
      result = send_message(deps, job, html)

      cond do
        result != :ok ->
          {:halt, result}

        not is_nil(deps.store) ->
          :ok = Store.mark_part_delivered(deps.store, job.id, index + 1)
          maybe_pace(index, parts, deps)

        index < length(parts) - 1 and deps.send_interval_ms > 0 ->
          Process.sleep(deps.send_interval_ms)
          {:cont, :ok}

        true ->
          {:cont, :ok}
      end
    end)
  end

  defp maybe_pace(index, parts, deps) do
    if index < length(parts) - 1 and deps.send_interval_ms > 0 do
      Process.sleep(deps.send_interval_ms)
    end

    {:cont, :ok}
  end

  defp send_message(deps, job, html) do
    case Telegram.send_html(deps.telegram, job.chat_id, html, message_id: job.message_id) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.error("Could not send transcription message for job #{job.id}: #{inspect(reason)}")
        {:error, :send_failed}
    end
  end

  defp classify(:too_large), do: :permanent
  defp classify(:too_long), do: :permanent
  defp classify(:invalid_media), do: :permanent
  defp classify(:missing_file), do: :permanent
  defp classify(:not_configured), do: :permanent
  defp classify(:command_not_found), do: :permanent
  defp classify({:http_status, status}) when status in 400..499, do: :permanent
  defp classify(_reason), do: :retryable

  defp safe_name(file_path) do
    case Path.basename(file_path) do
      "" -> "audio"
      "." -> "audio"
      ".." -> "audio"
      name -> name
    end
  end

  defp default(key, fallback) do
    Application.get_env(:transcriptor_bot, key, fallback)
  end
end
