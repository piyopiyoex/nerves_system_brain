# 2026-09-20 Nerves standard flow investigation

## Goal

Investigate whether `nerves_system_brain` can move from the current
standalone-like `nerves_system_br` workflow toward a normal Nerves System
dependency while preserving the PW-SH6 boot/storage path that already works.

The immediate PoC target is:

```sh
export MIX_TARGET=brain
mix deps.get
mix compile
```

`mix firmware` and `mix firmware.burn` are treated as follow-up work unless a
minimal `fwup.conf` is enough without changing the storage model.

## Compared Repositories

### `nerves_system_atomcam2`

Reusable:

- Root `mix.exs` declares `type: :system`.
- `Nerves.System.BR` remains the Buildroot platform.
- A target-specific app dependency selects the system with `targets: :atomcam2`.
- Development can switch between a released system and a local path dependency.
- Application releases use `include_erts: &Nerves.Release.erts/0`.
- Toolchain concerns are represented as a Nerves `type: :toolchain` package.

Needs adjustment for Brain:

- AtomCam2 uses a published custom toolchain artifact. Brain currently uses the
  Bootlin toolchain produced inside the Buildroot output under `o/host`.
- AtomCam2's `fwup.conf` models an A/B application slot layout. Brain must keep
  the existing p1 FAT + p2 ext4 layout during the first migration stage.
- AtomCam2 uses squashfs for the application rootfs. Brain currently requires
  ext4 because the validated brain-hackers kernel does not provide squashfs.

### Upstream-style system (`nerves_system_rpi3`)

Reusable:

- `type: :system`, `platform: Nerves.System.BR`, and `platform_config:
  [defconfig: "nerves_defconfig"]`.
- `env` entries for `TARGET_ARCH`, `TARGET_CPU`, `TARGET_OS`, `TARGET_ABI`, and
  `TARGET_GCC_FLAGS`.
- Keeping boot and rootfs customization in the system package rather than in the
  application.

Needs adjustment for Brain:

- Upstream systems expect a complete firmware image and `fwup` layout. Brain can
  expose a system dependency before adopting a full firmware/update model.
- Upstream ARM systems assume newer ARM cores and hard-float toolchains. Brain is
  ARM926EJ-S / ARMv5TEJ / soft-float.

### `circuits_quickstart`

Reusable:

- Application `mix.exs` has `@all_targets` and target-specific system deps.
- `config/config.exs` starts `:nerves_bootstrap`.
- Target release uses `include_erts: &Nerves.Release.erts/0` and
  `steps: [&Nerves.Release.init/1, :assemble]`.
- `cli/0` keeps `run` and `test` on host by default.

Needs adjustment for Brain:

- `hello_kiosk` currently has a validated ERTS-less deployment to `/srv/erlang`.
  A standard Nerves release should be added without immediately deleting that
  path.
- Native code must be built through the Nerves environment. The existing
  Makefile already accepts `CC`, `CXX`, and `ERTS_INCLUDE_DIR`, so it is a good
  fit for `elixir_make`.

## PoC Changes

- Added a root `mix.exs` that declares `nerves_system_brain` as a Nerves
  `type: :system` package.
- Added `NervesSystemBrain.Platform`, a small wrapper around `Nerves.System.BR`.
  It reuses an existing `o/` Buildroot output when present and falls back to the
  normal Buildroot artifact build otherwise.
- Added a minimal `toolchain/` package named `nerves_toolchain_brain`. For local
  development it reuses `o/host`; publishing it as an independent artifact is a
  follow-up.
- Updated `examples/hello_kiosk` toward a target-aware Nerves application shape:
  target list, local system dependency, `elixir_make`, `Nerves.Release.erts/0`,
  and `config/config.exs`.
- Adjusted the native Makefile to preserve Nerves-provided `CPPFLAGS` so the
  sysroot and target flags survive the `elixir_make` path.

## Findings

### Host-side PoC verification

