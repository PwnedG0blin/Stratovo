import Foundation
import CryptoKit

public enum GuestRemovalTarget: Equatable, Sendable {
    case windows, ubuntu, android(String)
    public var kind: String {
        switch self { case .windows: return "windows"; case .ubuntu: return "ubuntu"; case .android: return "android" }
    }
}

public struct GuestRemovalPlan: Equatable, Sendable {
    public struct Entry: Equatable, Sendable {
        public let path: String
        let device: UInt64
        let inode: UInt64
        let type: String
    }
    public let target: GuestRemovalTarget
    public let storageID: String
    public let entries: [Entry]
    public let retainedAndroidImage: Bool
    public var paths: [String] { entries.map(\.path) }
}

/// Only managed guest folders are eligible. Runtime binaries, the root pointer,
/// other guests and online accounts never enter the plan.
public enum GuestRemoval {
    private static let fm = FileManager.default
    private static func failure(_ text: String) -> NSError { StorageMigration.failure(text) }
    private static func exists(_ url: URL) -> Bool { (try? fm.attributesOfItem(atPath: url.path)) != nil }
    private static func checked(_ url: URL, inside root: URL) throws {
        // URL equality also compares directory hints. macOS additionally aliases
        // /private/var and /var while standardizing file URLs. Check components
        // below the approved root using lstat-backed attributes instead.
        let base = root.standardizedFileURL
        var current = url.standardizedFileURL
        guard current.path.hasPrefix(base.path + "/") else {
            throw failure("Entfernen abgebrochen: Verknüpfung oder fremder Pfad. " + url.path)
        }
        while current.path != base.path {
            if let attributes = try? fm.attributesOfItem(atPath: current.path),
               attributes[.type] as? FileAttributeType == .typeSymbolicLink {
                throw failure("Entfernen abgebrochen: Verknüpfung oder fremder Pfad. " + url.path)
            }
            current.deleteLastPathComponent()
        }
        guard (try fm.attributesOfItem(atPath: base.path)[.type] as? FileAttributeType) == .typeDirectory else {
            throw failure("Der gewählte Datenordner ist kein regulärer Ordner.")
        }
    }
    private static func entry(_ url: URL, root: URL) throws -> GuestRemovalPlan.Entry {
        try checked(url, inside: root)
        let attributes = try fm.attributesOfItem(atPath: url.path)
        guard let type = attributes[.type] as? FileAttributeType,
              type == .typeDirectory || type == .typeRegular,
              let device = attributes[.systemNumber] as? NSNumber,
              let inode = attributes[.systemFileNumber] as? NSNumber else {
            throw failure("Unbekannter Dateityp: " + url.path)
        }
        return .init(path: url.path, device: device.uint64Value, inode: inode.uint64Value, type: type.rawValue)
    }
    private static func ini(_ file: URL) throws -> [String: String] {
        RuntimeDiscovery.parseINI(try String(contentsOf: file, encoding: .utf8))
    }
    private static func image(config: [String: String], storage: GuestStorage) -> URL? {
        guard let path = config["image.sysdir.1"], !path.isEmpty else { return nil }
        let sdk = config["stratovo.sdk"].map { URL(fileURLWithPath: $0) } ?? storage.sdk
        let result = (path.hasPrefix("/") ? URL(fileURLWithPath: path) : sdk.appendingPathComponent(path)).standardizedFileURL
        let roots = [storage.sdk.appendingPathComponent("system-images"),
                     storage.url.appendingPathComponent("Android/Systems/Preview/sdk/system-images")].map(\.standardizedFileURL)
        // Exact package leaf, never an SDK or a platform parent.
        return roots.contains { root in
            result.path.hasPrefix(root.path + "/") &&
            result.pathComponents.count == root.pathComponents.count + 3 &&
            result.lastPathComponent == "arm64-v8a"
        } ? result : nil
    }
    public static func plan(storage: GuestStorage, target: GuestRemovalTarget,
                            support: URL = GuestStorage.pointer.deletingLastPathComponent()) throws -> GuestRemovalPlan {
        try storage.validate()
        let root = storage.url.standardizedFileURL
        guard (try fm.attributesOfItem(atPath: root.path)[.type] as? FileAttributeType) == .typeDirectory else {
            throw failure("Datenordner ist kein regulärer Ordner.")
        }
        var urls: [(URL, URL)] = []
        var retained = false
        func include(_ url: URL, inside base: URL) throws {
            // Validate missing paths too, so a dangling link cannot be silently skipped.
            try checked(url, inside: base)
            if exists(url) { urls.append((url, base)) }
        }
        switch target {
        case .windows, .ubuntu:
            let folder = target == .windows ? "Windows" : "Ubuntu"
            try include(root.appendingPathComponent(folder), inside: root)
            try include(root.appendingPathComponent("Austausch/" + folder), inside: root)
            let hashInput = storage.id + (target == .windows ? "" : ".ubuntu")
            let hash = SHA256.hash(data: Data(hashInput.utf8)).map { String(format: "%02x", $0) }.joined()
            try include(support.appendingPathComponent("SSH/" + hash), inside: support.standardizedFileURL)
        case .android(let name):
            let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_.-"))
            guard !name.isEmpty, name != ".", name != "..", name.count <= 200,
                  name.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
                throw failure("Ungültiger Android-Profilname.")
            }
            let profile = storage.avd.appendingPathComponent(name + ".avd")
            let locator = storage.avd.appendingPathComponent(name + ".ini")
            try checked(profile, inside: root)
            try checked(profile.appendingPathComponent("config.ini"), inside: root)
            // Incomplete installations must be removable too. Missing config means
            // that no SDK image can be safely attributed to this profile.
            let configFile = profile.appendingPathComponent("config.ini")
            var config = [String: String]()
            if exists(configFile) { config = try ini(configFile) }
            if exists(locator) {
                try checked(locator, inside: root)
                let values = try ini(locator)
                if let path = values["path"], URL(fileURLWithPath: path).standardizedFileURL.path != profile.standardizedFileURL.path {
                    throw failure("Das Android-Profil verweist auf einen anderen Ordner.")
                }
            }
            try include(profile, inside: root)
            try include(locator, inside: root)
            retained = true
            if let candidate = image(config: config, storage: storage), exists(candidate) {
                try checked(candidate, inside: root)
                var shared = false
                let externalRoots = [fm.homeDirectoryForCurrentUser.appendingPathComponent(".android/avd")]
                    + (ProcessInfo.processInfo.environment["ANDROID_AVD_HOME"].map { [URL(fileURLWithPath: $0)] } ?? [])
                for external in externalRoots where exists(external) && external.resolvingSymlinksInPath().standardizedFileURL.path != storage.avd.standardizedFileURL.path {
                    // Conservatively keep the image if Android Studio or another AVD
                    // directory exists outside our managed root.
                    let children = try fm.contentsOfDirectory(at: external, includingPropertiesForKeys: nil)
                    if children.contains(where: { ["avd", "ini"].contains($0.pathExtension) }) { shared = true }
                }
                // Check both orphan AVD folders and locators before deleting a package.
                for other in try fm.contentsOfDirectory(at: storage.avd, includingPropertiesForKeys: nil) {
                    let otherPath = other.standardizedFileURL.path
                    if otherPath == profile.standardizedFileURL.path || otherPath == locator.standardizedFileURL.path { continue }
                    if other.pathExtension == "avd" {
                        try checked(other, inside: root)
                        let file = other.appendingPathComponent("config.ini")
                        try checked(file, inside: root)
                        let otherConfig = try ini(file)
                        if image(config: otherConfig, storage: storage)?.path == candidate.path { shared = true }
                        if image(config: otherConfig, storage: storage) == nil { shared = true }
                    } else if other.pathExtension == "ini" {
                        try checked(other, inside: root)
                        let values = try ini(other)
                        guard let path = values["path"], URL(fileURLWithPath: path).deletingLastPathComponent().standardizedFileURL.path == storage.avd.standardizedFileURL.path else {
                            shared = true; continue
                        }
                        if !exists(URL(fileURLWithPath: path).appendingPathComponent("config.ini")) { shared = true }
                    }
                }
                if !shared { try include(candidate, inside: root); retained = false }
            }
        }
        let entries = try urls.map { try entry($0.0, root: $0.1) }.sorted { $0.path < $1.path }
        guard !entries.isEmpty else { throw failure("Für dieses System sind keine verwalteten Daten vorhanden.") }
        return .init(target: target, storageID: storage.id, entries: entries, retainedAndroidImage: retained)
    }

    /// Stages all selected paths into one bundle on the data volume. If any move
    /// or Trash operation fails, restore the staged paths before reporting failure.
    /// The injected Trash operation makes rollback testable without touching Trash.
    public static func execute(_ plan: GuestRemovalPlan, storage: GuestStorage,
                               support: URL = GuestStorage.pointer.deletingLastPathComponent(),
                               trash: (URL) throws -> URL) throws -> URL {
        guard plan.storageID == storage.id,
              try Self.plan(storage: storage, target: plan.target, support: support) == plan else {
            throw failure("Die Installation hat sich geändert. Bitte die Auswahl erneut prüfen.")
        }
        let bundle = storage.url.appendingPathComponent("Stratovo-Removed-" + UUID().uuidString, isDirectory: true)
        try checked(bundle, inside: storage.url)
        try fm.createDirectory(at: bundle, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var moved: [(URL, URL)] = []
        do {
            let manifest = plan.entries.map { ["original": $0.path] }
            try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
                .write(to: bundle.appendingPathComponent("Original-Paths.json"), options: .withoutOverwriting)
            for (index, item) in plan.entries.enumerated() {
                try storage.validate()
                let original = URL(fileURLWithPath: item.path)
                let base = original.standardizedFileURL.path.hasPrefix(storage.url.standardizedFileURL.path + "/")
                    ? storage.url : support.standardizedFileURL
                guard try entry(original, root: base) == item else { throw failure("Dateipfad wurde verändert: " + item.path) }
                let staged = bundle.appendingPathComponent("\(index)-" + original.lastPathComponent)
                try fm.moveItem(at: original, to: staged)
                moved.append((original, staged))
            }
            return try trash(bundle)
        } catch {
            var failed = [String]()
            for (original, staged) in moved.reversed() {
                do { try fm.moveItem(at: staged, to: original) }
                catch { failed.append(original.path) }
            }
            if failed.isEmpty { try? fm.removeItem(at: bundle) }
            else {
                throw failure("Entfernen angehalten. Wiederherstellung unvollständig; die Daten liegen hier: " + bundle.path + "\n" + failed.joined(separator: "\n"))
            }
            throw error
        }
    }
}
