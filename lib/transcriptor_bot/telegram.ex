defmodule TranscriptorBot.Telegram do
  @moduledoc """
  Telegram API boundary.

  A client wraps an adapter module plus opaque adapter state, so the rest of the
  application can use a fake adapter in tests and the real ExGram adapter in
  production. Reactions are always best effort.
  """

  require Logger

  @callback init(keyword()) :: term()
  @callback get_file(term(), String.t()) :: {:ok, map()} | {:error, term()}
  @callback download_file(term(), String.t(), Path.t(), non_neg_integer() | :infinity) ::
              :ok | {:error, term()}
  @callback send_html(term(), integer(), String.t(), keyword()) ::
              {:ok, term()} | {:error, term()}
  @callback react(term(), integer(), integer(), String.t()) :: :ok
  @callback remove_reaction(term(), integer(), integer()) :: :ok

  defstruct [:adapter, :state]

  @type t :: %__MODULE__{adapter: module(), state: term()}

  @spec client(keyword()) :: t()
  def client(opts \\ []) do
    adapter = Keyword.get(opts, :adapter, TranscriptorBot.Telegram.ExGram)
    %__MODULE__{adapter: adapter, state: adapter.init(opts)}
  end

  @spec get_file(t(), String.t()) :: {:ok, map()} | {:error, term()}
  def get_file(%__MODULE__{adapter: adapter, state: state}, file_id),
    do: adapter.get_file(state, file_id)

  @spec download_file(t(), String.t(), Path.t()) :: :ok | {:error, term()}
  def download_file(client, file_path, dest),
    do: download_file(client, file_path, dest, :infinity)

  @spec download_file(t(), String.t(), Path.t(), non_neg_integer() | :infinity) ::
          :ok | {:error, term()}
  def download_file(%__MODULE__{adapter: adapter, state: state}, file_path, dest, max_bytes),
    do: adapter.download_file(state, file_path, dest, max_bytes)

  @spec send_html(t(), integer(), String.t(), keyword()) :: {:ok, term()} | {:error, term()}
  def send_html(%__MODULE__{adapter: adapter, state: state}, chat_id, html, opts),
    do: adapter.send_html(state, chat_id, html, opts)

  @spec react(t(), integer(), integer(), String.t()) :: :ok
  def react(%__MODULE__{adapter: adapter, state: state}, chat_id, message_id, emoji) do
    adapter.react(state, chat_id, message_id, emoji)
  rescue
    error ->
      Logger.debug("Reaction failed: #{inspect(error)}")
      :ok
  end

  @spec remove_reaction(t(), integer(), integer()) :: :ok
  def remove_reaction(%__MODULE__{adapter: adapter, state: state}, chat_id, message_id) do
    adapter.remove_reaction(state, chat_id, message_id)
  rescue
    error ->
      Logger.debug("Reaction removal failed: #{inspect(error)}")
      :ok
  end

  @doc "Builds the local Bot API file URL for a Telegram file path."
  @spec file_url(t(), String.t()) :: String.t()
  def file_url(%__MODULE__{state: state}, file_path) do
    TranscriptorBot.Telegram.ExGram.file_url(state, file_path)
  end
end
