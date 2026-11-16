defmodule TranscriptorBot.Bot do
  @moduledoc """
  ExGram bot entry point.

  ExGram handles Telegram transport, long polling and update parsing. All
  product policy lives in `TranscriptorBot.Router`.
  """

  use ExGram.Bot, name: :transcriptor_bot, setup_commands: true, get_me: false

  require Logger

  command("start", description: "Iniciar el bot")
  command("help", description: "Mostrar ayuda contextual")
  command("status", description: "Ver estado del grupo y la cola")
  command("allow", description: "Autorizar y activar este grupo")
  command("deny", description: "Revocar la autorización del grupo")
  command("enable", description: "Activar las transcripciones")
  command("disable", description: "Pausar nuevas transcripciones")
  command("admin_add", description: "Añadir administrador respondiendo a su mensaje")
  command("admin_remove", description: "Eliminar administrador respondiendo a su mensaje")

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
