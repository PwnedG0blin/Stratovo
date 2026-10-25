import Foundation
import CryptoKit
import StratovoCore

struct WindowsSSHIdentity: Sendable {
    static func validateFileName(_ name: String) throws {
        let invalid = CharacterSet(charactersIn: "<>:\"/\\|?*").union(.controlCharacters)
        let stem = name.components(separatedBy: ".")[0].trimmingCharacters(in: .whitespaces).uppercased()
        let reserved = Set(["CON", "PRN", "AUX", "NUL", "CONIN$", "CONOUT$"]
            + (1...9).flatMap { ["COM\($0)", "LPT\($0)"] }
            + ["COM¹", "COM²", "COM³", "LPT¹", "LPT²", "LPT³"])
        guard !name.isEmpty, name != ".", name != "..", name.utf16.count <= 255,
              !name.hasSuffix("."), !name.hasSuffix(" "), name.rangeOfCharacter(from: invalid) == nil,
              !reserved.contains(stem) else {
            throw StorageMigration.failure("Diesen Dateinamen kann Windows nicht verwenden: \(name). Die Datei auf dem Mac umbenennen und erneut auswählen.")
        }
    }

    let directory: URL
    var kind: ExchangeGuest = .windows
    var key: URL { directory.appendingPathComponent("id_ed25519") }
    var knownHosts: URL { directory.appendingPathComponent("known_hosts") }
    var alias: String { "stratovo-" + kind.rawValue + "-" + directory.lastPathComponent }

    static func prepare(storageID: String, kind: ExchangeGuest = .windows) throws -> Self {
        let hash = SHA256.hash(data: Data((storageID + (kind == .windows ? "" : "." + kind.rawValue)).utf8)).map { String(format: "%02x", $0) }.joined()
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OpenGuest/SSH/" + hash, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard directory.standardizedFileURL == directory.resolvingSymlinksInPath().standardizedFileURL else {
            throw StorageMigration.failure("SSH-Schlüsselordner darf keine Verknüpfung sein.")
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let identity = Self(directory: directory, kind: kind)
        if !FileManager.default.fileExists(atPath: identity.key.path) {
            let result = try CommandCapture.run(CommandSpec(executable: "/usr/bin/ssh-keygen",
                arguments: ["-q", "-t", "ed25519", "-N", "", "-C", "Stratovo-Dateiaustausch", "-f", identity.key.path]))
            guard result.status == 0 else { throw StorageMigration.failure("SSH-Schlüssel konnte nicht erstellt werden.") }
        }
        for file in [identity.key, identity.key.appendingPathExtension("pub")] {
            guard file.standardizedFileURL == file.resolvingSymlinksInPath().standardizedFileURL else {
                throw StorageMigration.failure("SSH-Schlüssel darf keine Verknüpfung sein.")
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
        return identity
    }

    func arguments(user: String, port: Int) throws -> [String] {
        guard !user.isEmpty, user.count <= 128, !user.unicodeScalars.contains(where: { $0.value < 32 }),
              (49152...65535).contains(port) else { throw StorageMigration.failure("Gültigen lokalen Windows-Benutzernamen eingeben.") }
        guard knownHosts.standardizedFileURL == knownHosts.resolvingSymlinksInPath().standardizedFileURL,
              FileManager.default.fileExists(atPath: knownHosts.path) else {
            throw StorageMigration.failure("Windows zuerst über Verbinden koppeln.")
        }
        return ["-F", "/dev/null", "-T", "-p", String(port), "-l", user, "-i", key.path,
                "-oBatchMode=yes", "-oIdentitiesOnly=yes", "-oIdentityAgent=none", "-oStrictHostKeyChecking=yes",
                "-oUserKnownHostsFile=\"" + knownHosts.path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"", "-oGlobalKnownHostsFile=/dev/null",
                "-oHostKeyAlias=" + alias, "-oHostKeyAlgorithms=ssh-ed25519", "-oConnectTimeout=8",
                "-oServerAliveInterval=5", "-oServerAliveCountMax=3", "-oPasswordAuthentication=no",
                "-oKbdInteractiveAuthentication=no", "-oClearAllForwardings=yes", "-s", "127.0.0.1", "sftp"]
    }

    static func hostKey(from scan: String) throws -> (key: String, fingerprint: String) {
        let keys = scan.split(separator: "\n").filter { !$0.hasPrefix("#") }.compactMap { line -> String? in
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard fields.count == 3, fields[1] == "ssh-ed25519", let bytes = Data(base64Encoded: String(fields[2])), bytes.count == 51 else { return nil }
            return "ssh-ed25519 " + fields[2]
        }
        guard let key = keys.first, Set(keys).count == 1,
              let blob = Data(base64Encoded: String(key.split(separator: " ")[1])) else {
            throw StorageMigration.failure("Windows-SSH ist noch nicht erreichbar. Einrichtung in Windows abschließen und erneut verbinden.")
        }
        let fingerprint = Data(SHA256.hash(data: blob)).base64EncodedString().replacingOccurrences(of: "=", with: "")
        return (key, "SHA256:" + fingerprint)
    }

    func readPublicKey() throws -> String {
        try String(contentsOf: key.appendingPathExtension("pub"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
