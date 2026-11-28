# ezNTFS

English · [简体中文](README.zh-CN.md) · [日本語](README.ja.md)

Read and write Windows NTFS drives on your Mac. ezNTFS is a free, open-source NTFS tool for macOS. Connect a Windows-formatted external drive, choose **Mount Read-Write**, then copy files in Finder. You can keep the drive’s existing format and files.

Turn on auto-mount for the drives you use regularly. For important files, **Copy & Verify** reads each copy back and checks its SHA-256 before handing over the batch. ezNTFS uses NTFS-3G and macFUSE.

## Download 0.5.4 (stable)

| Mac | Minimum system | Installer |
| --- | --- | --- |
| Apple silicon | macOS 14 or later | [Apple silicon Setup ZIP](https://github.com/ixiehao/ezNTFS/releases/download/v0.5.4/ezNTFS-0.5.4-arm64-Setup.zip) |
| Intel Mac | macOS 12.7 Monterey or later | [Intel Setup ZIP](https://github.com/ixiehao/ezNTFS/releases/download/v0.5.4/ezNTFS-0.5.4-x86_64-Monterey-Setup.zip) |

[Release notes and checksums](https://github.com/ixiehao/ezNTFS/releases/tag/v0.5.4) · [ezNTFS official website](https://ixiehao.github.io/ezNTFS/)

<img src="website/assets/ezntfs-en.png" width="660" alt="ezNTFS showing three example NTFS drives and their mount status">

## Install

[Intel installation guide (Chinese)](docs/INSTALL-INTEL.zh-CN.md)

Unzip the download, open **Install ezNTFS**, and follow the installation or upgrade prompts. It skips a compatible macFUSE installation and downloads and verifies the official package if needed. Follow the macOS prompts for administrator approval, extensions and restarting.

For a standalone PKG:

1. Close files on your external drives and safely eject the drives before running the installer.
2. macFUSE 5.5.0 is a one-time install. If it’s already on your Mac, go straight to the ezNTFS PKG. [Get macFUSE 5.5.0](https://github.com/macfuse/macfuse/releases/tag/macfuse-5.5.0)
3. Open the ezNTFS PKG and approve installation in macOS.

The app and its executables are ad-hoc signed. The PKG is unsigned and has no Apple notarization.

For repairs, use **Environment Check → Install or Repair Dependencies** from the installed app. If an external disk is busy, safely eject it and retry.

## Use

- **Mount Read-Write** lets you use the drive in Finder. Unmount it first if another NTFS driver is using it.
- For automatic mounting, turn on **Mount on Connection** in Settings and **Auto Mount** for the drive. Use manual mounting for drives without a stable identifier.
- **Copy & Verify** checks each copy with SHA-256 and puts the batch in a new folder once it passes. It handles regular files and folders, including empty ones. Dates and extended attributes depend on driver support. Full macOS permissions, hard-link relationships and special files are outside its scope.
- Close open files before choosing **Safely Eject**. This ejects the whole drive, including all its volumes. If it’s busy, close the windows or apps using it and retry.

Closing the window leaves ezNTFS in the menu bar. Choose **Open ezNTFS** to bring it back.

## Help

- If macOS blocks disk access, open **Help → Check Dependencies**. Use **Open Full Disk Access** and **Show in Finder** to add or enable the mount service. Then click **Retry Mount**. [Privacy and permissions](docs/PRIVACY.md)
- Use **Help → Check for Updates** for the latest stable release. Choose your preferred language from the **Language** menu. [Report an issue](https://github.com/ixiehao/ezNTFS/issues)

## Development

[Documentation](docs/README.md) · [Build](docs/DEVELOPMENT.md) · [Testing](docs/QA.md) · [Releasing](docs/RELEASING.md) · [Contributing](CONTRIBUTING.md) · [Security](SECURITY.md)

[MIT License](LICENSE) · [Third-party components](docs/THIRD_PARTY.md)
