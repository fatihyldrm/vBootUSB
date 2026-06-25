# vBootUSB

A native macOS app to create bootable USB drives from Windows, VMware ESXi and Linux ISO images.

## Features

- **Safe device selection** — system and internal disks are never listed or writable.
- **Automatic write method** — byte-for-byte image writing with SHA‑256 verification for hybrid Linux/ESXi images, or file copy (FAT32) for Windows and ESXi, including automatic splitting of large `install.wim` files.
- **Partition scheme** (MBR/GPT) and **file system** (FAT32/exFAT) options.
- **Non‑bootable mode** to simply format a drive.
- **Live progress** with transfer speed and a clear success / failure result.
- **Built‑in update check** and an About panel.

## Install

Download the latest `.pkg` from the [Releases](https://github.com/fatihyldrm/vBootUSB/releases) page and **double‑click it** — no Terminal required. If macOS shows an "unidentified developer" warning, right‑click the package and choose **Open**, or allow it from **System Settings → Privacy & Security**.

## Usage

1. Open **vBootUSB**.
2. Select your USB drive.
3. Choose **Disk or ISO image** and pick an ISO (or **Non bootable** to just format).
4. Adjust the options if needed, then click **START**. You'll be asked for your administrator password once.

A success or failure result is shown when the operation finishes.

## How it works

The app reads files the user selects and only elevates the privileged steps (partitioning, formatting and raw image writing). Linux/ESXi hybrid images are written byte‑for‑byte and verified with SHA‑256; Windows media is created by formatting FAT32 and copying the ISO contents, splitting `install.wim` into `.swm` parts when it exceeds the FAT32 4 GB limit (requires [wimlib](https://wimlib.net)).

## Building from source

Requires macOS 13+ and the Swift 6 toolchain (Xcode).

```bash
make app     # build vBootUSB.app into dist/
make pkg     # build the installer package into dist/
```

## Updates

The app reads `latest.json` from this repository and shows an **Update available** banner when a newer version is published. To publish a new version: bump `VERSION` in the `Makefile` and `version` in `latest.json`, run `make pkg`, upload the package to Releases, then push.

## License

MIT — see [LICENSE](LICENSE).