The following commands were verified from `examples/hello_kiosk/` using the
project's `mise` toolchain wrapper because plain `mix` was not on the shell
`PATH`:

```sh
MIX_TARGET=brain mise exec -- mix deps.get
MIX_TARGET=brain mise exec -- mix compile
MIX_ENV=prod MIX_TARGET=brain mise exec -- mix release --overwrite
MIX_ENV=prod MIX_TARGET=brain mise exec -- mix firmware
```

Results:

- `mix deps.get` resolves the target app with `nerves_system_brain` as a normal
  target-specific system dependency.
- `mix compile` recognizes `MIX_TARGET=brain`, compiles the Elixir application,
  and drives `elixir_make` through the Nerves environment.
- The generated native artifacts are target ARM EABI5 binaries:
  `priv/kiosk_nif.so` is an ARM shared object and `priv/bin/devmem` is an ARM
  executable.
- `mix release` assembles a Brain target release with `erts-17.0.5` and
  `shoehorn.boot` under `_build/brain_prod/rel/hello_kiosk_brain/`.
- `mix firmware` builds
  `_build/brain_prod/nerves/images/hello_kiosk_brain.fw` through a
  Brain-specific ext4 `rel2fw.sh` path.
- Expanding the `.fw` with `fwup -a -t complete` produces a raw image with the
  current p1/p2 partition geometry. Extracting p2 confirms an ext4 rootfs with
  `/srv/erlang/releases/0.1.0` and the generated `/etc/erlinit.config` present
  with root ownership.

### SD-card write verification

On 2026-09-21, the generated `.fw` was written to a prepared SD card that
already contained the known-good brain-hackers boot files on p1:

```sh
sudo o/host/bin/fwup -a -d /dev/sda -t complete \
  -i examples/hello_kiosk/_build/brain_prod/nerves/images/hello_kiosk_brain.fw
sync
```

`fwup` completed successfully:

```text
100% [====================================] 17.11 MB in / 268.44 MB out
Success!
```

After the write, `lsblk` reported the expected PoC partition shape:

| Partition | Size | Filesystem | Label |
| --- | ---: | --- | --- |
| `/dev/sda1` | 64M | vfat | `boot` |
| `/dev/sda2` | 256M | ext4 | `rootfs` |

The `.fw` artifact used for the SD write was re-expanded locally after the card
write. Extracting p2 from that raw image confirmed the release tree:

- `/srv/erlang/erts-17.0.5`
- `/srv/erlang/lib`
- `/srv/erlang/releases/0.1.0/vm.args`
- `/srv/erlang/releases/0.1.0/shoehorn.boot`
- `/srv/erlang/releases/0.1.0/start.boot`
- `/srv/erlang/releases/0.1.0/sys.config`

The direct SD-card `debugfs` check showed the generated `/etc/erlinit.config`.
The release-directory listing from the live block device was inconclusive in the
captured terminal output, so the remaining proof point is a PW-SH6 boot test
with serial/console logs.

### First PW-SH6 boot result

The first SD-card boot reached the expected platform layers:

- kernel mounted `/dev/mmcblk1p2` as ext4 rootfs
- `/sbin/init` started `erlinit` 1.15.1
- `erlinit` found the release path and launched Erlang

The Erlang VM then terminated before the application started:

```text
{bad_heart_flag,false}
{heart_check_start_timeout,...}
...
erlinit: Erlang VM exited
```

Root cause: the first PoC `rel/vm.args.eex` included `-heart false`. In Erlang,
`-heart` is a flag that enables heart; `false` is not a valid way to disable it.
The fix is to omit the `-heart` flag entirely during Brain bring-up.

The firmware was rebuilt after removing that flag:

```text
Firmware UUID: offer-chalk (932a3365-d91b-5e35-eaeb-9b14bb004a22)
```

The rebuilt `.fw` was expanded locally and p2 was inspected with `debugfs`; the
embedded `/srv/erlang/releases/0.1.0/vm.args` no longer contains any `-heart`
entry.

