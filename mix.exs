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
        {:loadconfig, [&bootstrap/1]},
        {:"brain.system.build", &brain_system_build/1}
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

  defp brain_system_build(args) do
    {opts, positional, invalid} =
      OptionParser.parse(args,
        strict: [clean: :boolean, help: :boolean],
        aliases: [c: :clean, h: :help]
      )

    if opts[:help] do
      Mix.shell().info("""
      Build the local PW-SH6 Nerves System through the pinned nerves_system_br dependency.

          mix brain.system.build
          mix brain.system.build --clean

      On a fresh checkout, run `mix deps.get` once before this command.
      """)
    else
      if positional != [] or invalid != [] do
        Mix.raise("Usage: mix brain.system.build [--clean]")
      end

      build_dir = brain_system_build_dir()

      if opts[:clean] do
        clean_brain_system_build_dir!(build_dir)
      end

      system_br_path = Path.join(Mix.Project.deps_path(), "nerves_system_br")
      create_build = Path.join(system_br_path, "create-build.sh")
      defconfig = Path.join(__DIR__, "nerves_defconfig")

      unless File.regular?(create_build) do
        Mix.raise("nerves_system_br is unavailable; run mix deps.get and retry")
      end

      Mix.shell().info("==> Configuring PW-SH6 System in #{display_brain_system_path(build_dir)}")
      run_brain_system_command!("bash", [create_build, defconfig, build_dir])

      Mix.shell().info("==> Building PW-SH6 System")
      run_brain_system_command!("make", ["-C", build_dir])
      validate_brain_system_build!(build_dir)

      Mix.shell().info(
        "==> PW-SH6 System build complete: #{display_brain_system_path(build_dir)}"
      )
    end
  end

  defp brain_system_build_dir do
    case System.get_env("NERVES_SYSTEM_BRAIN_BUILD_DIR") do
      nil -> Path.join(__DIR__, "o")
      "" -> Path.join(__DIR__, "o")
      path -> Path.expand(path, __DIR__)
    end
  end

  defp clean_brain_system_build_dir!(build_dir) do
    if build_dir in [__DIR__, "/"] do
      Mix.raise("refusing to remove unsafe build directory: #{build_dir}")
    end

    Mix.shell().info("==> Removing #{display_brain_system_path(build_dir)}")
    File.rm_rf!(build_dir)
  end

  defp validate_brain_system_build!(build_dir) do
    missing =
      ["host", "staging", "images"]
      |> Enum.reject(&File.dir?(Path.join(build_dir, &1)))

    if missing != [] do
      Mix.raise("System build is missing expected output: #{Enum.join(missing, ", ")}")
    end
  end

  defp run_brain_system_command!(command, args) do
    {_output, status} =
      System.cmd(command, args,
        cd: __DIR__,
        env: [{"LD_LIBRARY_PATH", nil}],
        into: IO.stream(:stdio, :line),
        stderr_to_stdout: true
      )

    if status != 0 do
      Mix.raise("command failed with status #{status}: #{command} #{Enum.join(args, " ")}")
    end
  end

  defp display_brain_system_path(path), do: Path.relative_to(path, __DIR__)

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
