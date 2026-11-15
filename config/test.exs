import Config

config :ex_gram,
  token: "test_token",
  adapter: ExGram.Adapter.Test

config :transcriptor_bot,
  start_bot: false,
  owner_telegram_user_id: 14_977_303,
  bot_token: "test_token",
  telegram_api_base_url: "http://127.0.0.1:8081",
  database_path: Path.join(System.tmp_dir!(), "transcriptor_bot_test.sqlite3"),
  work_dir: Path.join(System.tmp_dir!(), "transcriptor_bot_test")