### Post-rebase firmware overlay fix

After rebasing onto `origin/main` with PR #41/#42, firmware generation was
rechecked against the updated USB HOST/NCM scripts. This exposed a packaging
gap: the generated ext4 rootfs contained `/etc/erlinit.config`, but not
`/usr/bin/enable_net`, even though `erlinit.config` runs it via
`--pre-run-exec`.

Root cause: the reusable local System artifact did not materialize the System
package's `rootfs_overlay/`, and the Brain-specific `rel2fw.sh` only appended
application-generated overlays.

Fix:

- `NervesSystemBrain.Platform` now copies the package-level `rootfs_overlay/`
  into `.nerves/reusable-system-artifact`.
- `scripts/rel2fw.sh` appends `$NERVES_SYSTEM/rootfs_overlay` before app
  overlays, so System-owned boot/network scripts stay below the application
  boundary.

The rebased firmware was rebuilt successfully:

```text
Firmware UUID: ring-visa (b0eca2a7-2e4d-5df1-c3e8-397f556454a9)
```

Expanding that `.fw` and inspecting p2 confirmed:

- `/usr/bin/enable_net` is present with mode `0775`
- `/usr/bin/enable_ethernet_gadget` is present with mode `0775`
- `/srv/erlang/releases/0.1.0/vm.args` still omits `-heart`
- `/usr/bin/enable_net` contains the rebased PR #41/#42 USB role logic

The `ring-visa` firmware was then written to the prepared SD card:

```text
100% [====================================] 17.21 MB in / 268.44 MB out
Success!
```

Booting `ring-visa` progressed past the previous heart failure and printed the
Erlang/OTP 29 banner, but then appeared to hang on the device LCD. No USB NCM
interface appeared on the host, which is expected when the SD boot partition is
using the host-mode DTB from PR #41/#42.

For the next iteration, the app was instrumented with a minimal diagnostic
launcher:

- `HelloKioskBrain.BootTrace` prints `hello_kiosk:` markers to the console and
  appends them to `/root/hello_kiosk_boot.log`.
- `HelloKioskBrain.KioskLauncher` starts the heavy Kiosk display path after the
  main application supervision tree has come up, so a blocking display/NIF init
  no longer prevents the rest of the app from starting.

The diagnostic firmware was rebuilt successfully:

```text
Firmware UUID: earth-nut (48a0e2c9-346e-55f0-6337-aaf7a02d1dd8)
```

For the diagnostic boot, switch the SD boot partition to the peripheral DTB with
`sd/use_usb_ncm.sh` after writing the `.fw`, so the host can try USB NCM/SSH even
if the LCD remains at the console banner.

Booting `earth-nut` confirmed that the release started the application:

```text
hello_kiosk: application start
hello_kiosk: starting supervisor children
hello_kiosk: kiosk launcher init ...
erlinit: Erlang VM exited
```

The VM exited before the 3-second delayed Kiosk task marker, which pointed away
from the display/NIF path. Comparing `rel/vm.args.eex` with upstream
`circuits_quickstart` showed the missing release option: Elixir's CLI was
started with `-run elixir start_cli`, but `--no-halt` was not passed after
`-extra`. On this console, the CLI can finish initialization and allow the VM to
exit even though the application has just started.

The fix adds the standard Nerves-style keepalive flags:

- `+Bc`
- `-noshell`
- `-extra --no-halt`

The firmware was rebuilt successfully:

```text
Firmware UUID: skill-toe (c0e67534-715b-587d-a855-d481d89678b2)
```

Expanding that `.fw` confirmed `/srv/erlang/releases/0.1.0/vm.args` contains
`--no-halt`, while the diagnostic modules and System overlay are still present.

Booting `skill-toe` on the PW-SH6 succeeded. The device reached the Kiosk home
screen and showed:

- model: `PW-SH6`
- title: `Nerves on Brain`
- wired/NCM address: `10.42.0.2`
- display: `OK`
- touch: `OK`
- keyboard: `OK`
- network: `OK`
- runtime: `OTP 29 / Elixir 1.20.2`
- memory: `39 / 112 MB`
- battery: charging, `48%`

