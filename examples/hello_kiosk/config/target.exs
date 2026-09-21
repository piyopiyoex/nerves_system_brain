import Config

# Follow the normal Nerves application composition: infrastructure starts
# before the kiosk so SSH/network access survives application failures.
config :logger, backends: [RingLogger]

config :shoehorn,
  init: [:nerves_runtime, :nerves_pack]

# Use the developer's public keys when available. Keep the lightweight password
# callback as a PW-SH6-specific fallback until NervesSSH startup cost is measured
# on the ARMv5 device.
keys =
  System.user_home!()
  |> Path.join(".ssh/id_{rsa,ecdsa,ed25519}.pub")
  |> Path.wildcard()

config :nerves_ssh,
  authorized_keys: Enum.map(keys, &File.read!/1),
  iex_opts: [dot_iex: "/etc/iex.exs"],
  daemon_option_overrides: [
    pwdfun: {HelloKioskBrain.SshAuth, :check_password, 2}
  ]

# Device Tree decides whether USB0 is host or peripheral. The System only creates
# the NCM gadget in peripheral mode; VintageNet owns addressing and DHCP.
# Missing interfaces are fine: VintageNet activates them when the kernel exposes
# them (usb0 for NCM, eth0 for a USB Ethernet adapter, wlan0 for USB WiFi).
config :vintage_net,
  regulatory_domain: "JP",
  config: [
    {"usb0", %{type: VintageNetDirect}},
    {"eth0",
     %{
       type: VintageNetEthernet,
       ipv4: %{method: :dhcp}
     }},
    {"wlan0", %{type: VintageNetWiFi}}
  ]

config :mdns_lite,
  hosts: [:hostname, "nerves"],
  ttl: 120,
  services: [
    %{protocol: "ssh", transport: "tcp", port: 22},
    %{protocol: "sftp-ssh", transport: "tcp", port: 22},
    %{protocol: "epmd", transport: "tcp", port: 4369}
  ]

config :hello_kiosk_brain,
  target: :brain,
  boot_trace: true,
  kiosk_start_delay_ms: 3_000
