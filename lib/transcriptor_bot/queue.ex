defmodule TranscriptorBot.Queue do
  @moduledoc """
  Global FIFO transcription queue.

  Exactly one job runs at a time. Every state transition is persisted in
  `TranscriptorBot.Store`, so accepted and running jobs survive a restart.
  Retryable failures get two retries with increasing delays.
  """

  use GenServer
  require Logger

  @default_retry_delays [30_000, 120_000]

  def start_link(opts) do
    case Keyword.get(opts, :name) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :name, __MODULE__),
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent
    }
  end

  @spec enqueue(GenServer.server(), map()) ::
          {:ok, TranscriptorBot.Store.Job.t()} | {:error, :queue_full}
  def enqueue(queue, attrs), do: GenServer.call(queue, {:enqueue, attrs})

  @spec status(GenServer.server()) :: map()
  def status(queue), do: GenServer.call(queue, :status)

  @impl true
  def init(opts) do
    store = Keyword.fetch!(opts, :store)
    recovered = TranscriptorBot.Store.recover(store)

    state = %{
      store: store,
      worker: Keyword.fetch!(opts, :worker),
      worker_opts: Keyword.get(opts, :worker_opts, []),
      retry_delays: Keyword.get(opts, :retry_delays_ms, @default_retry_delays),
      on_failure: Keyword.get(opts, :on_failure),
      current: nil
    }

    Logger.info("Transcription queue started; recovered #{recovered} running job(s)")
    send(self(), :dispatch)
    {:ok, state}
  end

  @impl true
  def handle_call({:enqueue, attrs}, _from, state) do
    case TranscriptorBot.Store.enqueue(state.store, attrs) do
      {:ok, job} ->
        send(self(), :dispatch)
        {:reply, {:ok, job}, state}

      {:error, :queue_full} = error ->
        {:reply, error, state}
    end
  end

  def handle_call(:status, _from, state) do
    {:reply, TranscriptorBot.Store.stats(state.store), state}
  end

  @impl true
  def handle_info(:dispatch, %{current: nil} = state) do
    case TranscriptorBot.Store.claim_next(state.store) do
      {:ok, job} ->
        {:noreply, start_worker(job, state)}

      :empty ->
        {:noreply, schedule_next_retry(state)}
    end
  end

  def handle_info(:dispatch, state), do: {:noreply, state}

  def handle_info({:worker_result, pid, result}, %{current: %{pid: pid}} = state) do
    Process.demonitor(state.current.ref, [:flush])
    job = state.current.job
    state = %{state | current: nil}
    state = handle_result(result, job, state)
    send(self(), :dispatch)
    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{current: %{ref: ref}} = state) do
    job = state.current.job
    Logger.error("Transcription worker crashed for job #{job.id}: #{inspect(reason)}")
    state = %{state | current: nil}
    state = handle_result({:error, {:crash, reason}, :retryable}, job, state)
    send(self(), :dispatch)
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{current: %{pid: pid}}) when is_pid(pid) do
    Process.exit(pid, :kill)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  defp start_worker(job, state) do
    parent = self()
    worker = state.worker
    worker_opts = state.worker_opts

    {pid, ref} =
      spawn_monitor(fn ->
        result =
          try do
            worker.perform(job, worker_opts)
          rescue
            error -> {:error, {:crash, error}, :retryable}
          catch
            kind, reason -> {:error, {:crash, {kind, reason}}, :retryable}
          end

        send(parent, {:worker_result, self(), result})
      end)

    %{state | current: %{ref: ref, pid: pid, job: job}}
  end

  defp handle_result(:ok, job, state) do
    :ok = TranscriptorBot.Store.complete(state.store, job.id)
    state
  end

  defp handle_result({:error, reason, :permanent}, job, state) do
    Logger.warning("Transcription job #{job.id} failed permanently: #{inspect(reason)}")
    :ok = TranscriptorBot.Store.fail(state.store, job.id, inspect(reason))
    state
  end

  defp handle_result({:error, reason, :retryable}, job, state) do
    if job.attempts < length(state.retry_delays) do
      delay = Enum.at(state.retry_delays, job.attempts)
      {:ok, _} = TranscriptorBot.Store.schedule_retry(state.store, job.id, delay)

      Logger.warning(
        "Transcription job #{job.id} failed; retrying in #{delay}ms: #{inspect(reason)}"
      )

      Process.send_after(self(), :dispatch, delay)
      state
    else
      Logger.warning("Transcription job #{job.id} failed after retries: #{inspect(reason)}")
      :ok = TranscriptorBot.Store.fail(state.store, job.id, inspect(reason))
      notify_failure(state, job)
      state
    end
  end

  defp handle_result(other, job, state) do
    Logger.warning("Transcription job #{job.id} returned unexpected result: #{inspect(other)}")
    :ok = TranscriptorBot.Store.fail(state.store, job.id, "unexpected_worker_result")
    state
  end

  defp notify_failure(%{on_failure: nil}, _job), do: :ok

  defp notify_failure(%{on_failure: fun}, job) when is_function(fun, 1) do
    case fun.(job) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("Final failure notification failed for job #{job.id}: #{inspect(reason)}")
        {:error, reason}

      _other ->
        :ok
    end
  rescue
    error ->
      Logger.error("Final failure notification crashed for job #{job.id}: #{inspect(error)}")
      {:error, error}
  end

  defp schedule_next_retry(state) do
    case TranscriptorBot.Store.stats(state.store) do
      %{next_retry_at: nil} ->
        state

      %{next_retry_at: next_retry_at} ->
        delay = max(next_retry_at - System.system_time(:millisecond), 0) + 10
        Process.send_after(self(), :dispatch, delay)
        state
    end
  end
end
