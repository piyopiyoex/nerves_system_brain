import Config

Application.start(:nerves_bootstrap)

# Keep application-owned firmware files with the application, as generated
# Nerves projects do. The System overlay remains responsible for PW-SH6 setup.
config :nerves, :firmware, rootfs_overlay: "rootfs_overlay"

if Mix.target() == :host do
  import_config "host.exs"
else
  import_config "target.exs"
end