This proves the PoC path from a standard Nerves-style app release into the
existing PW-SH6 boot/rootfs stack:

```text
MIX_TARGET=brain mix firmware
  -> fwup complete task
  -> ext4 p2 rootfs
  -> erlinit
  -> Nerves release with ERTS
  -> hello_kiosk Brain UI
```

The host-side check from the sandbox did not see a USB NCM interface after the
successful boot, despite the device UI reporting `usb0 10.42.0.2`. Treat that as
a separate host/cable/USB-enumeration follow-up rather than a blocker for the
System dependency and firmware packaging PoC.

After rebooting the device and switching USB mode to HOST from the Kiosk
`切替` button, the PW-SH6 obtained `192.168.10.103` on the local network.
Host-side verification from the ThinkPad succeeded:

```text
PING 192.168.10.103: 3 packets transmitted, 3 received, 0% packet loss
```

SSH also succeeded with the on-device SSH daemon:

```text
Interactive Elixir (1.20.2)

SHARP Brain PW-SH6
hello_kiosk_brain 0.1.0
Elixir 1.20.2 / OTP 29

iex(hello_kiosk_brain@brain)1>
```

This confirms that the standard-release PoC supports remote IEx over the
existing application SSH path when the device is reachable through HOST-mode
networking. The typed `exit` expression raised a compile error in IEx, but the
project's `quit` helper cleanly closed the SSH session.

After the successful boot, `hello_kiosk` was reshaped one step closer to the
standard Nerves application layout:

- `config/config.exs` now starts `:nerves_bootstrap` and imports `host.exs` or
  `target.exs`, matching the `circuits_quickstart` and AtomCam2 example shape.
- Brain-specific firmware config (`config :nerves, :firmware`) lives in
  `config/target.exs`.
- `config :shoehorn` metadata is present in target config and the System
  `erlinit.config` boots `shoehorn.boot`, matching a normal Nerves application.
- `BootTrace` and the Kiosk launch delay are now controlled by application
  config so bring-up diagnostics can be disabled without code changes.
- `examples/hello_kiosk` can select its System dependency source with
  `BRAIN_SYSTEM_SOURCE`. The default is `local`, matching this branch's
  trial-and-error workflow. `github` / `release` are wired for future tagged
  system artifact testing, and `path` allows testing another checkout via
  `BRAIN_SYSTEM_PATH`.
- The System `erlinit.config` was moved to `--boot shoehorn`, matching upstream
  systems and AtomCam2. The resulting firmware was then verified on PW-SH6.

### `shoehorn.boot` verified on PW-SH6

The `zebra-hello` firmware (`fc70a5d0-7b40-5649-ae66-3565d1bfadb2`, SHA-256
`fddc6db63e92a9021561a0cf54759a15eb82f10d9e2289e0c12689ff25397342`) booted
on the reference PW-SH6. The KIOSK UI and HOST-mode network came up, and the
device answered at `192.168.10.103`.

An OTP SSH direct-exec query returned:

```elixir
%{
  boot: {:ok, [[~c"/srv/erlang/releases/0.1.0/shoehorn"]]},
  hello_kiosk: ~c"0.1.0",
  node: :hello_kiosk_brain@brain,
  otp_release: ~c"29",
  shoehorn: ~c"0.9.3",
  started: true,
  system_architecture: ~c"arm-buildroot-linux-gnueabi"
}
```

This verifies the actual VM boot argument, rather than inferring shoehorn use
from files in the firmware image. `--boot shoehorn` is therefore adopted as the
PoC default. The legacy normal-release fallback remains available through
erlinit when a release has no `shoehorn.boot` file.

### Repository-root OTP pin

