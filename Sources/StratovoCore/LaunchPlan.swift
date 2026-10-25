import Foundation

public enum GuestError: LocalizedError {
    case invalidResources
    case wrongArchitecture
    case missingFile(String)
    case invalidAVD
    case invalidAPK
    case timedOut
    case commandFailed(Int32, String)

    public var errorDescription: String? {
        switch self {
        case .invalidResources:
            return "Bitte 2–8 CPU-Kerne und 2–8 GB RAM wählen (Windows mindestens 4 GB)."
        case .wrongArchitecture:
            return "Dieser Test benötigt ein Android-Gerät mit arm64-v8a. Bitte im Android Studio Device Manager anlegen."
        case .missingFile(let path): return "Datei fehlt oder ist nicht lesbar: \(path)"
        case .invalidAVD: return "Kein gültiges Android-Gerät ausgewählt."
        case .invalidAPK: return "Bitte eine lesbare einzelne .apk-Datei auswählen. Split-APK-Archive werden noch nicht unterstützt."
        case .timedOut: return "Die Prüfung wurde nach dem Zeitlimit beendet."
        case .commandFailed(let code, let output):
            return "Programm beendet mit Code \(code):\n\(output)"
        }
    }
}

public struct GuestResources: Equatable {
    public let memoryMiB: Int
    public let cores: Int
    public init(memoryMiB: Int, cores: Int) {
        self.memoryMiB = memoryMiB
        self.cores = cores
    }
    public func validate(windows: Bool = false) throws {
        guard ((windows ? 4096 : 2048)...8192).contains(memoryMiB),
              (2...8).contains(cores) else { throw GuestError.invalidResources }
    }
}

public struct CommandSpec: Equatable {
    public let executable: String
    public let arguments: [String]
    public let environment: [String: String]
    public init(executable: String, arguments: [String], environment: [String: String] = [:]) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
    }
    // Display only. Commands are always executed using Process.arguments, never a shell.
    public var display: String {
        ([executable] + arguments).map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }
            .joined(separator: " ")
    }
}

public struct AndroidDevice: Identifiable, Equatable {
    public let name: String
    public let abi: String
    public let googlePlay: Bool
    public var id: String { name }
    public var supported: Bool { abi == "arm64-v8a" }
    public init(name: String, abi: String, googlePlay: Bool = false) {
        self.name = name; self.abi = abi; self.googlePlay = googlePlay
    }
}

public enum LaunchPlan {
    public static func android(sdk: String, device: AndroidDevice, resources: GuestResources,
                               coldBoot: Bool, gpu: String, port: Int = 5554, vulkan: Bool = true, output: AndroidOutputMode = .player) throws -> CommandSpec {
        try resources.validate()
        guard !device.name.isEmpty, !device.name.hasPrefix("-"),
              !device.name.contains("/"), !device.name.contains("\\"),
              !device.name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else { throw GuestError.invalidAVD }
        guard device.supported else { throw GuestError.wrongArchitecture }
        guard ["auto", "host", "software"].contains(gpu) else { throw GuestError.invalidResources }
        guard (5554...5682).contains(port), port.isMultiple(of: 2) else { throw GuestError.invalidAVD }
        var args = ["-avd", device.name, "-accel", "on", "-gpu", output.gpu(requested: gpu),
                    "-memory", String(resources.memoryMiB), "-cores", String(resources.cores),
                    "-port", String(port), "-camera-back", "none", "-camera-front", "none"]
        if output.usesStream { args.append("-no-window") }
        if coldBoot { args.append("-no-snapshot-load") }
        if !vulkan { args += ["-feature", "-Vulkan"] }
        return CommandSpec(executable: URL(fileURLWithPath: sdk).appendingPathComponent("emulator/emulator").path,
                           arguments: args, environment: ["ANDROID_HOME": sdk, "ANDROID_SDK_ROOT": sdk])
    }

    public static func installAPK(adb: String, port: Int, apk: String) throws -> CommandSpec {
        guard (5554...5682).contains(port), port.isMultiple(of: 2), apk.hasPrefix("/"),
              URL(fileURLWithPath: apk).pathExtension.lowercased() == "apk",
              FileManager.default.isReadableFile(atPath: apk) else { throw GuestError.invalidAPK }
        return CommandSpec(executable: adb, arguments: ["-s", "emulator-\(port)", "install", "-r", apk])
    }

