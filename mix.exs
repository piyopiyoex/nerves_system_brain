defmodule NervesSystemBrain.MixProject do
  use Mix.Project

  @github_repository "piyopiyoex/nerves_system_brain"
  @app :nerves_system_brain
  @source_url "https://github.com/#{@github_repository}"
  @version Path.join(__DIR__, "VERSION")
           |> File.read!()
           |> String.trim()

  def project do
    [
      app: @app,
      version: @version,
      elixir: "~> 1.18",
      archives: [nerves_bootstrap: "~> 1.15"],
      compilers: Mix.compilers() ++ [:nerves_package],
      build_embedded: Mix.env() == :prod,
      start_permanent: Mix.env() == :prod,
      description: "Experimental Nerves system for SHARP Brain PW-SH6",
      package: package(),
      nerves_package: nerves_package(),
      deps: deps(),
      aliases: [
        loadconfig: [&bootstrap/1]
      ]
    ]
  end

  def application do
    []
  end

  defp deps do
    [
      {:nerves, "~> 1.13", runtime: false},
      {:nerves_system_br, "1.34.3", runtime: false},
      {:nerves_toolchain_brain, path: "toolchain", runtime: false},
      {:nerves_system_linter, "~> 0.4", only: [:dev, :test], runtime: false}
    ]
  end

  defp bootstrap(args) do
    set_target()
    Application.ensure_all_started(:nerves_bootstrap)
    Mix.Task.run("loadconfig", args)
  end

  defp set_target do
    if function_exported?(Mix, :target, 1) do
      apply(Mix, :target, [:brain])
    else
      System.put_env("MIX_TARGET", "brain")
    end
  end

  defp nerves_package do
    [
      type: :system,
      artifact_sites: [
        {:github_releases, @github_repository}
      ],
      platform: NervesSystemBrain.Platform,
      platform_config: [
        defconfig: "nerves_defconfig"
      ],
      env: [
        {"TARGET_ARCH", "arm"},
        {"TARGET_CPU", "arm926ej_s"},
        {"TARGET_OS", "linux"},
        {"TARGET_ABI", "gnueabi"},
        {"TARGET_GCC_FLAGS", "-marm -mcpu=arm926ej-s -mfloat-abi=soft"}
      ],
      checksum: package_files()
    ]
  end

  defp package do
    [
      files: package_files(),
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => @source_url}
    ]
  end

  defp package_files do
    [
      "docs",
      "boot",
      "lib",
      "rootfs_overlay",
      "sd",
      "scripts",
      "toolchain",
      "busybox.fragment",
      "Config.in",
      "fwup.conf",
      "mix.exs",
      "nerves_defconfig",
      "README.md",
      "REUSE.toml",
      "VERSION"
    ]
  end
end