Running the standard Nerves tasks directly from the System repository exposed
that the root inherited host OTP 28 while the reusable target System contains
OTP 29. Nerves rejected the environment because host and target OTP major
versions differed. The repository root now has the same `.tool-versions` pin as
`examples/hello_kiosk` (`erlang 29.0.5`, `elixir 1.20.2-otp-29`) and a root
`mix.lock`. This makes root-level System package and artifact operations use the
same BEAM format contract as the application and target.

### Portable System artifact generated and consumed

The first root-level `mix nerves.artifact` attempt exposed a second adapter
boundary: `archive/3` delegated to `Nerves.System.BR`, which expected a normal
Buildroot tree under `.nerves/artifacts/...`, while the reusable adapter had
materialized `.nerves/reusable-system-artifact` instead.

`NervesSystemBrain.Platform.archive/3` now follows the standard
`nerves_system_br` system archive shape:

- copy the real target sysroot into `staging/`, following only the top-level
  `o/staging` link and retaining links inside the sysroot;
- include `images/` and the common Nerves environment/scripts;
- overlay Brain's `rel2fw.sh`, `fwup.conf`, and `rootfs_overlay`;
- omit `o/host`, since a System artifact must not bundle its host toolchain.

The standard task produced:

```text
nerves_system_brain-portable-0.1.0-791B5D1.tar.gz  90 MiB
```

The archive was extracted under `/tmp`, outside this checkout. With
`NERVES_SYSTEM` set to that extracted directory, `hello_kiosk` completed both a
forced ARM target compile and `MIX_ENV=prod mix firmware`. The firmware build
explicitly copied the System overlay from the extracted artifact and produced
firmware nickname `emotion-nasty` (`548e7b25-b567-519e-2e41-a636838c2d1d`).

This proves the System artifact is portable. At this point the cached
`nerves_toolchain_brain` was still a link to this checkout's `o/host`, which
motivated the next experiment.

### Toolchain artifact generated and consumed

`NervesToolchainBrain.archive/3` now packages the complete reusable `o/host`
tree as a host-specific standard Nerves `.tar.xz`. Its archive root is
`nerves_toolchain_brain/`, symlinks are preserved, and `VERSION` is included as
`nerves-toolchain.tag` without modifying the Buildroot output.

The standard task produced:

```text
nerves_toolchain_brain-linux_x86_64-0.1.0-380F8C4.tar.xz  197 MiB
SHA-256 2a7a525b8302833d69d2dc8f48f9a88ff68e30fa28be203582334da2aaab358f
```

After extraction under `/tmp`, the relocated compiler reported:

```text
arm-linux-gcc.br_real (Buildroot 2021.11-18033-g83947c7bb6) 14.3.0
arm-buildroot-linux-gnueabi
```

The previously generated NIF and `devmem` outputs were removed before the
consumer test. With both `NERVES_SYSTEM` and `NERVES_TOOLCHAIN` pointing to
their extracted `/tmp` artifacts, the build log showed:

```text
/tmp/nerves-toolchain-brain-consumer/nerves_toolchain_brain/bin/arm-linux-g++
  --sysroot /tmp/nerves-system-brain-consumer/.../staging
  -I/tmp/nerves-system-brain-consumer/.../staging/usr/lib/erlang/erts-17.0.5/include
  -marm -mcpu=arm926ej-s -mfloat-abi=soft
```

The NIF and static helper rebuilt, and `mix firmware` produced `dynamic-labor`
(`4f7a7ade-89c9-560e-10aa-6b3921e7e649`). This verifies standard Nerves
cross-compilation without using the repository's `o/host` or `o/staging` paths.

Because `toolchain/` participates in the System package checksum, the final
System artifact name became
`nerves_system_brain-portable-0.1.0-E7EEC96.tar.gz` (SHA-256
`2022f564fb774dd0923f39a614f335f76844f4ea6001f0490b1ebc1db515e86d`). Its
contents were compared with the consumed artifact and were identical.

### Standard artifact resolution verified

