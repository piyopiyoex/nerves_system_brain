defmodule HelloKioskBrain.MixProject do
  use Mix.Project

  @app :hello_kiosk_brain
  @version "0.1.0"
  @all_targets [:brain]

  def project do
    [
      app: @app,
      version: @version,
      elixir: "~> 1.18",
      archives: [nerves_bootstrap: "~> 1.15"],
      compilers: Mix.compilers() ++ [:elixir_make],
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      releases: [{@app, release()}]
    ]
  end

  def application do
    [
      extra_applications: [:logger, :runtime_tools],
      mod: {HelloKioskBrain.Application, []}
    ]
  end

  def cli do
    [preferred_targets: [run: :host, test: :host]]
  end

  defp deps do
    [
      {:nerves, "~> 1.13", runtime: false},
      {:elixir_make, "~> 0.9", runtime: false},
      {:lovyangfx_elixir,
       github: "piyopiyoex/lovyangfx_elixir", ref: "5af95d748d80a8f1ace84b14a97ca7c484d93bbc"},
      {:shoehorn, "~> 0.9.0"},
      {:ring_logger, "~> 0.11"},
      {:toolshed, "~> 0.5"},
      {:nerves_runtime, "~> 0.13.9"},
      {:nerves_pack, "~> 0.7", targets: @all_targets}
    ] ++ system(Mix.target())
  end

  defp system(:host), do: []

  defp system(:brain) do
    [
      {:nerves_system_brain,
       path: "../..", runtime: false, targets: :brain, nerves: [compile: true]}
    ]
  end

  defp system(target), do: raise("unsupported MIX_TARGET: #{inspect(target)}")

  defp aliases do
    [
      setup: ["deps.get"]
    ]
  end

  defp release do
    if Mix.target() in @all_targets do
      [
        overwrite: true,
        cookie: "#{@app}_cookie",
        include_erts: &Nerves.Release.erts/0,
        steps: [&Nerves.Release.init/1, :assemble],
        strip_beams: true
      ]
    else
      [
        include_erts: false,
        strip_beams: true,
        quiet: true
      ]
    end
  end
end
