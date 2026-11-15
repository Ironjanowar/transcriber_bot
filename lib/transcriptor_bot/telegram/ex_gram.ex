defmodule TranscriptorBot.Telegram.ExGram do
  @moduledoc """
  Real Telegram adapter backed by ExGram and Req.

  Files are downloaded from the locally bound Bot API server, not from
  api.telegram.org. The download is streamed straight to disk.
  """

  @behaviour TranscriptorBot.Telegram
  require Logger

  @impl true
  def init(opts) do
    %{
      base_url:
        Keyword.get(opts, :base_url) ||
          Application.get_env(:transcriptor_bot, :telegram_api_base_url, "http://127.0.0.1:8081"),
      token: Keyword.get(opts, :token) || Application.get_env(:transcriptor_bot, :bot_token, ""),
      req_options: Keyword.get(opts, :req_options, [])
    }
  end

  @impl true
  def get_file(state, file_id) do
    case ExGram.get_file(file_id, token: state.token) do
      {:ok, file} -> {:ok, %{file_path: file.file_path, file_size: file.file_size}}
      {:error, _} = error -> error
    end
  end

  @impl true
  def download_file(state, file_path, dest, max_bytes) do
    url = file_url(state, file_path)
    {:ok, file} = File.open(dest, [:write, :binary])
    ref = make_ref()
    Process.put(ref, 0)

    into = fn {:data, data}, {req, resp} ->
      written = Process.get(ref, 0)
      next = written + byte_size(data)

      if max_bytes != :infinity and next > max_bytes do
        Process.put(ref, :too_large)
        {:halt, {req, resp}}
      else
        :ok = IO.binwrite(file, data)
        Process.put(ref, next)
        {:cont, {req, resp}}
      end
    end

    options =
      [
        into: into,
        receive_timeout: 120_000,
        retry: false
      ] ++ state.req_options

    result = Req.get(url, options)
    File.close(file)
    streamed = Process.delete(ref)

    case {streamed, result} do
      {:too_large, _} ->
        File.rm(dest)
        {:error, :too_large}

      {_, {:ok, %Req.Response{status: 200}}} ->
        :ok

      {_, {:ok, %Req.Response{status: status}}} ->
        File.rm(dest)
        {:error, {:http_status, status}}

      {_, {:error, error}} ->
        File.rm(dest)
        {:error, error}
    end
  rescue
    error ->
      File.rm(dest)
      {:error, error}
  end

  @impl true
  def send_html(state, chat_id, html, opts) do
    reply_parameters =
      case Keyword.get(opts, :message_id) do
        nil ->
          []

        message_id ->
          {:ok, reply} =
            ExGram.Cast.cast(%{message_id: message_id}, ExGram.Model.ReplyParameters)

          [reply_parameters: reply]
      end

    ExGram.send_message(
      chat_id,
      html,
      [parse_mode: "HTML", disable_web_page_preview: true, token: state.token] ++
        reply_parameters
    )
  end

  @impl true
  def react(state, chat_id, message_id, emoji) do
    {:ok, reaction} =
      ExGram.Cast.cast(%{type: "emoji", emoji: emoji}, ExGram.Model.ReactionType)

    case ExGram.set_message_reaction(chat_id, message_id,
           reaction: [reaction],
           token: state.token
         ) do
      {:ok, _} ->
        :ok

      {:error, error} ->
        Logger.debug("Could not add reaction: #{inspect(error)}")
        :ok
    end
  rescue
    error ->
      Logger.debug("Could not add reaction: #{inspect(error)}")
      :ok
  end

  @impl true
  def remove_reaction(state, chat_id, message_id) do
    case ExGram.set_message_reaction(chat_id, message_id,
           reaction: [],
           token: state.token
         ) do
      {:ok, _} ->
        :ok

      {:error, error} ->
        Logger.debug("Could not remove reaction: #{inspect(error)}")
        :ok
    end
  rescue
    error ->
      Logger.debug("Could not remove reaction: #{inspect(error)}")
      :ok
  end

  @doc false
  def file_url(%{base_url: base_url, token: token}, file_path) do
    String.trim_trailing(base_url, "/") <> "/file/bot" <> token <> "/" <> file_path
  end
end
