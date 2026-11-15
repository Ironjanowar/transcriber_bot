defmodule TranscriptorBot.FakeTelegram do
  @moduledoc false
  @behaviour TranscriptorBot.Telegram

  alias TranscriptorBot.Telegram

  @impl true
  def init(_opts) do
    {:ok, agent} =
      Agent.start_link(fn ->
        %{
          calls: [],
          get_file: {:ok, %{file_path: "voice/file_1.ogg", file_size: 100}},
          download: :ok,
          send_html: {:ok, %{message_id: 1}},
          download_body: "audio-bytes"
        }
      end)

    agent
  end

  def client(opts \\ []), do: Telegram.client(Keyword.put(opts, :adapter, __MODULE__))

  @impl true
  def get_file(agent, file_id) do
    record(agent, {:get_file, file_id})
    Agent.get(agent, & &1.get_file)
  end

  @impl true
  def download_file(agent, file_path, dest, max_bytes) do
    record(agent, {:download_file, file_path, dest})
    result = Agent.get(agent, & &1.download)

    if result == :ok do
      body = Agent.get(agent, & &1.download_body)

      if max_bytes != :infinity and byte_size(body) > max_bytes do
        {:error, :too_large}
      else
        File.write!(dest, body)
        :ok
      end
    else
      result
    end
  end

  @impl true
  def send_html(agent, chat_id, html, opts) do
    record(agent, {:send_html, chat_id, html, opts})
    Agent.get(agent, & &1.send_html)
  end

  @impl true
  def react(agent, chat_id, message_id, emoji) do
    record(agent, {:react, chat_id, message_id, emoji})
    :ok
  end

  @impl true
  def remove_reaction(agent, chat_id, message_id) do
    record(agent, {:remove_reaction, chat_id, message_id})
    :ok
  end

  def put(%{state: agent}, key, value) do
    Agent.update(agent, &Map.put(&1, key, value))
  end

  def calls(agent), do: agent |> state() |> Agent.get(&Enum.reverse(&1.calls))

  def sent_html(client) do
    client
    |> calls()
    |> Enum.filter(&match?({:send_html, _, _, _}, &1))
    |> Enum.map(fn {:send_html, chat_id, html, opts} -> {chat_id, html, opts} end)
  end

  def reactions(client) do
    client
    |> calls()
    |> Enum.filter(&(match?({:react, _, _, _}, &1) or match?({:remove_reaction, _, _}, &1)))
  end

  defp state(%{state: agent}), do: agent
  defp state(agent) when is_pid(agent), do: agent

  defp record(agent, call),
    do: Agent.update(agent, &Map.update!(&1, :calls, fn calls -> [call | calls] end))
end
