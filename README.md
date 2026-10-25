# Stratovo · Android, Windows & Ubuntu for Mac

**1.0 Beta 7.4 · Midnight**

This public update adds SSH/SFTP file exchange for Windows and Ubuntu. Windows setup repairs invalid SSH host-key permissions automatically before starting the service. See the [Beta 7.4 release guide](docs/RELEASE_1.0_BETA7_4.md). Android player changes remain in private testing. This remains a prerelease.

## Android, Windows and Ubuntu for Mac

**Free, open-source macOS app for Android emulation, Windows ARM64 and Ubuntu ARM virtual machines on Apple silicon.**

Developed by **PwnedG0blin** · macOS **14+** · **MIT license** · **1.0 Beta 7.4**

[Website](https://pwnedg0blin.pages.dev/) · [All projects](https://pwnedg0blin.pages.dev/projekte) · [Support](https://pwnedg0blin.pages.dev/support)

[Deutsch: vollständige Anleitung](README.de.md) · [Setup](LIES_MICH_ZUERST.md) · [Mac test builds](https://github.com/PwnedG0blin/Stratovo/actions/workflows/macos.yml) · [Report an issue](https://github.com/PwnedG0blin/Stratovo/issues)

Stratovo brings Android ARM64, Windows ARM64 and Ubuntu ARM guest systems into a native Mac interface. Install Android APKs, use persistent guest storage, and open Android and Ubuntu in resizable display windows. Windows uses a direct native Metal graphics window by default. Only one guest runs at a time. System images, engines and drivers are set up separately.

## Interface language

Stratovo follows your preferred macOS language at launch. Override it under Setup → Language. Fourteen language folders are included: German, English, French, Spanish, Italian, Portuguese, Dutch, Polish, Turkish, Ukrainian, Arabic, Simplified Chinese, Japanese and Korean. Core controls are translated; technical text falls back to English, and some tool errors/logs retain their original language. Full technical translation is still in progress. Guest languages are independent.

## Android on Apple silicon

- Android 16 with Google Play is the default profile; Android 17 is optional.
- Install APK files and configure display resolution, density and input.
- Guest apps, accounts and data persist between sessions.
- Android graphics performance and app compatibility depend on the emulator and guest configuration. A 60 FPS target does not guarantee 60 game frames per second.

## Windows ARM64 virtual machines

- Install Windows using your own ARM64 ISO and an appropriate Windows license.
- Persistent virtual disks, ARM64 firmware, TPM support and optional Virtio drivers.
- 3D through VirtIO / Neptune / DXMT / Metal in the existing Windows installation. Direct native output is the default, avoiding VNC/CPU frame copies; embedding remains an explicit experimental option. The initial graphics build requires full Xcode and additional libraries.

## Ubuntu ARM

- Ubuntu 26.04.1 LTS Desktop ARM64, downloaded from Canonical with pinned SHA-256 verification.
- Independent 64-GiB disk and UEFI state on the selected data drive.
- Same Stratovo player, keyboard, paste and trackpad controls. Plan about 80 GiB storage and 6–8 GiB guest RAM.

[What changed](docs/RELEASE_1.0_BETA6.md) · [Safe cleanup after updating](docs/AUFRAEUMEN.md)

## File exchange

The **File exchange / Dateiaustausch** workspace sets up SSH/SFTP for Windows and Ubuntu, lists guest folders and transfers selected files. Confirm the guest administrator prompt during first setup. Windows uses a visible local setup helper on the STRATOVO virtual CD, with automatic host-key permission repair. No macOS SMB share is required. Android retains its existing ADB send/import actions. See [setup instructions](docs/DATEIAUSTAUSCH.md).

## Install or build

Download the DMG from [GitHub Releases](https://github.com/PwnedG0blin/Stratovo/releases), or build from source after obtaining the Windows helper from the matching CI run, then run `bash scripts/build-app.sh` on an Apple-silicon Mac with Xcode command line tools. The output is `dist/Stratovo.app`.

The test app is ad-hoc signed, not Developer ID signed or notarized. See [signing information](SIGNIERUNG.md), [setup instructions](LIES_MICH_ZUERST.md) and [third-party licenses](THIRD_PARTY_NOTICES.md).

## Updating from Pixelkoje / OpenGuest

Stratovo was previously called Pixelkoje. The public repository is now **Stratovo**. GitHub redirects legacy OpenGuest links. Public app versions older than Beta 7.2 (build 1027) must be updated manually after the rename because their updater trusts only the old download paths. Shut down both guest systems and quit the previous app before replacing it. Keep your selected data folder.

The bundle ID, existing settings keys, keychain service, Android AVD names, Windows machine identity and legacy storage paths are intentionally preserved. Existing virtual disks are not moved or recreated by this rename.

## Development and privacy

The application is a development test version. Native compilation, automated tests and a launch smoke test do not establish full guest or game compatibility. Stratovo itself has no telemetry; guest operating systems and separately installed components have their own network behavior. GitHub update checks are optional and off by default; no automatic app installation occurs.

Contributions: [CONTRIBUTING.md](CONTRIBUTING.md) · Security and local data: [SECURITY.md](SECURITY.md).

## Developer and support

Developed by **PwnedG0blin**. [GitHub Sponsors](https://github.com/sponsors/PwnedG0blin) · [Patreon](https://www.patreon.com/cw/PwnedG0blinApp) · [X](https://x.com/PwnedG0blin)

Copyright (c) 2026 PwnedG0blin and contributors. [MIT license](LICENSE). Voluntary sponsorship supports development; Stratovo remains free and without a subscription.

Windows Arm uses a direct Cocoa/Metal graphics window by default, avoiding embedded VNC readback. The embedded view is experimental. Paste and file exchange remain in the Windows controls.