An initial isolated-cache test with `BRAIN_SYSTEM_SOURCE=local` did not consume
the archives. This is expected: that development mode specifies
`nerves: [compile: true]`, so Nerves rebuilt the local packages and cached links
to `.nerves/reusable-system-artifact` and `o/host`.

A throwaway Nerves application was then created outside the repository with the
same local System package source but without `compile: true`, matching the
artifact behavior of a tagged dependency. With empty `NERVES_ARTIFACTS_DIR`, no
`NERVES_SYSTEM` / `NERVES_TOOLCHAIN` overrides, and an isolated
`NERVES_DL_DIR`, `mix deps.get` reported:

```text
Checking for prebuilt Nerves artifacts...
  Checking nerves_system_brain...
  => Trying .../nerves_system_brain-portable-0.1.0-087E263.tar.gz
  => Success
  Checking nerves_toolchain_brain...
  => Trying .../nerves_toolchain_brain-linux_x86_64-0.1.0-380F8C4.tar.xz
  => Success
```

The isolated artifact cache contained real extracted directories rather than
links to this repository, and `MIX_TARGET=brain mix compile` succeeded. This
proves the archive names, roots, checksums, extraction, and normal Nerves
resolver path. GitHub release publication remains the missing remote step.

### Standard `mix firmware.burn` task verified

The standard task was tested without risking physical media:

```sh
MIX_ENV=prod MIX_TARGET=brain mix firmware.burn \
  --device /tmp/hello_kiosk_brain-burn-test.img --task complete -y
```

It rebuilt firmware `pig-abandon` (`b904b08d-d8e1-5a87-000b-3dd24f59e84a`)
and completed the fwup write. The resulting 321 MiB image had the intended MBR:

```text
partition 1: start 2048,   131072 sectors, 64 MiB, FAT32 LBA, bootable
partition 2: start 133120, 524288 sectors, 256 MiB, Linux
```

This verifies that System dependency use, firmware generation, `fwup`, and the
standard burn task can all be adopted without introducing A/B slots. It does
not make blank media bootable: the current `complete` task creates/preserves the
p1 layout but does not package brain-hackers boot files. A pre-provisioned p1
remains a prerequisite until redistribution and blank-media policy are decided.

Warnings still present in the application compile are unrelated to the Nerves
System packaging PoC:

- duplicate `touch_btn/2` clauses in `HelloKioskBrain.Input`
- bitstring size pinning warnings in `HelloKioskBrain.Fb.stamp/4`
- unused `@battmon` in `HelloKioskBrain.Battery`
- `HelloKioskBrain.Display` calling `HelloKioskBrain.Fb.open/0`, which is not
  currently defined. `Display` is not currently supervised; the running kiosk
  path uses `HelloKioskBrain.Kiosk`.

### Standard target IEx dependencies

The example application now follows the minimal setup used by regular Nerves
examples:

- `:nerves_runtime` is a target dependency and a shoehorn init application.
- `:nerves_motd` prints the target summary from `priv/iex.exs`.
- `:toolshed` is imported from `priv/iex.exs`.
- project-specific IEx helpers remain imported after the standard helpers.

Adding `nerves_runtime` exposed one System responsibility that the standalone
application had not needed: `nerves_uevent` links against `libmnl`. The first
target compile failed on a missing `libmnl/libmnl.h`. Adding
`BR2_PACKAGE_LIBMNL=y` to `nerves_defconfig` placed the header and library in the
System sysroot and the shared library in the target rootfs. After rebuilding the
System output, the standard application command compiled all dependencies and
the native uevent helper for ARMv5:

```sh
MIX_TARGET=brain BRAIN_SYSTEM_SOURCE=local mise exec -- mix compile
```

The production release for firmware `sphere-laptop` contains
`nerves_runtime 0.13.13`, `nerves_motd 0.1.17`, `toolshed 0.5.0`, and
`nerves_uevent 0.1.7`. Host tests pass (4 tests); their expected warning about
loading the ARM32 kiosk NIF on x86_64 remains unchanged. Device verification of
the new runtime initialization and IEx startup is the next step.

