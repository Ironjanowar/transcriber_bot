defmodule TranscriptorBot.Bot do
  @moduledoc """
  ExGram bot entry point.

  ExGram handles Telegram transport, long polling and update parsing. All
  product policy lives in `TranscriptorBot.Router`.
  """

  use ExGram.Bot, name: :transcriptor_bot, setup_commands: false, get_me: false

  require Logger

  command("allow")
  command("deny")
  command("enable")
  command("disable")
  command("status")
  command("admin_add")
  command("admin_remove")

  @impl true
  def handle({:command, command, message}, context) do
    dispatch(%{message | text: "/" <> to_string(command)}, context)
  end

  def handle({:text, _text, message}, context), do: dispatch(message, context)

  def handle({:message, message}, context), do: dispatch(message, context)

  def handle(_update, context), do: context

  defp dispatch(message, context) do
    update = %{context.update | message: message}

    case TranscriptorBot.Router.handle(update, deps()) do
      _ -> :ok
    end

    context
  rescue
    error ->
      Logger.error("Router failed for message #{message.message_id}: #{inspect(error)}")
      context
  end

  @doc false
  def deps do
    Application.get_env(:transcriptor_bot, :router_deps) ||
      %{
        store: TranscriptorBot.Store,
        queue: TranscriptorBot.Queue,
        telegram: TranscriptorBot.Telegram.client(),
        owner_id: TranscriptorBot.Config.owner_id()
      }
  end
end
