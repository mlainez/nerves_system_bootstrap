defmodule NervesSystemBootstrap.MixProject do
  use Mix.Project

  def project do
    [
      app: :nerves_system_bootstrap,
      version: "0.1.0",
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:nerves_system_br, "~> 1.20", runtime: false},
      {:req, "~> 0.5.0"},
      {:jason, "~> 1.4"}
    ]
  end
end
