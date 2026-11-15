import Config

config :transcriptor_bot,
  start_bot: false,
  owner_telegram_user_id: System.get_env("OWNER_TELEGRAM_USER_ID", "14977303"),
  bot_token: System.get_env("BOT_TOKEN", "dev_token"),
  telegram_api_base_url: System.get_env("TELEGRAM_API_BASE_URL", "http://127.0.0.1:8081"),
  database_path: Path.join(File.cwd!(), "tmp/transcriptor_bot.sqlite3"),
  work_dir: Path.join(File.cwd!(), "tmp/work")
