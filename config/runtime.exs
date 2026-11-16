import Config

if config_env() == :prod do
  config :transcriptor_bot,
    start_bot: true,
    owner_telegram_user_id: System.fetch_env!("OWNER_TELEGRAM_USER_ID"),
    bot_token: System.get_env("BOT_TOKEN"),
    telegram_api_base_url: System.get_env("TELEGRAM_API_BASE_URL", "http://127.0.0.1:8081"),
    database_path:
      System.get_env("DATABASE_PATH") ||
        Path.join(
          System.user_home!(),
          ".local/share/transcriber_bot/transcriber_bot.sqlite3"
        ),
    work_dir:
      System.get_env("WORK_DIR") ||
        Path.join(System.user_home!(), ".local/share/transcriber_bot/work"),
    transcriber_command: System.get_env("TRANSCRIBER_COMMAND", "transcriptor"),
    transcriber_args: OptionParser.split(System.get_env("TRANSCRIBER_ARGS") || "")

  config :ex_gram,
    token: System.get_env("BOT_TOKEN"),
    adapter: ExGram.Adapter.Req,
    base_url: System.get_env("TELEGRAM_API_BASE_URL", "http://127.0.0.1:8081")
end
