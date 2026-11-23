# ezNTFS

English · [简体中文](README.zh-CN.md) · [日本語](README.ja.md)

ezNTFS is a free, open-source tool for writing to NTFS external hard drives on Mac. It uses NTFS-3G and macFUSE so you can copy files in Finder without reformatting the drive. It also supports per-disk auto mount, safe ejection, and copying with SHA-256 verification.

[Official website](https://ixiehao.github.io/ezNTFS/) · [Download 0.5.2 for Apple Silicon](https://github.com/ixiehao/ezNTFS/releases/download/v0.5.2/ezNTFS-0.5.2-arm64.pkg) · [Release notes and checksums](https://github.com/ixiehao/ezNTFS/releases/tag/v0.5.2) · [Report an issue](https://github.com/ixiehao/ezNTFS/issues)

## Requirements

- Apple Silicon Mac running macOS 14 or later.
- The ezNTFS installer automatically checks for macFUSE 5.5.0. If it’s already installed, continue with ezNTFS. If it’s missing, install it once per Mac from the [official macFUSE 5.5.0 release](https://github.com/macfuse/macfuse/releases/tag/macfuse-5.5.0).
- Administrator approval to install the app, system mount service, and NTFS-3G driver from the ezNTFS PKG.
- The app and bundled executables use ad-hoc signing. The PKG is unsigned and not notarized. The release page includes SHA-256 checksums.

<img src="website/assets/ezntfs-en.png" width="660" alt="ezNTFS showing three demo NTFS disks and their mount states">

## Use

1. Connect an external NTFS disk and choose **Mount Read-Write** on its card or in the menu bar. If another driver is managing it, unmount the volume normally first.
2. For automatic mounting, turn on **Mount on Connection** in Settings and **Auto Mount** for the disk. Drives without a stable identifier can be mounted manually.
3. **Copy & Verify** copies regular files and folders one at a time, then reads back each copy and checks its SHA-256 digest. The batch is delivered in a new folder after verification. It includes empty files and directories. File dates and extended attributes use the driver’s metadata support. Full macOS permissions, hard-link relationships, and special files are outside this copy mode.
4. When finished, close files on the disk and choose **Safely Eject**. This ejects the entire physical disk and all its volumes. If macOS reports it is in use, close the windows or apps using it and retry.
5. Closing the main window keeps ezNTFS running in the menu bar. Choose **Open ezNTFS** to bring the window back, or **Quit ezNTFS** to exit.

## Settings and troubleshooting

- The **Language** menu and Settings share the same choices: Follow System, English, Simplified Chinese, and Japanese. The Installer and system dialogs use macOS’s language settings.
- **Help → Check for Updates** checks GitHub for the latest public stable release. When a newer version is available, **View Release** appears as a separate item in Help and the status menu.
- **Help → Check Dependencies** opens the same panel as **Environment Check** in Settings. It shows macFUSE, NTFS-3G, and the mount service. If macOS blocks raw disk access, use **Open Privacy Settings** and **Copy Service Path** to add the mount service to Full Disk Access. See [Privacy and permissions](docs/PRIVACY.md).
- Before upgrading or repairing the driver, close files on your external disks, safely eject all external disks, and reopen the installer. Reconnect them after installation.

## Development

[Documentation](docs/README.md) · [Build](docs/DEVELOPMENT.md) · [Testing](docs/QA.md) · [Releasing](docs/RELEASING.md) · [Contributing](CONTRIBUTING.md) · [Security](SECURITY.md)

ezNTFS is available under the [MIT License](LICENSE). See [Third-party components](docs/THIRD_PARTY.md) for NTFS-3G, macFUSE, and Tabler Icons.
