# 2026-09-22 USB NCM real-device verification

## Goal

Verify the normalized USB development path on a real SHARP Brain PW-SH6 after
moving networking policy to NervesPack / VintageNet:

```text
PW-SH6 peripheral DTB
  -> erlinit hardware preparation
  -> configfs NCM gadget
  -> VintageNetDirect
  -> mDNS
  -> NervesSSH / IEx
```

The firmware was built through the normal application flow and written to a
blank microSD with `mix burn`. Because the `complete` task installs the host-mode
DTB, `sd/use_usb_ncm.sh` was run after the burn to replace p1
`imx28-pwsh6.dtb` with the peripheral variant.

## Finding 1: erlinit keeps one pre-run command

The first peripheral boot reached Nerves and rendered the KIOSK, but the Linux
host did not enumerate an NCM device. The expected gadget diagnostic file was
also absent from p2.

Inspection of the generated and burned `erlinit.config` showed that repeated
`--pre-run-exec` entries did not preserve all three PW-SH6 helpers. `erlinit`
v1.15.1 represents `pre_run_exec` as a single string, so later occurrences
replace earlier ones.

The System now uses one entry:

```text
--pre-run-exec /usr/bin/prepare_brain_hardware
```

`prepare_brain_hardware` keeps the individual responsibilities separate and
invokes them in order:

```text
restore_brain_rtc
enable_ethernet_gadget
enable_bt_speaker
```

This keeps hardware preparation below the networking policy boundary while
matching erlinit's actual option semantics.

## Finding 2: the gadget helper requires BusyBox tr

After the single pre-run helper was in place, `/root/gadget_diag.log` proved
that `enable_ethernet_gadget` was finally being executed, but it stopped while
reading the Device Tree property:

```text
/usr/bin/enable_ethernet_gadget: line 15: tr: not found
dr_mode=
skip: USB0 is not peripheral
```

The helper uses `tr -d '\000'` because Device Tree string properties are NUL
terminated. The System's BusyBox configuration did not include `tr`.

`busybox.fragment` therefore explicitly enables both applets used by the gadget
setup:

```text
CONFIG_LN=y
CONFIG_TR=y
```

The Buildroot output must be regenerated after changing the fragment. During
this verification, a stale `o/.config` still referenced the removed
`post-build-wifi.sh`; rerunning `create-build.sh nerves_defconfig o` resynced the
Buildroot configuration before the successful rebuild.

The final rootfs was checked before burning:

```text
o/target/usr/bin/tr -> ../../bin/busybox
./usr/bin/tr -> ../../bin/busybox   # in o/images/rootfs.tar
```

## Real-device result

After rebuilding and burning the firmware, then selecting the peripheral DTB,
the Linux development PC enumerated the PW-SH6 as CDC NCM:

```text
Product: Brain (Nerves)
Manufacturer: SHARP
cdc_ncm ... MAC-Address: 8a:15:8b:44:3a:01
cdc_ncm ... enx8a158b443a01: renamed from usb0
```

The host received a peer address automatically. In this boot:

```text
PW-SH6 usb0: 172.31.172.181/30
Linux host:   172.31.172.182/30
```

These addresses are an observed example, not a fixed configuration contract.
`VintageNetDirect` owns the /30 selection and DHCP behavior.

mDNS and SSH then worked without manual host-side IP configuration:

```text
ping nerves.local
ssh user@nerves.local
```

`ssh user@nerves.local` opened the standard Nerves IEx session. On the target,
`VintageNet.info()` reported:

```text
Interface usb0
  Type: VintageNetDirect
  Present: true
  State: :configured
  Connection: :lan
  Addresses: ... 172.31.172.181/30
```

The expected applications were also running:

```elixir
[:nerves_pack, :mdns_lite, :vintage_net, :nerves_ssh]
```

`ifconfig()` showed `usb0` as up/running with the configured IPv4 and IPv6
link-local addresses.

## Remaining boundaries

- `mix upload` / OTA firmware update is still unsupported. The current writable
  single-root ext4 layout has no safe inactive slot, and the `upgrade` task is
  intentionally disabled.
- `mix burn` restores the host-mode DTB in p1. Run `sd/use_usb_ncm.sh` after each
  burn when the development path should use USB NCM.
- `Nerves.Runtime.KV.get_all()` currently returns `%{}`, so the Nerves MOTD shows
  `unknown 0.0.0 - unknown` / `Platform: unknown`. This is a separate System
  metadata normalization issue and did not affect boot, networking, or SSH.
- `/root/gadget_diag.log` is bring-up instrumentation. It is useful while the
  USB role path is still being stabilized, but it can be reduced or removed
  independently after the failure path is considered sufficiently observable.
