defmodule TranscriptorBot.WorkerBehaviour do
  @moduledoc false
  @callback perform(TranscriptorBot.Store.Job.t(), keyword()) ::
              :ok | {:error, term(), :retryable | :permanent}
end