### `mix upload` is not safe on the current single-root layout

The current application does not provide a `mix upload` task. That task normally
comes from `ssh_subsystem_fwup`, commonly through `nerves_ssh`, and sends the
firmware to an SSH subsystem named `fwup`. The Brain application's custom SSH
daemon currently exposes only SFTP.

Adding the task and subsystem is straightforward, but enabling them would not
make updates safe. The standard subsystem invokes target `fwup` with
`--no-unmount` and the firmware `upgrade` task. On the reference PW-SH6, a
read-only SSH inspection confirmed:

```text
kernel command line: root=/dev/mmcblk1p2 rw rootwait
root mount:          /dev/root / ext4 rw
target fwup:         /usr/bin/fwup
```

The current `complete` task writes a complete ext4 image over p2 and requires an
unmounted destination. The current `upgrade` task intentionally returns an
error. Reusing `complete` remotely would overwrite the mounted root filesystem
from which Erlang and `fwup` are executing.

Therefore `mix upload` remains a storage/update follow-up, independent from the
now-working standard application compile and firmware build flow. A safe design
must first provide either an A/B rootfs with boot selection/rollback, or a
recovery/staging environment that applies the p2 image while p2 is unmounted.
An SFTP-based application-release replacement could be built separately, but it
would not be the standard Nerves `mix upload` firmware protocol.

### System dependency is feasible

`nerves_system_brain` can be shaped as a normal Nerves system package without
changing `nerves_defconfig`, `Config.in`, or `rootfs_overlay` in the first
stage. The key is that the package surface and the platform boot/storage choices
are separable.

The current reusable Buildroot output has the directories expected by
`nerves_system_br`:

- `o/host`
- `o/staging`
- `o/images`

`nerves_system_br`'s environment setup can use this directly as a local provider
because it finds the toolchain in `host` and the sysroot/ERTS headers in
`staging`.

### ARMv5 / Bootlin toolchain can be exposed

For local development, the existing Bootlin toolchain can be reused from
`o/host`. The expected Nerves cross-compile variables map cleanly:

| Variable | Proposed value |
| --- | --- |
| `TARGET_ARCH` | `arm` |
| `TARGET_CPU` | `arm926ej_s` |
| `TARGET_OS` | `linux` |
| `TARGET_ABI` | `gnueabi` |
| `TARGET_GCC_FLAGS` | `-marm -mcpu=arm926ej-s -mfloat-abi=soft` |

The value that should be verified most carefully is `TARGET_CPU`. Buildroot
selects `BR2_arm926t`; GCC accepts `-mcpu=arm926ej-s`, which better matches the
i.MX283 core family. If this causes any compiler/package regression, fall back
to the simpler Buildroot-selected defaults and keep CPU detail as metadata only.

Publishing a dedicated `nerves_toolchain_brain` artifact is still desirable for
release use. It removes the need for application developers to have a full
Buildroot output tree locally.

### Native code can move toward Nerves cross compilation

The existing `examples/hello_kiosk/Makefile` already has the right general
contract:

- `CC` / `CXX` can be supplied by the environment.
- `ERTS_INCLUDE_DIR` can be supplied by the environment.
- `MIX_APP_PATH` controls where `priv/` artifacts are written.

That aligns well with Nerves plus `elixir_make`. The application no longer needs
to discover `o/host/bin/arm-linux-g++` itself once the Nerves environment is
loaded.

### `mix compile` and `fwup` are separable

Using `nerves_system_brain` as a dependency and compiling target-specific native
code does not require `fwup`. `fwup` becomes necessary when producing or burning
a Nerves firmware artifact.

The first firmware-generation step is now proven without changing the storage
layout:

- `fwup.conf` models the existing FAT p1 + Linux p2 layout.
- `scripts/rel2fw.sh` keeps the Nerves firmware task interface but creates an
  ext4 image from `rootfs.tar`, the target release, and generated rootfs
  overlays instead of using the stock squashfs merge.
