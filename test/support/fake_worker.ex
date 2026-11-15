defmodule TranscriptorBot.FakeWorker do
  @moduledoc false
  @behaviour TranscriptorBot.WorkerBehaviour

  @impl true
  def perform(job, opts) do
    if test = opts[:test], do: send(test, {:performing, job.id, self()})
    fun = opts[:fun] || fn _ -> :ok end
    fun.(job)
  end
end
