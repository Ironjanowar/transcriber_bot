import Config

config :ex_gram, adapter: ExGram.Adapter.Req

config :transcriptor_bot,
  max_pending_jobs: 25,
  max_file_bytes: 500 * 1024 * 1024,
  max_duration_ms: 60 * 60 * 1000,
  retry_delays_ms: [30_000, 120_000],
  min_transcriber_timeout_ms: 15 * 60 * 1000,
  max_transcriber_timeout_ms: 2 * 60 * 60 * 1000,
  reaction_emoji: "👀"

import_config "#{config_env()}.exs"
