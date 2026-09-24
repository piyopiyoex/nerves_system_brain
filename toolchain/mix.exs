defmodule NervesToolchainBrain.MixProject do
  use Mix.Project

  @app :nerves_toolchain_brain
  @version Path.join(__DIR__, "VERSION")
           |> File.read!()
           |> String.trim()
  @source_url "https://github.com/piyopiyoex/nerves_system_brain"

  def project do
    [
      app: @app,
      version: @version,
      elixir: "~> 1.18",
      description: "Nerves toolchain adapter for SHARP Brain PW-SH6",
      source_url: @source_url,
      package: package(),
      compilers: compilers(Mix.env()),
      nerves_package: nerves_package(),
      deps: deps()
    ]
  end

  def application, do: []

  defp compilers(:prod), do: Mix.compilers() ++ [:nerves_package]
  defp compilers(_environment), do: Mix.compilers()

  defp nerves_package do
    [
      type: :toolchain,
      platform: NervesToolchainBrain,
      target_tuple: :armv5_nerves_linux_gnueabi,
      artifact_sites: [
        {:github_releases, "piyopiyoex/nerves_system_brain"}
      ],
      checksum: checksum_files()
    ]
  end

  defp deps do
    [
      {:nerves, "~> 1.13", runtime: false}
    ]
  end

  defp package do
    [
      files: ["lib", "UPSTREAM", "VERSION", "defconfig", "mix.exs"],
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => @source_url}
    ]
  end

  defp checksum_files do
    [
      "UPSTREAM",
      "defconfig"
    ]
  end
end
