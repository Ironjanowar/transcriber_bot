defmodule TranscriptorBot.Router do
  @moduledoc """
  Telegram update policy.

  Decides who may enqueue audio and which administrators may change group or
  administrator state. Telegram side effects go through
  `TranscriptorBot.Telegram`; queue persistence goes through
  `TranscriptorBot.Queue`.
  """

  alias ExGram.Model.{Message, Update}
  alias TranscriptorBot.{Formatting, Queue, Store, Telegram}

  @group_types ~w(group supergroup)
  @commands ~w(start help allow deny enable disable status admin_add admin_remove)

  @type deps :: %{
          store: GenServer.server(),
          queue: GenServer.server(),
          telegram: Telegram.t(),
          owner_id: integer()
        }

  @spec handle(Update.t() | map(), deps()) :: :ok | :ignored
  def handle(%Update{update_id: update_id, message: %Message{} = message}, deps),
    do: handle_message(message, update_id, deps)

  def handle(_update, _deps), do: :ignored

  defp handle_message(%Message{} = message, update_id, deps) do
    cond do
      is_nil(message.from) or message.from.is_bot ->
        :ignored

      command = parse_command(message.text) ->
        handle_command(command, message, deps)

      true ->
        handle_media(message, update_id, deps)
    end
  end

  defp parse_command(text) when is_binary(text) do
    with "/" <> rest <- text,
         [name | _] <- String.split(rest, ~r/\s+/, parts: 2),
         name <- name |> String.split("@") |> hd(),
         true <- name in @commands do
      String.to_existing_atom(name)
    else
      _ -> nil
    end
  end

  defp parse_command(_), do: nil

  # ---------------------------------------------------------------------------
  # Commands
  # ---------------------------------------------------------------------------

  defp handle_command(command, message, deps) do
    if group?(message) do
      handle_group_command(command, message, deps)
    else
      handle_private_command(command, message, deps)
    end
  end

  defp handle_group_command(:start, message, deps), do: reply(deps, message, start_text())

  defp handle_group_command(:help, message, deps),
    do: reply(deps, message, help_text(message, deps))

  defp handle_group_command(command, message, deps)
       when command in [:allow, :deny, :enable, :disable, :status] do
    case command do
      :status ->
        reply(deps, message, group_status(message, deps))

      _ ->
        if admin?(message.from.id, deps) do
          apply_group_command(command, message, deps)
        else
          reply(deps, message, "Solo los administradores pueden usar este comando.")
        end
    end
  end

  defp handle_group_command(:admin_add, message, deps), do: handle_admin_add(message, deps)
  defp handle_group_command(:admin_remove, message, deps), do: handle_admin_remove(message, deps)

  defp handle_private_command(:start, message, deps), do: reply(deps, message, start_text())

  defp handle_private_command(:help, message, deps),
    do: reply(deps, message, help_text(message, deps))

  defp handle_private_command(:status, message, deps) do
    stats = Queue.status(deps.queue)

    reply(
      deps,
      message,
      "Pendientes: #{stats.pending}\nEn proceso: #{stats.running}"
    )
  end

  defp handle_private_command(:admin_add, message, deps), do: handle_admin_add(message, deps)

  defp handle_private_command(:admin_remove, message, deps),
    do: handle_admin_remove(message, deps)

  defp handle_private_command(_command, message, deps) do
    reply(deps, message, "Este comando solo funciona en grupos.")
  end

  defp apply_group_command(:allow, message, deps) do
    :ok = Store.allow(deps.store, message.chat.id)
    reply(deps, message, "Grupo autorizado y activo.")
  end

  defp apply_group_command(:deny, message, deps) do
    :ok = Store.deny(deps.store, message.chat.id)
    reply(deps, message, "Grupo desautorizado.")
  end

  defp apply_group_command(:enable, message, deps) do
    case Store.enable(deps.store, message.chat.id) do
      :ok ->
        reply(deps, message, "Grupo activado.")

      {:error, :not_allowed} ->
        reply(deps, message, "El grupo no está autorizado. Usa /allow primero.")
    end
  end

  defp apply_group_command(:disable, message, deps) do
    :ok = Store.disable(deps.store, message.chat.id)

    reply(
      deps,
      message,
      "Grupo desactivado. Los trabajos aceptados terminarán."
    )
  end

  # ---------------------------------------------------------------------------
  # Administrators
  # ---------------------------------------------------------------------------

  defp handle_admin_add(message, deps) do
    cond do
      message.from.id != deps.owner_id ->
        reply(deps, message, "Solo el propietario puede gestionar administradores.")

      target = reply_target(message) ->
        case Store.add_admin(deps.store, target.id) do
          :ok -> reply(deps, message, "Administrador añadido.")
          :already_admin -> reply(deps, message, "Ese usuario ya es administrador.")
        end

      true ->
        reply(
          deps,
          message,
          "Responde al mensaje del usuario que quieres añadir como administrador."
        )
    end
  end

  defp handle_admin_remove(message, deps) do
    cond do
      message.from.id != deps.owner_id ->
        reply(deps, message, "Solo el propietario puede gestionar administradores.")

      target = reply_target(message) ->
        cond do
          target.id == deps.owner_id ->
            reply(deps, message, "El propietario no se puede eliminar.")

          true ->
            case Store.remove_admin(deps.store, target.id) do
              :ok -> reply(deps, message, "Administrador eliminado.")
              :not_admin -> reply(deps, message, "Ese usuario no es administrador.")
              :owner -> reply(deps, message, "El propietario no se puede eliminar.")
            end
        end

      true ->
        reply(
          deps,
          message,
          "Responde al mensaje del usuario que quieres eliminar como administrador."
        )
    end
  end

  defp reply_target(%Message{reply_to_message: %Message{from: %{id: id, is_bot: false}}})
       when is_integer(id),
       do: %{id: id}

  defp reply_target(_message), do: nil

  # ---------------------------------------------------------------------------
  # Audio
  # ---------------------------------------------------------------------------

  defp handle_media(message, update_id, deps) do
    case media(message) do
      nil ->
        :ignored

      media ->
        authorize_and_enqueue(media, message, update_id, deps)
    end
  end

  defp authorize_and_enqueue(media, message, update_id, deps) do
    cond do
      private?(message) and admin?(message.from.id, deps) ->
        enqueue(media, message, update_id, deps)

      private?(message) ->
        reply(deps, message, "Solo los administradores pueden enviar audio por privado.")

      group?(message) ->
        case Store.chat_state(deps.store, message.chat.id) do
          %{allowed: true, enabled: true} ->
            enqueue(media, message, update_id, deps)

          %{allowed: true, enabled: false} ->
            reply(
              deps,
              message,
              "El grupo está desactivado. Un administrador puede usar /enable."
            )

          _ ->
            reply(
              deps,
              message,
              "Este grupo no está autorizado. Un administrador puede usar /allow."
            )
        end

      true ->
        :ignored
    end
  end

  defp enqueue(media, message, update_id, deps) do
    attrs = %{
      update_id: update_id,
      chat_id: message.chat.id,
      message_id: message.message_id,
      file_id: media.file_id,
      file_unique_id: media.file_unique_id,
      kind: media.kind,
      mime_type: media.mime_type,
      file_name: media.file_name,
      requested_by: message.from.id,
      duration_ms: media.duration_ms
    }

    case Queue.enqueue(deps.queue, attrs) do
      {:ok, _job} ->
        Telegram.react(deps.telegram, message.chat.id, message.message_id, reaction_emoji())
        :ok

      {:error, :queue_full} ->
        reply(deps, message, "La cola está llena. Inténtalo de nuevo más tarde.")
    end
  end

  defp media(%Message{voice: %{} = voice}) do
    %{
      file_id: voice.file_id,
      file_unique_id: voice.file_unique_id,
      kind: "voice",
      mime_type: voice.mime_type || "audio/ogg",
      file_name: nil,
      duration_ms: seconds_to_ms(voice.duration)
    }
  end

  defp media(%Message{audio: %{} = audio}) do
    %{
      file_id: audio.file_id,
      file_unique_id: audio.file_unique_id,
      kind: "audio",
      mime_type: audio.mime_type,
      file_name: audio.file_name,
      duration_ms: seconds_to_ms(audio.duration)
    }
  end

  defp media(%Message{document: %{mime_type: "audio/" <> _} = document}) do
    %{
      file_id: document.file_id,
      file_unique_id: document.file_unique_id,
      kind: "document",
      mime_type: document.mime_type,
      file_name: document.file_name,
      duration_ms: nil
    }
  end

  defp media(_message), do: nil

  defp seconds_to_ms(nil), do: nil
  defp seconds_to_ms(seconds) when is_integer(seconds), do: seconds * 1000

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp admin?(user_id, deps) do
    user_id == deps.owner_id or Store.admin?(deps.store, user_id)
  end

  defp group?(%Message{chat: %{type: type}}), do: type in @group_types
  defp group?(_message), do: false

  defp private?(%Message{chat: %{type: "private"}}), do: true
  defp private?(_message), do: false

  defp group_status(message, deps) do
    state =
      case Store.chat_state(deps.store, message.chat.id) do
        %{allowed: true, enabled: true} -> "autorizado y activo"
        %{allowed: true, enabled: false} -> "autorizado y desactivado"
        _ -> "no autorizado"
      end

    stats = Queue.status(deps.queue)

    "Grupo: #{state}\nPendientes: #{stats.pending}\nEn proceso: #{stats.running}"
  end

  defp start_text do
    "Hola. Transcribo notas de voz y archivos de audio. Usa /help para ver cómo utilizarme."
  end

  defp help_text(message, deps) do
    cond do
      private?(message) and message.from.id == deps.owner_id ->
        "Envíame audio por privado para transcribirlo.\n\n" <>
          "Comandos: /status, /help.\n" <>
          "Propietario: responde a un usuario con /admin_add o /admin_remove."

      private?(message) and admin?(message.from.id, deps) ->
        "Envíame audio por privado para transcribirlo.\n\nComandos: /status, /help."

      private?(message) ->
        "Este bot transcribe audio en grupos autorizados. Solo los administradores pueden enviar audio por privado."

      group?(message) and admin?(message.from.id, deps) ->
        "Envía una nota de voz o un archivo de audio para transcribirlo.\n\n" <>
          "Comandos: /status, /allow, /deny, /enable, /disable y /help."

      true ->
        "Envía una nota de voz o un archivo de audio. El grupo debe estar autorizado y activo.\n\n" <>
          "Comandos: /status y /help."
    end
  end

  defp reply(deps, message, text) do
    Telegram.send_html(deps.telegram, message.chat.id, Formatting.escape(text),
      message_id: message.message_id
    )

    :ok
  end

  defp reaction_emoji do
    Application.get_env(:transcriptor_bot, :reaction_emoji, "👀")
  end
end