- The `complete` task writes p2 and preserves the same partition offsets. It
  assumes p1 already contains the brain-hackers boot files; it is not yet a
  from-blank-SD replacement for the current base-image workflow.

This means the migration can be staged:

1. Make `MIX_TARGET=brain mix compile` work using the existing `o/` output. Done
   in this PoC.
2. Make a release with `Nerves.Release.erts/0`. Done in this PoC.
3. Build an ext4-rootfs `.fw` for the current p2 layout. Done in this PoC.
4. Device-test the `.fw` against an SD card that already has the known-good p1
   boot files. Done with `skill-toe` on PW-SH6.
5. Use `mix firmware.burn` with the current `complete` task for pre-provisioned
   media; blank-media boot files, A/B slots, and update architecture remain
   independent follow-ups.

### PW-SH6-specific pieces should remain below the system interface

Do not standardize away:

- brain-hackers U-Boot and kernel assets.
- FAT p1 + ext4 p2 storage during the first stage.
- ARMv5 soft-float constraints.
- display/input initialization and device-specific kernel interfaces.
- the current manual SD deployment scripts while `fwup` is still experimental.

## Follow-up Issues

- Publish the consume-tested `nerves_toolchain_brain` and `nerves_system_brain`
  artifacts in a tagged GitHub release, then verify
  `BRAIN_SYSTEM_SOURCE=github MIX_TARGET=brain mix deps.get`.
- Decide whether `TARGET_CPU` should be `arm926ej_s`, `arm926t`, or omitted from
  compiler flags after native package testing.
- Decide whether the Brain app should keep the diagnostic `BootTrace` /
  `KioskLauncher` scaffolding, replace it with normal supervision, or gate it
  behind a bring-up config flag.
- Investigate USB NCM host enumeration if peripheral-mode USB development is
  still needed; HOST-mode LAN networking and SSH/IEx are verified.
- Add a blank-media story for `mix firmware.burn`, either by packaging the p1
  boot files when redistribution is acceptable or by documenting a base-image
  prerequisite.
- Revisit ADR 0005 after PoC verification and split accepted changes into
  smaller implementation issues.

## 2026-09-21: Blank-SD provisioning and A/B investigation

The fixed buildbrain release is `2026-03-25-024518`. Its small release assets
are sufficient for the direct-SD boot path; downloading the 685 MiB base SD
image is not necessary. The required files are:

| File | Archive | SHA-256 checked archive |
| --- | --- | --- |
| `edsh6exe.bin` | `uboot-sh6-2026-03-25-024518.zip` | `a07b43ade594b566ed189bcfc5e49212006679600ca30e2fb7468961ef664f95` |
| `zImage` | `linux-2026-03-25-024518.zip` | `da7a8f87c6daf982085c2f7042d874654645a28a6318558d3c6ea0e6a2851f69` |
| `imx28-pwsh6.dtb` | `linux-2026-03-25-024518.zip` | same as above |

`scripts/fetch_boot_assets.sh` verifies and extracts these files. `fwup.conf`
now formats p1 as FAT32, labels it `boot`, writes the three files, and writes the
generated ext4 release image to p2. A complete firmware was expanded to a raw
image and inspected without physical media:

```text
p1: FAT32 BOOT, edsh6exe.bin, zImage, imx28-pwsh6.dtb
p2: ext4, /srv/erlang/releases/0.1.0/shoehorn.boot
```

The fixed U-Boot source revision is `e8fc0d0cf39d9cd06245ef1777d1cf54258e5cb6`.
Its `brain_mx28_common.h` loads `uEnv.txt` from p1 and imports it before
`bootcmd`; `sdroot` can therefore select `/dev/mmcblk1p2` or p3. It has no
bootcount, slot validation, rollback, or inactive-slot updater. Merely adding
a p3 partition would make remote updates less safe, not more safe. ADR 0007
therefore keeps the legacy scripts as recovery tooling and defers A/B/mix-upload
until boot selection and rollback are designed and tested together.
