# PW-SH6 boot assets

`mix firmware` needs three files in this directory to make a blank SD card
bootable through the existing direct-SD boot path:

- `edsh6exe.bin`: PW-SH6 NK/U-Boot loader
- `zImage`: Linux kernel
- `imx28-pwsh6.dtb`: PW-SH6 host-mode Device Tree

They are derived from the fixed
[brain-hackers/buildbrain 2026-03-25-024518 release](https://github.com/brain-hackers/buildbrain/releases/tag/2026-03-25-024518).
They are intentionally not committed to this repository. Fetch them with:

```sh
scripts/fetch_boot_assets.sh
```

The fetcher verifies the upstream archive SHA-256 values before extraction.
To use a non-default location, pass it as its only argument and set the same
path in `BRAIN_BOOT_DIR` when running `mix firmware`.

Run the fetcher before `mix nerves.artifact` when publishing a System artifact.
The custom artifact platform copies the fetched bundle, so consumers of that
artifact do not need to download the upstream archives while building firmware.

The default DTB is the upstream host-mode DTB. The application can replace it
with its bundled peripheral-mode DTB after first boot when USB NCM is wanted.

The boot loader and kernel are upstream third-party works. See `NOTICE`,
`REUSE.toml`, and the upstream source repositories for their licensing and
corresponding source.
