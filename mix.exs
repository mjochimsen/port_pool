defmodule PortPool.Mixfile do
  use Mix.Project

  def project do
    [
      app: :port_pool,
      version: "0.0.1",
      elixir: "~> 1.1",
      build_embedded: Mix.env == :prod,
      start_permanent: Mix.env == :prod,
      deps: deps
    ]
  end

  # Configuration for the OTP application
  #
  # Type "mix help compile.app" for more information
  def application do
    [applications: []]
  end

  # Dependencies of the application
  #
  # Type "mix help deps" for examples and options
  defp deps do
    []
  end
end