    private static func block(_ name: String, driver: String, path: String, readOnly: Bool) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: [
            "driver": driver, "node-name": name, "read-only": readOnly,
            "file": ["driver": "file", "filename": path]
        ], options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    public static func windowsVM(qemu: String, firmware: String, variables: String, disk: String,
                                 tpmSocket: String, iso: String?, driversISO: String?, proISO: String?,
                                 installing: Bool, resources: GuestResources, displaySocket: String, network: Bool, qmpSocket: String, identity: WindowsMachineIdentity = .legacy,
                                 graphics: WindowsGraphics = .basic, resolution: WindowsDisplayMode = .fullHD, metalRoot: String? = nil, embeddedPlayer: Bool = false, bootArtwork: String? = nil, writeLimit: WindowsWriteLimit = .off, refreshRate: WindowsRefreshRate = .automatic) throws -> CommandSpec {
        try resources.validate(windows: true)
        try identity.validate()
        guard displaySocket.hasPrefix("/tmp/og-"), !displaySocket.contains(","), !displaySocket.contains("\n") else { throw GuestError.invalidResources }
        guard qmpSocket.hasPrefix("/tmp/og-"), !qmpSocket.contains(","), !qmpSocket.contains("\n") else { throw GuestError.invalidResources }
        let metal = metalRoot != nil
        var args = ["-name", "Windows Arm", "-nodefaults",
                    "-machine", metal ? "virt,pflash0=uefi-code,pflash1=uefi-vars,gic-version=3" : "virt,pflash0=uefi-code,pflash1=uefi-vars", "-accel", metal ? "hvf,ipa-granule-size=0x1000" : "hvf", "-cpu", "host",
                    "-smp", String(resources.cores), "-m", String(resources.memoryMiB),
                    "-blockdev", try block("uefi-code", driver: "raw", path: firmware, readOnly: true),
                    "-blockdev", try block("uefi-vars", driver: "raw", path: variables, readOnly: false),
                    "-blockdev", try block("systemdisk", driver: "qcow2", path: disk, readOnly: false),
                    "-device", "nvme,drive=systemdisk,serial=\(identity.serial),bootindex=2",
                    "-device", graphics.device(resolution: resolution), "-device", "qemu-xhci,id=usb",
                    "-device", "usb-kbd,bus=usb.0", "-device", "usb-tablet,bus=usb.0",
                    "-audiodev", "coreaudio,id=stratovo-audio",
                    "-device", "usb-audio,id=stratovo-sound,bus=usb.0,audiodev=stratovo-audio",
                    "-display", "none", "-vnc", "unix:\(displaySocket)", "-serial", "none", "-monitor", "none",
                    "-qmp", "unix:\(qmpSocket),server=on,wait=off",
                    "-chardev", "socket,id=chrtpm,path=\(tpmSocket)",
                    "-tpmdev", "emulator,id=tpm0,chardev=chrtpm",
                    // QEMU #4587: PPI's 1 KiB RAM region aborts HVF on 16 KiB hosts.
                    // Keep TPM 2.0 and its persistent state; disable only the PPI region.
                    "-device", metal ? "tpm-tis-device,tpmdev=tpm0" : "tpm-tis-device,tpmdev=tpm0,ppi=off",
                    "-device", "virtio-rng-pci"]
        if writeLimit != .off {
            // A runtime filter preserves the existing image, cache/flush semantics
            // and NVMe identity. Off keeps the original block graph entirely.
            let group: [String: Any] = ["qom-type": "throttle-group", "id": "windows-write-limit",
                                       "limits": ["bps-write": writeLimit.bytesPerSecond]]
            let filter: [String: String] = ["driver": "throttle", "node-name": "limited-systemdisk",
                                            "throttle-group": "windows-write-limit", "file": "systemdisk"]
            let nvme = args.firstIndex(of: "nvme,drive=systemdisk,serial=\(identity.serial),bootindex=2")!
            args[nvme] = "nvme,drive=limited-systemdisk,serial=\(identity.serial),bootindex=2"
            args += ["-object", String(decoding: try JSONSerialization.data(withJSONObject: group, options: .sortedKeys), as: UTF8.self),
                     "-blockdev", String(decoding: try JSONSerialization.data(withJSONObject: filter, options: .sortedKeys), as: UTF8.self)]
        }
        if let uuid = identity.uuid {
            args += ["-uuid", uuid, "-smbios", "type=1,manufacturer=Pixelkoje,product=Pixelkoje Windows ARM64,serial=\(identity.serial)"]
        }
        if network {
            let mac = identity.mac.map { ",mac=" + $0 } ?? ""
            args += ["-netdev", "user,id=net0", "-device", "virtio-net-pci,netdev=net0" + mac]
        }
        else { args += ["-nic", "none"] }
        // Dedicated read-only media for the visible SSH setup helper.
        args += ["-drive", "if=none,id=stratovo-exchange,media=cdrom,readonly=on",
                 "-device", "usb-bot,id=stratovo-exchange-usb,bus=usb.0",
                 "-device", "scsi-cd,id=stratovo-exchange-cd,drive=stratovo-exchange,bus=stratovo-exchange-usb.0,scsi-id=0,lun=0"]
        if installing, let iso, !iso.isEmpty {
            args += ["-blockdev", try block("installer", driver: "raw", path: iso, readOnly: true),
                     "-device", "usb-bot,id=installer-usb,bus=usb.0",
                     "-device", "scsi-cd,id=installer-cd,drive=installer,bus=installer-usb.0,scsi-id=0,lun=0,bootindex=1"]
        }
        if let driversISO, !driversISO.isEmpty {
            args += ["-blockdev", try block("drivers", driver: "raw", path: driversISO, readOnly: true),
                     "-device", "usb-bot,id=drivers-usb,bus=usb.0",
                     "-device", "scsi-cd,id=drivers-cd,drive=drivers,bus=drivers-usb.0,scsi-id=0,lun=0"]
        }
        if installing, let proISO {
            args += ["-blockdev", try block("edition", driver: "raw", path: proISO, readOnly: true),
                     "-device", "usb-bot,id=edition-usb,bus=usb.0",
                     "-device", "scsi-cd,id=edition-cd,drive=edition,bus=edition-usb.0,scsi-id=0,lun=0"]
        }
        args += ["-boot", "menu=on,splash-time=3000"]
        if let root = metalRoot {
            guard root.hasPrefix("/"), !root.contains("\n") else { throw GuestError.invalidResources }
            let device = args.firstIndex(where: { $0 == "ramfb" || $0.hasPrefix("virtio-gpu-pci,") })!
            args[device] = "virtio-ramfb-gl,hostmem=8G,blob=true,venus=false,neptune=true"
            args += ["-vga", "none"]
            let display = args.firstIndex(of: "-display")!
            args[display+1] = "cocoa,gl=es,zoom-to-fit=on"
            args += ["-blockdev", try block("graphics", driver: "raw", path: root+"/GraphicsDrivers.iso", readOnly: true),
                     "-device", "usb-bot,id=graphics-usb,bus=usb.0",
                     "-device", "scsi-cd,id=graphics-cd,drive=graphics,bus=graphics-usb.0,scsi-id=0,lun=0"]
            var environment = ["NPT_BACKEND": "dxmt", "ANGLE_DEFAULT_PLATFORM": "metal",
                "RENDER_SERVER_EXEC_PATH": root+"/Runtime/libexec/virgl_render_server",
                "DYLD_FALLBACK_LIBRARY_PATH": root+"/Runtime/lib:"+root+"/ANGLE.xcarchive/Products/usr/local/lib"]
            if refreshRate != .automatic {
                environment["STRATOVO_DISPLAY_HZ"] = String(refreshRate.rawValue)
            }
            if embeddedPlayer {
                environment["STRATOVO_EMBEDDED_V1"] = "1"
            } else {
                environment["STRATOVO_NATIVE_PLAYER"] = "1"
                if let bootArtwork {
                    guard bootArtwork.hasPrefix("/tmp/og-"), !bootArtwork.contains("\n"), !bootArtwork.contains("\0") else { throw GuestError.invalidResources }
                    environment["STRATOVO_BOOT_ARTWORK"] = bootArtwork
                }
                // Native Cocoa/Metal output: no GPU readback or VNC frame transport.
                let vnc = args.firstIndex(of: "-vnc")!
                args.removeSubrange(vnc...vnc+1)
            }
            return CommandSpec(executable: root+"/Runtime/bin/qemu-system-aarch64", arguments: args,
                               environment: environment)
        }
        return CommandSpec(executable: qemu, arguments: args)
    }

}

