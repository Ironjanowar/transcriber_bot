defmodule TranscriptorBot.StoreTest do
  use ExUnit.Case, async: true

  alias TranscriptorBot.Store

  setup do
    dir = Path.join(System.tmp_dir!(), "transcriptor_store_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    path = Path.join(dir, "test.sqlite3")

    on_exit(fn -> File.rm_rf!(dir) end)

    {:ok, path: path}
  end

  defp start_store(path, opts \\ []) do
    start_supervised!({Store, Keyword.merge([database_path: path, max_pending: 25], opts)})
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

  describe "jobs" do
    test "persists a queued job and reads it back", %{path: path} do
      store = start_store(path)

      assert {:ok, job} = Store.enqueue(store, job_attrs())
      assert job.status == "queued"
      assert job.attempts == 0

      assert %{id: id, file_id: "file", chat_id: -100} = Store.get_job(store, job.id)
      assert id == job.id
    end

    test "survives a restart", %{path: path} do
      store = start_store(path)
      assert {:ok, job} = Store.enqueue(store, job_attrs())

      stop_supervised(Store)
      store = start_store(path)

      assert %{id: id, status: "queued"} = Store.get_job(store, job.id)
      assert id == job.id
    end

    test "deduplicates redelivered Telegram updates by update_id", %{path: path} do
      store = start_store(path)
      attrs = job_attrs(update_id: 987, chat_id: -100, message_id: 7)

      assert {:ok, first} = Store.enqueue(store, attrs)
      assert {:ok, duplicate} = Store.enqueue(store, %{attrs | file_id: "changed"})
      assert duplicate.id == first.id
      assert duplicate.file_id == "file"
      assert Store.pending_count(store) == 1
    end

    test "message ids remain local to each chat", %{path: path} do
      store = start_store(path)

      assert {:ok, first} =
               Store.enqueue(store, job_attrs(update_id: 1, chat_id: -100, message_id: 7))

      assert {:ok, second} =
               Store.enqueue(store, job_attrs(update_id: 2, chat_id: -200, message_id: 7))

      refute first.id == second.id
    end

    test "enforces the pending limit", %{path: path} do
      store = start_store(path, max_pending: 2)

      assert {:ok, _} = Store.enqueue(store, job_attrs())
      assert {:ok, _} = Store.enqueue(store, job_attrs())
      assert {:error, :queue_full} = Store.enqueue(store, job_attrs())
      assert Store.pending_count(store) == 2
    end

    test "claims the oldest queued job once", %{path: path} do
      store = start_store(path)
      {:ok, first} = Store.enqueue(store, job_attrs())
      {:ok, second} = Store.enqueue(store, job_attrs())

      assert {:ok, claimed} = Store.claim_next(store)
      assert claimed.id == first.id
      assert claimed.status == "running"
      assert claimed.started_at

      assert :empty = Store.claim_next(store)

      Store.complete(store, first.id)
      assert {:ok, claimed} = Store.claim_next(store)
      assert claimed.id == second.id
    end

    test "recovers a running job as queued after a restart", %{path: path} do
      store = start_store(path)
      {:ok, job} = Store.enqueue(store, job_attrs())
      {:ok, _} = Store.claim_next(store)

      stop_supervised(Store)
      store = start_store(path)

      assert Store.recover(store) == 1
      assert %{status: "queued", started_at: nil} = Store.get_job(store, job.id)
    end

    test "retries increment attempts and respect the next attempt time", %{path: path} do
      store = start_store(path)
      {:ok, job} = Store.enqueue(store, job_attrs())
      now = System.system_time(:millisecond)

      assert {:ok, retried} = Store.schedule_retry(store, job.id, 5_000, now)
      assert retried.status == "retrying"
      assert retried.attempts == 1
      assert retried.next_attempt_at == now + 5_000

      assert :empty = Store.claim_next(store, now + 4_999)
      assert {:ok, claimed} = Store.claim_next(store, now + 5_000)
      assert claimed.id == job.id
      assert claimed.attempts == 1
    end

    test "persists multipart delivery progress across restart", %{path: path} do
      store = start_store(path)
      {:ok, job} = Store.enqueue(store, job_attrs())

      assert :ok = Store.mark_part_delivered(store, job.id, 2)
      assert Store.get_job(store, job.id).delivered_parts == 2

      stop_supervised(Store)
      store = start_store(path)
      assert Store.get_job(store, job.id).delivered_parts == 2
    end

    test "completed jobs free pending capacity", %{path: path} do
      store = start_store(path, max_pending: 1)
      {:ok, job} = Store.enqueue(store, job_attrs())
      {:ok, _} = Store.claim_next(store)

      assert {:error, :queue_full} = Store.enqueue(store, job_attrs())
      assert :ok = Store.complete(store, job.id)
      assert {:ok, _} = Store.enqueue(store, job_attrs())
    end

    test "reports queue statistics", %{path: path} do
      store = start_store(path)
      {:ok, first} = Store.enqueue(store, job_attrs())
      {:ok, second} = Store.enqueue(store, job_attrs())
      {:ok, third} = Store.enqueue(store, job_attrs())
      {:ok, _} = Store.claim_next(store)
      Store.complete(store, first.id)
      Store.fail(store, second.id, "boom")

      stats = Store.stats(store)

      assert stats.completed == 1
      assert stats.failed == 1
      assert stats.queued == 1
      assert stats.pending == 1
      assert stats.oldest_queued_id == third.id
    end
  end

  describe "administrators" do
    test "bootstraps the owner from the store option", %{path: path} do
      store = start_store(path, owner_id: 14_977_303)

      assert Store.admin?(store, 14_977_303)
    end

    test "the owner is an immutable administrator", %{path: path} do
      store = start_store(path)

      assert :ok = Store.ensure_owner(store, 14_977_303)
      assert :ok = Store.ensure_owner(store, 14_977_303)
      assert Store.admin?(store, 14_977_303)
      assert :owner = Store.remove_admin(store, 14_977_303)
      assert Store.admin?(store, 14_977_303)
    end

    test "refuses to start when the configured owner differs from the persisted owner", %{
      path: path
    } do
      _store = start_store(path, owner_id: 111)
      stop_supervised(Store)

      Process.flag(:trap_exit, true)

      assert {:error, {:owner_mismatch, 111, 222}} =
               Store.start_link(database_path: path, owner_id: 222)

      refute_receive {:EXIT, _, _}
    end

    test "adds and removes administrators", %{path: path} do
      store = start_store(path)
      Store.ensure_owner(store, 1)

      refute Store.admin?(store, 2)
      assert :ok = Store.add_admin(store, 2)
      assert :already_admin = Store.add_admin(store, 2)
      assert Store.admin?(store, 2)

      assert :ok = Store.remove_admin(store, 2)
      refute Store.admin?(store, 2)
      assert :not_admin = Store.remove_admin(store, 2)
    end
  end

  describe "group authorization" do
    test "allow activates a group and deny deauthorizes it", %{path: path} do
      store = start_store(path)

      assert Store.chat_state(store, -100) == nil

      assert :ok = Store.allow(store, -100)
      assert %{allowed: true, enabled: true} = Store.chat_state(store, -100)

      assert :ok = Store.disable(store, -100)
      assert %{allowed: true, enabled: false} = Store.chat_state(store, -100)

      assert :ok = Store.enable(store, -100)
      assert %{allowed: true, enabled: true} = Store.chat_state(store, -100)

      assert :ok = Store.deny(store, -100)
      assert %{allowed: false, enabled: false} = Store.chat_state(store, -100)
    end

    test "enable fails for a group that was never authorized", %{path: path} do
      store = start_store(path)
      assert {:error, :not_allowed} = Store.enable(store, -100)
    end

    test "disable preserves authorization", %{path: path} do
      store = start_store(path)
      :ok = Store.allow(store, -100)
      :ok = Store.disable(store, -100)
      assert %{allowed: true, enabled: false} = Store.chat_state(store, -100)
    end
  end
end
