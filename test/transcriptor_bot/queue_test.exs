defmodule TranscriptorBot.QueueTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureLog

  alias TranscriptorBot.{FakeWorker, Queue, Store}

  setup do
    dir = Path.join(System.tmp_dir!(), "queue_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    path = Path.join(dir, "db.sqlite3")

    store = start_supervised!({Store, database_path: path})

    on_exit(fn -> File.rm_rf!(dir) end)

    {:ok, store: store, path: path}
  end

  defp start_queue(store, opts \\ []) do
    start_supervised!(
      {Queue,
       Keyword.merge(
         [
           store: store,
           worker: FakeWorker,
           worker_opts: [test: self()],
           retry_delays_ms: [10, 20],
           poll_interval_ms: 60_000
         ],
         opts
       )}
    )
  end

  defp job_attrs(attrs \\ []) do
    Enum.into(attrs, %{
      update_id: System.unique_integer([:positive]),
      chat_id: -100,
      message_id: System.unique_integer([:positive]),
      file_id: "file",
      file_unique_id: "unique",
      kind: "voice",
      mime_type: "audio/ogg",
      file_name: nil,
      requested_by: 42,
      duration_ms: 1_000
    })
  end

  defp eventually(fun, attempts \\ 100) do
    Enum.reduce_while(1..attempts, nil, fn _i, _acc ->
      case fun.() do
        true -> {:halt, true}
        false -> Process.sleep(10) && {:cont, false}
      end
    end)
  end

  test "processes a queued job and marks it complete", %{store: store} do
    queue = start_queue(store)
    {:ok, job} = Queue.enqueue(queue, job_attrs())

    assert_receive {:performing, job_id, _pid}, 500
    assert job_id == job.id

    assert eventually(fn -> Store.get_job(store, job.id).status == "completed" end)
  end

  test "runs one job at a time in FIFO order", %{store: store} do
    queue =
      start_queue(store,
        worker_opts: [test: self(), fun: fn _ -> receive do: (:continue -> :ok) end]
      )

    {:ok, first} = Queue.enqueue(queue, job_attrs())
    {:ok, second} = Queue.enqueue(queue, job_attrs())

    assert_receive {:performing, first_id, first_pid}, 500
    assert first_id == first.id
    refute_receive {:performing, _, _}, 100

    send(first_pid, :continue)

    assert_receive {:performing, second_id, second_pid}, 500
    assert second_id == second.id
    send(second_pid, :continue)

    assert eventually(fn -> Store.get_job(store, second.id).status == "completed" end)
  end

  test "recovers a running job after restart", %{store: store} do
    {:ok, job} = Store.enqueue(store, job_attrs())
    {:ok, _} = Store.claim_next(store)

    _queue = start_queue(store)

    assert_receive {:performing, job_id, _}, 500
    assert job_id == job.id
    assert eventually(fn -> Store.get_job(store, job.id).status == "completed" end)
  end

  test "retries twice with increasing delay and then succeeds", %{store: store} do
    counter = :counters.new(1, [])
    queue = start_queue(store, worker_opts: [test: self(), fun: retry_fun(counter, 2)])

    {:ok, job} = Queue.enqueue(queue, job_attrs())

    assert_receive {:performing, _, _}, 500
    assert_receive {:performing, _, _}, 500
    assert_receive {:performing, _, _}, 500

    assert eventually(fn -> Store.get_job(store, job.id).status == "completed" end)
    assert Store.get_job(store, job.id).attempts == 2
  end

  test "does not retry permanent failures", %{store: store} do
    queue =
      start_queue(store,
        worker_opts: [test: self(), fun: fn _ -> {:error, :too_long, :permanent} end]
      )

    {:ok, job} = Queue.enqueue(queue, job_attrs())

    assert_receive {:performing, _, _}, 500
    refute_receive {:performing, _, _}, 200
    assert eventually(fn -> Store.get_job(store, job.id).status == "failed" end)
    assert Store.get_job(store, job.id).attempts == 0
  end

  test "fails permanently after the two retries are exhausted", %{store: store} do
    test = self()

    queue =
      start_queue(store,
        worker_opts: [test: self(), fun: fn _ -> {:error, :boom, :retryable} end],
        on_failure: fn job -> send(test, {:final_failure, job.id}) end
      )

    {:ok, job} = Queue.enqueue(queue, job_attrs())

    assert_receive {:performing, _, _}, 500
    assert_receive {:performing, _, _}, 500
    assert_receive {:performing, _, _}, 500
    refute_receive {:performing, _, _}, 200

    assert eventually(fn -> Store.get_job(store, job.id).status == "failed" end)
    assert Store.get_job(store, job.id).attempts == 2
    assert_receive {:final_failure, job_id}, 500
    assert job_id == job.id
  end

  test "logs a final failure notification error", %{store: store} do
    log =
      capture_log(fn ->
        queue =
          start_queue(store,
            worker_opts: [test: self(), fun: fn _ -> {:error, :boom, :retryable} end],
            retry_delays_ms: [],
            on_failure: fn _job -> {:error, :telegram_down} end
          )

        {:ok, job} = Queue.enqueue(queue, job_attrs())
        assert eventually(fn -> Store.get_job(store, job.id).status == "failed" end)
        Process.sleep(20)
      end)

    assert log =~ "Final failure notification failed"
    assert log =~ "telegram_down"
  end

  test "treats a crashed worker as a retryable failure", %{store: store} do
    queue =
      start_queue(store,
        worker_opts: [test: self(), fun: fn _ -> raise "boom" end],
        retry_delays_ms: [10]
      )

    {:ok, job} = Queue.enqueue(queue, job_attrs())

    assert_receive {:performing, _, _}, 500
    assert_receive {:performing, _, _}, 500
    assert eventually(fn -> Store.get_job(store, job.id).status == "failed" end)
    assert Store.get_job(store, job.id).attempts == 1
  end

  test "delegates the pending limit to the store", %{store: store} do
    queue =
      start_queue(store,
        worker_opts: [test: self(), fun: fn _ -> receive do: (:continue -> :ok) end]
      )

    for _ <- 1..25 do
      assert {:ok, _} = Queue.enqueue(queue, job_attrs())
    end

    assert {:error, :queue_full} = Queue.enqueue(queue, job_attrs())
  end

  test "reports queue status", %{store: store} do
    queue =
      start_queue(store, worker_opts: [test: self(), fun: fn _ -> Process.sleep(50) && :ok end])

    {:ok, _} = Queue.enqueue(queue, job_attrs())

    assert_receive {:performing, _, _}, 500
    status = Queue.status(queue)
    assert status.running == 1
    assert status.pending == 1
  end

  defp retry_fun(counter, failures) do
    fn _job ->
      :counters.add(counter, 1, 1)
      if :counters.get(counter, 1) <= failures, do: {:error, :transient, :retryable}, else: :ok
    end
  end
end
