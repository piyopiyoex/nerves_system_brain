defmodule NervesToolchainBrain do
  @moduledoc false

  use Nerves.Package.Platform

  alias Nerves.Artifact

  @impl Nerves.Package.Platform
  def bootstrap(_package), do: :ok

  @impl Nerves.Package.Platform
  def build_path_link(package) do
    reusable_toolchain_path(package) || "Use the Buildroot/Bootlin toolchain artifact"
  end

  @impl Nerves.Artifact.BuildRunner
  def build(package, _toolchain, _options) do
    case reusable_toolchain_path(package) do
      nil ->
        {:error,
         "Build nerves_system_brain first, or publish a Brain toolchain artifact before compiling without o/host"}

      path ->
        {:ok, path}
    end
  end

  @impl Nerves.Artifact.BuildRunner
  def archive(package, _toolchain, options) do
    case reusable_toolchain_path(package) do
      nil ->
        {:error, "Build nerves_system_brain before packaging the Brain toolchain artifact"}

      toolchain_path ->
        archive_reusable_toolchain(package, toolchain_path, options)
    end
  end

  @impl Nerves.Artifact.BuildRunner
  def clean(package) do
    _ = Artifact.Cache.delete(package)
    :ok
  end

  defp archive_reusable_toolchain(package, toolchain_path, options) do
    name = Keyword.get(options, :name, Artifact.download_name(package) <> Artifact.ext(package))
    archive_path = options |> Keyword.get(:path, File.cwd!()) |> Path.expand() |> Path.join(name)
    source_name = Path.basename(toolchain_path)
    archive_root = Atom.to_string(package.app)

    transform =
      "s,^#{source_name},#{archive_root},;" <>
        "s,^VERSION$,#{archive_root}/nerves-toolchain.tag,"

    File.mkdir_p!(Path.dirname(archive_path))

    case System.cmd(
           "tar",
           [
             "--create",
             "--xz",
             "--file",
             archive_path,
             "--transform",
             transform,
             "--directory",
             Path.dirname(toolchain_path),
             source_name,
             "--directory",
             Path.expand(package.path),
             "VERSION"
           ],
           stderr_to_stdout: true
         ) do
      {_output, 0} -> {:ok, archive_path}
      {output, _status} -> {:error, output}
    end
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp reusable_toolchain_path(package) do
    build_dir = System.get_env("NERVES_SYSTEM_BRAIN_BUILD_DIR", "../o")
    path = Path.expand(Path.join(build_dir, "host"), package.path)

    if File.dir?(Path.join(path, "bin")) do
      path
    end
  end
end
