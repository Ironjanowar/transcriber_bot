defmodule TranscriptorBot.MixProject do
  use Mix.Project

  def project do
    [
      app: :transcriptor_bot,
      version: "0.1.0",
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {TranscriptorBot.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:ex_gram, "~> 0.71"},
      {:req, "~> 0.5"},
      {:jason, "~> 1.4"},
      {:exqlite, "~> 0.43"},
      {:plug, "~> 1.16", only: :test}
    ]
  end
end
