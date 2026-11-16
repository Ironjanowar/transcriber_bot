defmodule TranscriptorBot.Store do
  @moduledoc """
  SQLite-backed operational store for jobs, administrators and group state.

  All access is serialized through one GenServer so queue transitions are atomic.
  Audio and transcripts are never stored here.
  """

  use GenServer
  require Logger

  alias Exqlite.Sqlite3

  defmodule Job do
    @moduledoc false
    @enforce_keys [:id, :status]
    defstruct [
      :id,
      :update_id,
      :chat_id,
      :message_id,
      :file_id,
      :file_unique_id,
      :kind,
      :mime_type,
      :file_name,
      :requested_by,
      :duration_ms,
      :delivered_parts,
      :status,
      :attempts,
      :next_attempt_at,
      :created_at,
      :started_at,
      :finished_at,
      :error
    ]
  end

  @type job :: %Job{}

  # ---------------------------------------------------------------------------
  # Client API
  # ---------------------------------------------------------------------------

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

  @spec enqueue(GenServer.server(), map()) :: {:ok, job()} | {:error, :queue_full}
  def enqueue(store, attrs), do: GenServer.call(store, {:enqueue, attrs})

  @spec pending_count(GenServer.server()) :: non_neg_integer()
  def pending_count(store), do: GenServer.call(store, :pending_count)

  @spec claim_next(GenServer.server(), integer() | nil) :: {:ok, job()} | :empty
  def claim_next(store, now \\ nil), do: GenServer.call(store, {:claim_next, now})

  @spec complete(GenServer.server(), integer()) :: :ok
  def complete(store, id), do: GenServer.call(store, {:complete, id})

  @spec fail(GenServer.server(), integer(), String.t()) :: :ok
  def fail(store, id, error), do: GenServer.call(store, {:fail, id, error})

  @spec schedule_retry(GenServer.server(), integer(), non_neg_integer(), integer() | nil) ::
          {:ok, job()}
  def schedule_retry(store, id, delay_ms, now \\ nil),
    do: GenServer.call(store, {:schedule_retry, id, delay_ms, now})

  @spec get_job(GenServer.server(), integer()) :: job() | nil
  def get_job(store, id), do: GenServer.call(store, {:get_job, id})

  @spec mark_part_delivered(GenServer.server(), integer(), non_neg_integer()) :: :ok
  def mark_part_delivered(store, id, count),
    do: GenServer.call(store, {:mark_part_delivered, id, count})

  @spec recover(GenServer.server()) :: non_neg_integer()
  def recover(store), do: GenServer.call(store, :recover)

  @spec stats(GenServer.server()) :: map()
  def stats(store), do: GenServer.call(store, :stats)

  @spec ensure_owner(GenServer.server(), integer()) :: :ok
  def ensure_owner(store, user_id), do: GenServer.call(store, {:ensure_owner, user_id})

  @spec admin?(GenServer.server(), integer()) :: boolean()
  def admin?(store, user_id), do: GenServer.call(store, {:admin?, user_id})

  @spec add_admin(GenServer.server(), integer()) :: :ok | :already_admin
  def add_admin(store, user_id), do: GenServer.call(store, {:add_admin, user_id})

  @spec remove_admin(GenServer.server(), integer()) :: :ok | :owner | :not_admin
  def remove_admin(store, user_id), do: GenServer.call(store, {:remove_admin, user_id})

  @spec list_admins(GenServer.server()) :: [integer()]
  def list_admins(store), do: GenServer.call(store, :list_admins)

  @spec allow(GenServer.server(), integer()) :: :ok
  def allow(store, chat_id), do: GenServer.call(store, {:allow, chat_id})

  @spec deny(GenServer.server(), integer()) :: :ok
  def deny(store, chat_id), do: GenServer.call(store, {:deny, chat_id})

  @spec enable(GenServer.server(), integer()) :: :ok | {:error, :not_allowed}
  def enable(store, chat_id), do: GenServer.call(store, {:enable, chat_id})

  @spec disable(GenServer.server(), integer()) :: :ok
  def disable(store, chat_id), do: GenServer.call(store, {:disable, chat_id})

  @spec chat_state(GenServer.server(), integer()) ::
          %{allowed: boolean(), enabled: boolean()} | nil
  def chat_state(store, chat_id), do: GenServer.call(store, {:chat_state, chat_id})

  # ---------------------------------------------------------------------------
  # Server
  # ---------------------------------------------------------------------------

  @impl true
  def init(opts) do
    path = Keyword.fetch!(opts, :database_path)
    File.mkdir_p!(Path.dirname(path))

    {:ok, conn} = Sqlite3.open(path)
    Sqlite3.execute(conn, "PRAGMA busy_timeout=5000")
    Sqlite3.execute(conn, "PRAGMA journal_mode=WAL")
    Sqlite3.execute(conn, "PRAGMA foreign_keys=ON")
    migrate!(conn)

    state = %{conn: conn, path: path, max_pending: Keyword.get(opts, :max_pending, 25)}

    case Keyword.get(opts, :owner_id) do
      nil ->
        {:ok, state}

      owner_id ->
        case ensure_owner_conn(conn, owner_id) do
          :ok ->
            {:ok, state}

          {:error, reason} ->
            Sqlite3.close(conn)
            {:stop, reason}
        end
    end
  end

  @impl true
  def terminate(_reason, %{conn: conn}) do
    Sqlite3.close(conn)
    :ok
  end

  @impl true
  def handle_call({:enqueue, attrs}, _from, state) do
    case get_job_by_update_id(state.conn, attrs[:update_id]) do
      %Job{} = existing ->
        {:reply, {:ok, existing}, state}

      nil ->
        enqueue_new(attrs, state)
    end
  end

  def handle_call(:pending_count, _from, state) do
    {:reply, count_pending(state), state}
  end

  def handle_call({:claim_next, now}, _from, state) do
    now = now || now()

    case running_count(state) do
      0 ->
        case query(
               state.conn,
               """
               SELECT id FROM jobs
               WHERE status = 'queued'
                  OR (status = 'retrying' AND next_attempt_at <= ?)
               ORDER BY id ASC
               LIMIT 1
               """,
               [now]
             ) do
          {:ok, [[id]]} ->
            exec!(
              state.conn,
              "UPDATE jobs SET status = 'running', started_at = ?, next_attempt_at = NULL WHERE id = ?",
              [now, id]
            )

            {:reply, {:ok, get_job_by_id(state.conn, id)}, state}

          _ ->
            {:reply, :empty, state}
        end

      _ ->
        {:reply, :empty, state}
    end
  end

  def handle_call({:complete, id}, _from, state) do
    exec!(
      state.conn,
      "UPDATE jobs SET status = 'completed', finished_at = ?, error = NULL WHERE id = ?",
      [now(), id]
    )

    {:reply, :ok, state}
  end

  def handle_call({:fail, id, error}, _from, state) do
    exec!(
      state.conn,
      "UPDATE jobs SET status = 'failed', finished_at = ?, next_attempt_at = NULL, error = ? WHERE id = ?",
      [now(), error, id]
    )

    {:reply, :ok, state}
  end

  def handle_call({:schedule_retry, id, delay_ms, now}, _from, state) do
    now = now || now()

    exec!(
      state.conn,
      """
      UPDATE jobs
      SET status = 'retrying', attempts = attempts + 1,
          next_attempt_at = ?, started_at = NULL
      WHERE id = ?
      """,
      [now + delay_ms, id]
    )

    {:reply, {:ok, get_job_by_id(state.conn, id)}, state}
  end

  def handle_call({:get_job, id}, _from, state) do
    {:reply, get_job_by_id(state.conn, id), state}
  end

  def handle_call({:mark_part_delivered, id, count}, _from, state) do
    exec!(state.conn, "UPDATE jobs SET delivered_parts = MAX(delivered_parts, ?) WHERE id = ?", [
      count,
      id
    ])

    {:reply, :ok, state}
  end

  def handle_call(:recover, _from, state) do
    {:ok, [[count]]} =
      query(state.conn, "SELECT COUNT(*) FROM jobs WHERE status = 'running'", [])

    if count > 0 do
      exec!(
        state.conn,
        "UPDATE jobs SET status = 'queued', started_at = NULL WHERE status = 'running'",
        []
      )

      Logger.info("Recovered #{count} running transcription job(s) after restart")
    end

    {:reply, count, state}
  end

  def handle_call(:stats, _from, state) do
    {:ok, rows} =
      query(state.conn, "SELECT status, COUNT(*) FROM jobs GROUP BY status", [])

    counts = Map.new(rows, fn [status, count] -> {status, count} end)

    {:ok, [[oldest]]} =
      query(state.conn, "SELECT MIN(id) FROM jobs WHERE status = 'queued'", [])

    {:ok, [[next_retry]]} =
      query(
        state.conn,
        "SELECT MIN(next_attempt_at) FROM jobs WHERE status = 'retrying'",
        []
      )

    queued = Map.get(counts, "queued", 0)
    running = Map.get(counts, "running", 0)
    retrying = Map.get(counts, "retrying", 0)

    {:reply,
     %{
       queued: queued,
       running: running,
       retrying: retrying,
       completed: Map.get(counts, "completed", 0),
       failed: Map.get(counts, "failed", 0),
       pending: queued + running + retrying,
       oldest_queued_id: oldest,
       next_retry_at: next_retry
     }, state}
  end

  def handle_call({:ensure_owner, user_id}, _from, state) do
    {:reply, ensure_owner_conn(state.conn, user_id), state}
  end

  def handle_call({:admin?, user_id}, _from, state) do
    {:ok, rows} = query(state.conn, "SELECT 1 FROM admins WHERE user_id = ?", [user_id])
    {:reply, rows != [], state}
  end

  def handle_call({:add_admin, user_id}, _from, state) do
    reply =
      case query(state.conn, "SELECT 1 FROM admins WHERE user_id = ?", [user_id]) do
        {:ok, []} ->
          exec!(
            state.conn,
            "INSERT INTO admins (user_id, is_owner, created_at) VALUES (?, 0, ?)",
            [user_id, now()]
          )

          :ok

        _ ->
          :already_admin
      end

    {:reply, reply, state}
  end

  def handle_call({:remove_admin, user_id}, _from, state) do
    reply =
      case query(state.conn, "SELECT is_owner FROM admins WHERE user_id = ?", [user_id]) do
        {:ok, [[1]]} ->
          :owner

        {:ok, [[0]]} ->
          exec!(state.conn, "DELETE FROM admins WHERE user_id = ?", [user_id])
          :ok

        _ ->
          :not_admin
      end

    {:reply, reply, state}
  end

  def handle_call(:list_admins, _from, state) do
    {:ok, rows} = query(state.conn, "SELECT user_id FROM admins ORDER BY user_id", [])
    {:reply, Enum.map(rows, fn [id] -> id end), state}
  end

  def handle_call({:allow, chat_id}, _from, state) do
    exec!(
      state.conn,
      """
      INSERT INTO chats (chat_id, allowed, enabled, updated_at) VALUES (?, 1, 1, ?)
      ON CONFLICT(chat_id) DO UPDATE SET allowed = 1, enabled = 1, updated_at = excluded.updated_at
      """,
      [chat_id, now()]
    )

    {:reply, :ok, state}
  end

  def handle_call({:deny, chat_id}, _from, state) do
    upsert_chat(state, chat_id, 0, 0)
    {:reply, :ok, state}
  end

  def handle_call({:enable, chat_id}, _from, state) do
    case load_chat_state(state, chat_id) do
      %{allowed: true} ->
        upsert_chat(state, chat_id, 1, 1)
        {:reply, :ok, state}

      _ ->
        {:reply, {:error, :not_allowed}, state}
    end
  end

  def handle_call({:disable, chat_id}, _from, state) do
    case load_chat_state(state, chat_id) do
      nil -> upsert_chat(state, chat_id, 0, 0)
      %{allowed: allowed} -> upsert_chat(state, chat_id, bool_to_int(allowed), 0)
    end

    {:reply, :ok, state}
  end

  def handle_call({:chat_state, chat_id}, _from, state) do
    {:reply, load_chat_state(state, chat_id), state}
  end

  # ---------------------------------------------------------------------------
  # Internals
  # ---------------------------------------------------------------------------

  defp enqueue_new(attrs, state) do
    if count_pending(state) >= state.max_pending do
      {:reply, {:error, :queue_full}, state}
    else
      now = now()

      params = [
        attrs[:update_id],
        attrs[:chat_id],
        attrs[:message_id],
        attrs[:file_id],
        attrs[:file_unique_id],
        attrs[:kind],
        attrs[:mime_type],
        attrs[:file_name],
        attrs[:requested_by],
        attrs[:duration_ms],
        now
      ]

      exec!(
        state.conn,
        """
        INSERT INTO jobs
          (update_id, chat_id, message_id, file_id, file_unique_id, kind, mime_type,
           file_name, requested_by, duration_ms, status, attempts, created_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'queued', 0, ?)
        """,
        params
      )

      {:ok, [[id]]} = query(state.conn, "SELECT last_insert_rowid()", [])
      {:reply, {:ok, get_job_by_id(state.conn, id)}, state}
    end
  end

  defp ensure_owner_conn(conn, user_id) do
    exec!(conn, "BEGIN IMMEDIATE", [])

    result =
      case query(conn, "SELECT value FROM metadata WHERE key = 'owner_id'", []) do
        {:ok, []} ->
          exec!(conn, "INSERT INTO metadata (key, value) VALUES ('owner_id', ?)", [user_id])

          exec!(
            conn,
            "INSERT INTO admins (user_id, is_owner, created_at) VALUES (?, 1, ?) ON CONFLICT(user_id) DO UPDATE SET is_owner = 1",
            [user_id, now()]
          )

          :ok

        {:ok, [[persisted]]} ->
          persisted = if is_binary(persisted), do: String.to_integer(persisted), else: persisted
          if persisted == user_id, do: :ok, else: {:error, {:owner_mismatch, persisted, user_id}}
      end

    exec!(conn, if(result == :ok, do: "COMMIT", else: "ROLLBACK"), [])
    result
  end

  defp migrate!(conn) do
    statements = [
      """
      CREATE TABLE IF NOT EXISTS jobs (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        update_id INTEGER,
        chat_id INTEGER NOT NULL,
        message_id INTEGER NOT NULL,
        file_id TEXT NOT NULL,
        file_unique_id TEXT,
        kind TEXT NOT NULL,
        mime_type TEXT,
        file_name TEXT,
        requested_by INTEGER NOT NULL,
        duration_ms INTEGER,
        delivered_parts INTEGER NOT NULL DEFAULT 0,
        status TEXT NOT NULL,
        attempts INTEGER NOT NULL DEFAULT 0,
        next_attempt_at INTEGER,
        created_at INTEGER NOT NULL,
        started_at INTEGER,
        finished_at INTEGER,
        error TEXT
      )
      """,
      "CREATE INDEX IF NOT EXISTS jobs_status_idx ON jobs (status, id)",
      "CREATE INDEX IF NOT EXISTS jobs_next_attempt_idx ON jobs (status, next_attempt_at)",
      "CREATE UNIQUE INDEX IF NOT EXISTS jobs_update_id_idx ON jobs (update_id)",
      """
      CREATE TABLE IF NOT EXISTS admins (
        user_id INTEGER PRIMARY KEY,
        is_owner INTEGER NOT NULL DEFAULT 0,
        created_at INTEGER NOT NULL
      )
      """,
      "CREATE UNIQUE INDEX IF NOT EXISTS admins_single_owner_idx ON admins (is_owner) WHERE is_owner = 1",
      """
      CREATE TABLE IF NOT EXISTS metadata (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
      )
      """,
      """
      CREATE TABLE IF NOT EXISTS chats (
        chat_id INTEGER PRIMARY KEY,
        allowed INTEGER NOT NULL DEFAULT 0,
        enabled INTEGER NOT NULL DEFAULT 0,
        updated_at INTEGER NOT NULL
      )
      """
    ]

    Enum.each(statements, &exec!(conn, &1, []))
  end

  defp count_pending(state) do
    {:ok, [[count]]} =
      query(
        state.conn,
        "SELECT COUNT(*) FROM jobs WHERE status IN ('queued', 'running', 'retrying')",
        []
      )

    count
  end

  defp running_count(state) do
    {:ok, [[count]]} = query(state.conn, "SELECT COUNT(*) FROM jobs WHERE status = 'running'", [])
    count
  end

  defp get_job_by_id(conn, id) do
    sql = """
    SELECT id, update_id, chat_id, message_id, file_id, file_unique_id, kind, mime_type,
           file_name, requested_by, duration_ms, delivered_parts, status, attempts, next_attempt_at,
           created_at, started_at, finished_at, error
    FROM jobs WHERE id = ?
    """

    case query(conn, sql, [id]) do
      {:ok, [row]} -> row_to_job(row)
      _ -> nil
    end
  end

  defp get_job_by_update_id(conn, update_id) do
    case query(conn, "SELECT id FROM jobs WHERE update_id = ?", [update_id]) do
      {:ok, [[id]]} -> get_job_by_id(conn, id)
      _ -> nil
    end
  end

  defp row_to_job([
         id,
         update_id,
         chat_id,
         message_id,
         file_id,
         file_unique_id,
         kind,
         mime_type,
         file_name,
         requested_by,
         duration_ms,
         delivered_parts,
         status,
         attempts,
         next_attempt_at,
         created_at,
         started_at,
         finished_at,
         error
       ]) do
    %Job{
      id: id,
      update_id: update_id,
      chat_id: chat_id,
      message_id: message_id,
      file_id: file_id,
      file_unique_id: file_unique_id,
      kind: kind,
      mime_type: mime_type,
      file_name: file_name,
      requested_by: requested_by,
      duration_ms: duration_ms,
      delivered_parts: delivered_parts,
      status: status,
      attempts: attempts,
      next_attempt_at: next_attempt_at,
      created_at: created_at,
      started_at: started_at,
      finished_at: finished_at,
      error: error
    }
  end

  defp load_chat_state(state, chat_id) do
    case query(state.conn, "SELECT allowed, enabled FROM chats WHERE chat_id = ?", [chat_id]) do
      {:ok, [[allowed, enabled]]} -> %{allowed: allowed == 1, enabled: enabled == 1}
      _ -> nil
    end
  end

  defp upsert_chat(state, chat_id, allowed, enabled) do
    exec!(
      state.conn,
      """
      INSERT INTO chats (chat_id, allowed, enabled, updated_at) VALUES (?, ?, ?, ?)
      ON CONFLICT(chat_id) DO UPDATE SET
        allowed = excluded.allowed,
        enabled = excluded.enabled,
        updated_at = excluded.updated_at
      """,
      [chat_id, allowed, enabled, now()]
    )
  end

  defp bool_to_int(true), do: 1
  defp bool_to_int(false), do: 0

  defp exec!(conn, sql, params) do
    case Sqlite3.prepare(conn, sql) do
      {:ok, statement} ->
        :ok = Sqlite3.bind(statement, params)

        result =
          case Sqlite3.step(conn, statement) do
            :done -> :ok
            {:row, _} -> :ok
            {:error, error} -> raise "SQLite step failed: #{inspect(error)}"
          end

        Sqlite3.release(conn, statement)
        result

      {:error, error} ->
        raise "SQLite prepare failed: #{inspect(error)}"
    end
  end

  defp query(conn, sql, params) do
    with {:ok, statement} <- Sqlite3.prepare(conn, sql),
         :ok <- Sqlite3.bind(statement, params),
         {:ok, rows} <- collect(conn, statement, []) do
      Sqlite3.release(conn, statement)
      {:ok, rows}
    end
  end

  defp collect(conn, statement, acc) do
    case Sqlite3.step(conn, statement) do
      {:row, row} -> collect(conn, statement, [row | acc])
      :done -> {:ok, Enum.reverse(acc)}
      {:error, error} -> {:error, error}
    end
  end

  defp now, do: System.system_time(:millisecond)
end
