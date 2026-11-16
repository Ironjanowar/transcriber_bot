defmodule TranscriptorBot.FakeMedia do
  @moduledoc false

  def probe(path, opts) do
    if test = opts[:test], do: send(test, {:probe, path})
    fun = opts[:probe] || fn _ -> {:ok, 1_000} end
    fun.(path)
  end

  def validate_size(path, max), do: TranscriptorBot.Media.validate_size(path, max)
  def validate_duration(duration, max), do: TranscriptorBot.Media.validate_duration(duration, max)

  def normalize(input, output, opts) do
    if test = opts[:test], do: send(test, {:normalize, input, output})
    fun = opts[:normalize] || fn _, _ -> :ok end
    fun.(input, output)
  end
end
