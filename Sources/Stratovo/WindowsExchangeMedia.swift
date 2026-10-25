import Foundation
import StratovoCore

struct WindowsExchangeMedia: Sendable {
    let directory: URL
    var iso: URL { directory.appendingPathComponent("Stratovo.iso") }
    // Only discover and open a locally attached executable. No script or downloaded code is executed.
    static let launch = "cmd /c for %d in (D E F G H I J K L M N O P Q R S T U V W X Y Z) do @if exist %d:\\Stratovo.exe start \"\" %d:\\Stratovo.exe"

    static func create(helper: URL, baseURL: String, publicKey: String?, capture: Bool = false) throws -> Self {
        // Reuse the bounded capability endpoint validation without accepting a Windows script launcher.
        _ = try GuestBootstrapScripts.launch(kind: .ubuntu, baseURL: baseURL)
        let fm = FileManager.default
        guard fm.fileExists(atPath: helper.path), !((try helper.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink ?? false) else {
            throw StorageMigration.failure("Das Windows-Einrichtungsprogramm fehlt in dieser App.")
        }
        let root = fm.temporaryDirectory.appendingPathComponent("Stratovo-Media-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let media = Self(directory: root)
        do {
            let contents = root.appendingPathComponent("Content", isDirectory: true)
            try fm.createDirectory(at: contents, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            try fm.copyItem(at: helper, to: contents.appendingPathComponent("Stratovo.exe"))
            var config = ["endpoint": baseURL, "mode": capture ? "capture" : "setup"]
            if let publicKey { config["publicKey"] = publicKey }
            let json = try JSONSerialization.data(withJSONObject: config, options: .sortedKeys)
            try json.write(to: contents.appendingPathComponent("exchange.json"), options: .atomic)
            let result = try CommandCapture.run(CommandSpec(executable: "/usr/bin/hdiutil", arguments: [
                "makehybrid", "-o", media.iso.path, "-iso", "-joliet", "-default-volume-name", "STRATOVO", contents.path
            ]), timeout: 30)
            guard result.status == 0 else { throw GuestError.commandFailed(result.status, result.output) }
            return media
        } catch { media.remove(); throw error }
    }
    func remove() { try? FileManager.default.removeItem(at: directory) }
}
