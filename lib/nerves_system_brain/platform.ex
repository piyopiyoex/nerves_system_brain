defmodule NervesSystemBrain.Platform do
  @moduledoc false

  @behaviour Nerves.Artifact.BuildRunner
  @behaviour Nerves.Package.Platform

  alias Nerves.Artifact

  @impl Nerves.Package.Platform
  def bootstrap(package) do
    Nerves.System.BR.bootstrap(package)
  end

  @impl Nerves.Package.Platform
  def build_path_link(package) do
    if reusable_system?(reusable_build_path(package)) do
      prepared_artifact_path(package)
    else
      Nerves.System.BR.build_path_link(package)
    end
  end

  @impl Nerves.Artifact.BuildRunner
  def build(package, toolchain, opts) do
    reusable_build = reusable_build_path(package)

    if reusable_system?(reusable_build) do
      {:ok, materialize_reusable_artifact(package, reusable_build)}
    else
      Nerves.System.BR.build(package, toolchain, opts)
    end
  end

  @impl Nerves.Artifact.BuildRunner
  def archive(package, toolchain, opts) do
    reusable_build = reusable_build_path(package)

    if reusable_system?(reusable_build) do
      archive_reusable_system(package, reusable_build, opts)
    else
      Nerves.System.BR.archive(package, toolchain, opts)
    end
  end

  @impl Nerves.Artifact.BuildRunner
  def clean(package) do
    if reusable_system?(reusable_build_path(package)) do
      _ = Nerves.Artifact.Cache.delete(package)
      _ = File.rm_rf(prepared_artifact_path(package))
      :ok
    else
      Nerves.System.BR.clean(package)
    end
  end

  defp reusable_build_path(package) do
    build_dir = System.get_env("NERVES_SYSTEM_BRAIN_BUILD_DIR", "o")
    Path.expand(build_dir, package.path)
  end

  defp reusable_system?(path) do
    File.dir?(Path.join(path, "host")) and
      File.dir?(Path.join(path, "staging")) and
      File.dir?(Path.join(path, "images"))
  end

  defp prepared_artifact_path(package) do
    Path.join(package.path, ".nerves/reusable-system-artifact")
  end

  defp materialize_reusable_artifact(package, reusable_build) do
    dest = prepared_artifact_path(package)
    system_br_path = nerves_system_br_path(package)

    _ = File.rm_rf!(dest)
    File.mkdir_p!(dest)

    link!(Path.join(reusable_build, "host"), Path.join(dest, "host"))
    link!(Path.join(reusable_build, "staging"), Path.join(dest, "staging"))
    materialize_images!(package, reusable_build, dest)

    for file <- ["nerves-env.sh", "nerves_env.exs", "nerves-env.cmake", "nerves.mk"],
        source = Path.join(system_br_path, file),
        File.exists?(source) do
      File.cp!(source, Path.join(dest, file))
    end

    File.cp_r!(Path.join(system_br_path, "scripts"), Path.join(dest, "scripts"))

    local_scripts = Path.join(package.path, "scripts")

    if File.dir?(local_scripts) do
      File.cp_r!(local_scripts, Path.join(dest, "scripts"))
    end

    local_rootfs_overlay = Path.join(package.path, "rootfs_overlay")

    if File.dir?(local_rootfs_overlay) do
      File.cp_r!(local_rootfs_overlay, Path.join(dest, "rootfs_overlay"))
    end

    copy_optional_tree!(Path.join(package.path, "boot"), dest)

    File.write!(Path.join(dest, "nerves-system.tag"), package.version)

    dest
  end

  defp archive_reusable_system(package, reusable_build, opts) do
    name = Keyword.get(opts, :name, Artifact.download_name(package) <> Artifact.ext(package))
    artifact_name = String.replace_suffix(name, Artifact.ext(package), "")
    archive_path = opts |> Keyword.get(:path, File.cwd!()) |> Path.expand() |> Path.join(name)
    work_dir = Path.join(package.path, ".nerves/archive")
    archive_root = Path.join(work_dir, artifact_name)

    try do
      File.rm_rf!(work_dir)
      File.mkdir_p!(archive_root)
      File.mkdir_p!(Path.dirname(archive_path))

      system_br_path = nerves_system_br_path(package)

      copy_files!(system_br_path, archive_root, [
        "nerves-env.sh",
        "nerves_env.exs",
        "nerves-env.cmake",
        "nerves.mk"
      ])

      copy_tree!(Path.join(system_br_path, "scripts"), Path.join(archive_root, "scripts"))
      copy_tree_following_root_link!(Path.join(reusable_build, "staging"), archive_root)
      copy_tree!(Path.join(reusable_build, "images"), Path.join(archive_root, "images"))

      copy_optional_tree!(Path.join(reusable_build, "legal-info"), archive_root)
      copy_optional_file!(Path.join(reusable_build, ".config"), archive_root)
      overlay_brain_files!(package, archive_root)

      File.write!(Path.join(archive_root, "nerves-system.tag"), package.version <> "\n")

      File.write!(
        Path.join(archive_root, "README.md"),
        "# Nerves system artifact\n\nGenerated from the reusable PW-SH6 Buildroot output.\n"
      )

      case System.cmd(
             "tar",
             [
               "--create",
               "--gzip",
               "--file",
               archive_path,
               "--directory",
               work_dir,
               artifact_name
             ],
             stderr_to_stdout: true
           ) do
        {_output, 0} -> {:ok, archive_path}
        {output, _status} -> {:error, output}
      end
    rescue
      error -> {:error, Exception.message(error)}
    after
      File.rm_rf(work_dir)
    end
  end

  defp overlay_brain_files!(package, archive_root) do
    local_scripts = Path.join(package.path, "scripts")

    if File.dir?(local_scripts) do
      local_scripts
      |> File.ls!()
      |> Enum.each(fn entry ->
        source = Path.join(local_scripts, entry)
        destination = Path.join([archive_root, "scripts", entry])
        File.rm_rf!(destination)
        copy_tree_or_file!(source, destination)
      end)
    end

    copy_optional_tree!(Path.join(package.path, "rootfs_overlay"), archive_root)
    copy_optional_tree!(Path.join(package.path, "boot"), archive_root)

    fwup_conf = Path.join(package.path, "fwup.conf")

    if File.regular?(fwup_conf) do
      File.cp!(fwup_conf, Path.join([archive_root, "images", "fwup.conf"]))
    end
  end

  defp copy_files!(source_dir, destination_dir, files) do
    Enum.each(files, fn file ->
      source = Path.join(source_dir, file)

      if File.regular?(source) do
        File.cp!(source, Path.join(destination_dir, file))
      end
    end)
  end

  defp copy_optional_file!(source, destination_dir) do
    if File.regular?(source) do
      File.cp!(source, Path.join(destination_dir, Path.basename(source)))
    end
  end

  defp copy_optional_tree!(source, destination_dir) do
    if File.dir?(source) do
      copy_tree!(source, Path.join(destination_dir, Path.basename(source)))
    end
  end

  defp copy_tree_or_file!(source, destination) do
    if File.dir?(source) do
      copy_tree!(source, destination)
    else
      File.cp!(source, destination)
    end
  end

  defp copy_tree!(source, destination) do
    File.rm_rf!(destination)

    case System.cmd("cp", ["-R", "--preserve=mode,timestamps,links", source, destination],
           stderr_to_stdout: true
         ) do
      {_output, 0} -> :ok
      {output, _status} -> raise "failed to copy #{source}: #{output}"
    end
  end

  # o/staging is a link to the toolchain sysroot. Follow that one link while
  # retaining links inside the sysroot, matching nerves_system_br/mksystem.sh.
  defp copy_tree_following_root_link!(source, destination_dir) do
    case System.cmd("cp", ["-HR", "--preserve=mode,timestamps,links", source, destination_dir],
           stderr_to_stdout: true
         ) do
      {_output, 0} -> :ok
      {output, _status} -> raise "failed to copy #{source}: #{output}"
    end
  end

  defp materialize_images!(package, reusable_build, dest) do
    source_images = Path.join(reusable_build, "images")
    dest_images = Path.join(dest, "images")

    File.mkdir_p!(dest_images)

    source_images
    |> File.ls!()
    |> Enum.each(fn entry ->
      link!(Path.join(source_images, entry), Path.join(dest_images, entry))
    end)

    fwup_conf = Path.join(package.path, "fwup.conf")

    if File.exists?(fwup_conf) do
      File.rm(Path.join(dest_images, "fwup.conf"))
      File.cp!(fwup_conf, Path.join(dest_images, "fwup.conf"))
    end
  end

  defp link!(source, dest) do
    File.rm(dest)
    File.ln_s!(Path.expand(source), dest)
  end

  defp nerves_system_br_path(package) do
    case Nerves.Env.package(:nerves_system_br) do
      %{path: path} -> path
      _ -> Path.expand("../nerves_system_br", package.path)
    end
  end
end
