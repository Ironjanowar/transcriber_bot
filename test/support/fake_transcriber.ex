defmodule TranscriptorBot.FakeTranscriber do
  @moduledoc false

  def transcribe(path, duration, opts) do
    if test = opts[:test], do: send(test, {:transcribe, path, duration})
    fun = opts[:fun] || fn _, _ -> {:ok, "Hola mundo."} end
    fun.(path, duration)
  end
end
