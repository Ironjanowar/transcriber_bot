defmodule TranscriptorBot.Application do
  @moduledoc false

  use Application

  alias TranscriptorBot.{Bot, Config, Queue, Store, Telegram, Worker}

  @impl true
  def start(_type, _args) do
    children = children()

    {:ok, supervisor} =
      Supervisor.start_link(children, strategy: :one_for_one, name: TranscriptorBot.Supervisor)

    {:ok, supervisor}
  end

  @doc false
  def children do
    if Application.get_env(:transcriptor_bot, :start_bot, false) do
      owner_id = Config.owner_id()
      telegram = Telegram.client()
      work_dir = Application.get_env(:transcriptor_bot, :work_dir, System.tmp_dir!())

      worker_opts = [
        telegram: telegram,
        store: Store,
        work_dir: work_dir,
        send_interval_ms: Application.get_env(:transcriptor_bot, :send_interval_ms, 1_000)
      ]

      [
        {Store,
         [
           name: Store,
           owner_id: owner_id,
           database_path: Application.fetch_env!(:transcriptor_bot, :database_path),
           max_pending: Application.get_env(:transcriptor_bot, :max_pending_jobs, 25)
         ]},
        ExGram,
        {Queue,
         [
           name: Queue,
           store: Store,
           worker: Worker,
           worker_opts: worker_opts,
           retry_delays_ms:
             Application.get_env(:transcriptor_bot, :retry_delays_ms, [30_000, 120_000]),
           on_failure: fn job -> Worker.notify_final_failure(job, worker_opts) end
         ]},
        {Bot,
         [
           method: :polling,
           token: Application.fetch_env!(:transcriptor_bot, :bot_token)
         ]}
      ]
    else
      []
    end
  end
end
