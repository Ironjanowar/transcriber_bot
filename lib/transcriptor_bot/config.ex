defmodule TranscriptorBot.Config do
  @moduledoc """
  Runtime configuration access.

  The owner id is read from `OWNER_TELEGRAM_USER_ID` at startup and is never
  mutable through bot commands.
  """

  @spec owner_id() :: integer()
  def owner_id do
    :transcriptor_bot
    |> Application.get_env(:owner_telegram_user_id)
    |> normalize_owner!(System.get_env("OWNER_TELEGRAM_USER_ID"))
  end

  defp normalize_owner!(value, _env) when is_integer(value) and value > 0, do: value

  defp normalize_owner!(value, _env) when is_binary(value) do
    case Integer.parse(value) do
      {id, ""} when id > 0 -> id
      _ -> invalid_owner!(value)
    end
  end

  defp normalize_owner!(nil, env) when is_binary(env) do
    normalize_owner!(env, env)
  end

  defp normalize_owner!(value, env), do: invalid_owner!(value || env)

  defp invalid_owner!(value) do
    raise ArgumentError,
          "OWNER_TELEGRAM_USER_ID must be an integer Telegram user id, got: #{inspect(value)}"
  end
end
