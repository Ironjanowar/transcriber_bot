defmodule TranscriptorBot.FakeQueue do
  @moduledoc false
  use GenServer

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts)
  end

  def set_full(queue, full), do: GenServer.call(queue, {:set_full, full})

  def enqueued(queue), do: GenServer.call(queue, :enqueued)

  @impl true
  def init(opts) do
    {:ok,
     %{
       full: Keyword.get(opts, :full, false),
       enqueued: [],
       status: Keyword.get(opts, :status, %{queued: 0, running: 0, pending: 0})
     }}
  end

  @impl true
  def handle_call({:set_full, full}, _from, state), do: {:reply, :ok, %{state | full: full}}

  def handle_call(:enqueued, _from, state), do: {:reply, Enum.reverse(state.enqueued), state}

  def handle_call({:enqueue, attrs}, _from, state) do
    if state.full do
      {:reply, {:error, :queue_full}, state}
    else
      job =
        struct(
          TranscriptorBot.Store.Job,
          Map.merge(%{id: length(state.enqueued) + 1, status: "queued"}, attrs)
        )

      {:reply, {:ok, job}, %{state | enqueued: [job | state.enqueued]}}
    end
  end

  def handle_call(:status, _from, state), do: {:reply, state.status, state}
end
