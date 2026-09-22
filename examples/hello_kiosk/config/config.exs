import Config

Application.start(:nerves_bootstrap)

# Keep application-owned firmware files with the application, as generated
# Nerves projects do. The System overlay remains responsible for PW-SH6 setup.
config :nerves, :firmware, rootfs_overlay: "rootfs_overlay"

config :nerves_motd,
  logo: [
    IO.ANSI.color(74),
    File.read!(Path.expand("logo.txt", __DIR__)),
    IO.ANSI.reset()
  ]

if Mix.target() == :host do
  import_config "host.exs"
else
  import_config "target.exs"
end
