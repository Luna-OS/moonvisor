# Moonvisor

A free, open-source app for running macOS virtual machines on Apple silicon Macs.

Moonvisor is built on Apple's [Virtualization framework](https://developer.apple.com/documentation/virtualization),
so guests run at near-native speed with no kernel extensions or helper tools.

## Features

- **One-click macOS install.** Downloads the latest macOS Apple supports for your Mac, or uses an `.ipsw` restore image you provide.
- **Library of virtual machines.** Create, duplicate, rename and delete machines from one window.
- **Suspend and resume.** Saves the entire running machine to disk and picks up exactly where you left off. When you quit Moonvisor, running machines are suspended automatically.
- **Snapshots.** Save the disk at any point and roll back later. Snapshots are APFS clones, so they are instant and only store what changed.
- **Shared folders.** Share Mac folders with the guest, read-write or read-only. They appear under `/Volumes/My Shared Files`.
- **Resizable display.** Resizing the window resizes the guest's screen. Retina presets are included.
- **Networking and sound.** Shared (NAT) networking and audio output work out of the box.

## Requirements

- A Mac with Apple silicon (M1 or later)
- macOS 14 Sonoma or later
- Free disk space for the guest: the restore image is about 15 GB, and each machine's disk grows as it's used

## Install

1. Download `Moonvisor-<version>.dmg` from [Releases](../../releases) and drag Moonvisor to Applications.
2. Moonvisor isn't notarized yet, so macOS blocks it the first time you open it. Open it once, then go to
   **System Settings → Privacy & Security** and click **Open Anyway**.
   Alternatively, run `xattr -dr com.apple.quarantine /Applications/Moonvisor.app` in Terminal.

## Build from source

Xcode 16 or later is required.

```sh
bash scripts/build-app.sh          # builds build/Moonvisor.app
bash scripts/build-app.sh --dmg    # also builds the disk image
open build/Moonvisor.app
```

The app needs the `com.apple.security.virtualization` entitlement, so start it from the built `.app` and not with
`swift run`. The build script signs the app ad hoc. To sign it with your own Developer ID, set `SIGN_IDENTITY`.

Pushing a `v*` tag builds the disk image on GitHub Actions and publishes it as a release.

## Where your machines are stored

`~/Library/Application Support/Moonvisor/Virtual Machines/<name>.moonvm`

Each `.moonvm` bundle contains the disk image (`Disk.img`), the platform files (`AuxiliaryStorage`, `HardwareModel`,
`MachineIdentifier`), the settings (`config.json`), a saved state if the machine is suspended, and its snapshots.
Downloaded restore images are cached in `~/Library/Application Support/Moonvisor/Restore Images`.

## Limitations

- Only macOS guests are supported at the moment.
- Apple's framework doesn't support clipboard sharing or USB passthrough for macOS guests.
- Signing in to iCloud inside a macOS guest requires macOS 15 on both the host and the guest.
- A machine and its duplicate share the same machine identifier, so they can't run at the same time.

## Roadmap

- Linux guests with Rosetta
- Notarized releases
- Disk resizing
- German localization

## License

[MIT](LICENSE)

Moonvisor is an independent project. It isn't affiliated with or endorsed by Apple or Parallels, and it contains
no code from other virtualization products.
