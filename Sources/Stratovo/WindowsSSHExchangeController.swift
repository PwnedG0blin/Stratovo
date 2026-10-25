import AppKit
import Combine
import StratovoCore

@MainActor
final class GuestFileExchangeController: ObservableObject {
    let kind: ExchangeGuest
    @Published private(set) var user = ""
    @Published private(set) var busy = false
    @Published private(set) var connected = false
    @Published private(set) var status = ""
    @Published private(set) var path = "."
    @Published private(set) var files = [SSHRemoteFile]()
    @Published private(set) var progress: Double?
    private var task: Task<Void, Never>?
    private var operation: SSHFileOperation?
    private var setupServer: GuestSetupServer?
    private var context: (identity: WindowsSSHIdentity, port: Int, user: String)?
    private var storageID: String?
    private var userKey: String { "Stratovo.SSH.User." + kind.rawValue + "." + (storageID ?? "") }

    init(kind: ExchangeGuest = .windows) { self.kind = kind; self.path = kind.initialPath }
    func attach(storage: GuestStorage?) {
        guard storageID != storage?.id else { return }
        cancel(disconnect: true); storageID = storage?.id
        user = UserDefaults.standard.string(forKey: userKey) ?? ""
    }
    func cancel(disconnect: Bool = false) {
        task?.cancel(); operation?.cancel(); setupServer?.stop()
        if disconnect { connected = false; context = nil; files = []; path = kind.initialPath }
    }
    private func begin(_ work: @escaping () async throws -> Void) {
        guard !busy else { return }
        busy = true; progress = nil
        task = Task {
            defer { busy = false; progress = nil; task = nil; operation = nil; setupServer?.stop(); setupServer = nil }
            do { try await work() }
            catch is CancellationError { status = L10n.text("Vorgang abgebrochen.") }
            catch { status = error.localizedDescription }
        }
    }
    private func run<T: Sendable>(timeout: TimeInterval = 30, _ body: @escaping @Sendable (SFTPChannel) throws -> T) async throws -> T {
        guard let context else { throw StorageMigration.failure("Zuerst den Dateiaustausch starten.") }
        let args = try context.identity.arguments(user: context.user, port: context.port)
        let op = SSHFileOperation(); operation = op
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let result = try await Task.detached(priority: .utility) { try op.run(arguments: args, timeout: timeout, body: body) }.value
            try Task.checkCancellation(); return result
        } onCancel: { op.cancel() }
    }
    private func list(_ directory: String) async throws -> [SSHRemoteFile] {
        return try await run { try $0.list(directory) }
    }

    func start(model: AppModel, repair: Bool = false) {
        guard let storage = model.storage, model.running, model.activeGuest == kind.rawValue else { return }
        attach(storage: storage)
        begin {
            try storage.validate(); self.connected = false; self.files = []
            let kind = self.kind
            let identity = try await Task.detached(priority: .utility) { try WindowsSSHIdentity.prepare(storageID: storage.id, kind: kind) }.value
            try Task.checkCancellation()
            let port = try await model.prepareGuestSSHExchange()
            self.user = UserDefaults.standard.string(forKey: self.userKey) ?? ""
            if !repair, !self.user.isEmpty, FileManager.default.fileExists(atPath: identity.knownHosts.path) {
                self.context = (identity, port, self.user)
                do {
                    self.files = try await self.list("."); self.path = "."; self.connected = true
                    self.status = L10n.text("Verbunden. Ordner öffnen oder Dateien auswählen."); return
                } catch is CancellationError { throw CancellationError() }
                catch { self.status = L10n.text("Verbindung wird automatisch neu eingerichtet …") }
            }
            self.context = nil
            let server = GuestSetupServer(); self.setupServer = server
            try await server.start()
            let launcher: String
            if kind == .windows {
                self.status = L10n.text("Windows-Einrichtungsmedium wird vorbereitet …")
                launcher = try await model.prepareWindowsExchangeMedia(baseURL: server.baseURL, publicKey: identity.readPublicKey())
            } else {
                server.script = Data(try GuestBootstrapScripts.script(kind: kind, publicKey: identity.readPublicKey(), baseURL: server.baseURL).utf8)
                launcher = try GuestBootstrapScripts.launch(kind: kind, baseURL: server.baseURL)
            }
            self.status = L10n.text("Einrichtung wird gestartet. Bitte das Systemfenster kurz unberührt lassen.")
            try await model.runGuestExchangeSetup(launcher, kind: kind) { count, total in self.progress = Double(count) / Double(total) }
            self.progress = nil
            self.status = kind == .windows
                ? L10n.text("Im Windows-Fenster Dateiaustausch einrichten wählen und die Administratorabfrage bestätigen.")
                : L10n.text("Einrichtung startet. Eine Administratorabfrage bitte im Systemfenster bestätigen.")
            let fetchDeadline = ProcessInfo.processInfo.systemUptime + 90
            let layoutRetry = ProcessInfo.processInfo.systemUptime + 12
            var triedAlternateLayout = false
            let deadline = ProcessInfo.processInfo.systemUptime + 1200
            var ready: GuestSetupUpdate?
            while ProcessInfo.processInfo.systemUptime < deadline {
                try Task.checkCancellation()
                if let update = server.update {
                    if update.stage == "error" { throw StorageMigration.failure(update.message ?? "Die Einrichtung ist fehlgeschlagen.") }
                    if update.stage == "ready" { ready = update; break }
                    if update.stage == "confirm" {
                        self.status = L10n.message("Bitte die Administratorabfrage in \(kind.title) bestätigen.")
                    } else if update.stage == "install" {
                        self.status = L10n.message("\(kind.title) installiert den Dateiaustausch. Das kann einige Minuten dauern.")
                    } else { self.status = L10n.text("Die geschützte Verbindung wird eingerichtet …") }
                } else if kind == .ubuntu, !server.fetched, !triedAlternateLayout, ProcessInfo.processInfo.systemUptime > layoutRetry {
                    triedAlternateLayout = true
                    self.status = L10n.text("Einrichtung wird mit dem anderen Tastaturlayout erneut gestartet …")
                    try await model.runGuestExchangeSetup(launcher, kind: kind, layout: model.windowsTextLayout == .german ? .us : .german) { _, _ in }
                } else if server.update == nil, !server.fetched, ProcessInfo.processInfo.systemUptime > fetchDeadline {
                    throw StorageMigration.failure(kind == .windows
                        ? "In Windows unter Dieser PC die CD STRATOVO öffnen und Stratovo.exe starten. Dann Dateiaustausch einrichten wählen. Falls die CD fehlt, Windows nach dem App-Update vollständig beenden und neu starten."
                        : "Die Einrichtung ist im System nicht angekommen. Auf den gestarteten Desktop wechseln, das Tastaturlayout in Stratovo prüfen und erneut Dateiaustausch starten wählen.")
                }
                try await Task.sleep(nanoseconds: 250_000_000)
            }
            guard let ready, let account = ready.user, !account.isEmpty, let raw = ready.key else {
                throw StorageMigration.failure("Die Einrichtung hat zu lange gedauert. Bitte erneut versuchen.")
            }
            let fields = raw.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard fields.count >= 2 else { throw GuestError.invalidResources }
            let host = try WindowsSSHIdentity.hostKey(from: "setup " + fields.prefix(2).joined(separator: " "))
            try (identity.alias + " " + host.key + "\n").write(to: identity.knownHosts, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: identity.knownHosts.path)
            self.user = account; self.context = (identity, port, account)
            self.status = L10n.text("Verbindung wird geprüft …")
            var lastError: Error = GuestError.timedOut
            for _ in 0..<8 {
                try Task.checkCancellation()
                do {
                    self.files = try await self.list("."); self.path = "."; self.connected = true
                    UserDefaults.standard.set(account, forKey: self.userKey)
                    self.status = L10n.text("Verbunden. Ordner öffnen oder Dateien auswählen.")
                    return
                } catch is CancellationError { throw CancellationError() }
                catch { lastError = error; try await Task.sleep(nanoseconds: 750_000_000) }
            }
            throw lastError
        }
    }
    func open(_ directory: String) {
        begin { self.files = try await self.list(directory); self.path = directory; self.status = "" }
    }
    func parent() {
        guard path != kind.rootPath else { return }
        let parent = (path as NSString).deletingLastPathComponent
        open(parent.isEmpty ? kind.rootPath : parent)
    }
    func open(_ file: SSHRemoteFile) { if file.directory { open(path + "/" + file.name) } }

    func send(model: AppModel) {
        guard connected, !busy, let storage = model.storage, storageID == storage.id else { return }
        let panel = NSOpenPanel()
        panel.title = L10n.message("Dateien zu \(kind.title) senden")
        panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls, directory = path, kind = kind
        begin {
            try storage.validate()
            var total: UInt64 = 0
            for url in urls {
                guard !url.lastPathComponent.contains("\\"), !url.lastPathComponent.unicodeScalars.contains(where: { $0.value < 32 }) else {
                    throw StorageMigration.failure("Die Datei auf dem Mac ohne Steuerzeichen oder Rückstrich im Namen umbenennen und erneut auswählen.")
                }
                if kind == .windows { try WindowsSSHIdentity.validateFileName(url.lastPathComponent) }
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true else { throw StorageMigration.failure("Bitte normale Dateien auswählen.") }
                total += UInt64(max(0, values.fileSize ?? 0))
            }
            let totalBytes = total
            var completed: UInt64 = 0
            let remoteDirectory = directory + "/Stratovo-" + UUID().uuidString
            try await self.run { try $0.createDirectory(remoteDirectory) }
            for (index, url) in urls.enumerated() {
                self.status = L10n.message("Datei \(index + 1) von \(urls.count): \(url.lastPathComponent)")
                let base = completed, remote = remoteDirectory + "/" + url.lastPathComponent
                let size = UInt64(max(0, try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0))
                let partial = remoteDirectory + "/" + UUID().uuidString + ".partial"
                    try await self.run(timeout: 7200) { channel in
                        try channel.upload(local: url, remote: partial) { count in
                            Task { @MainActor in self.progress = totalBytes == 0 ? 1 : min(1, Double(base + count) / Double(totalBytes)) }
                        }
                        try channel.rename(partial, to: remote)
                    }
                completed += size; self.progress = totalBytes == 0 ? 1 : min(1, Double(completed) / Double(totalBytes))
            }
            self.files = try await self.list(remoteDirectory); self.path = remoteDirectory
            self.status = L10n.text("Dateien übertragen.")
        }
    }
    func receive(_ selection: Set<String>, model: AppModel) {
        guard connected, !busy, let storage = model.storage, storageID == storage.id else { return }
        let selected = files.filter { !$0.directory && selection.contains($0.id) }, directory = path, kind = kind
        guard !selected.isEmpty else { return }
        begin {
            let parent = try ExchangeFolder.prepare(storage: storage).appendingPathComponent(kind.title, isDirectory: true)
            guard parent.standardizedFileURL == parent.resolvingSymlinksInPath().standardizedFileURL else { throw StorageMigration.failure("Importordner darf keine Verknüpfung sein.") }
            let target = parent.appendingPathComponent("Import-" + UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let total = selected.reduce(UInt64(0)) { $0 + $1.size }
            var completed: UInt64 = 0
            for (index, file) in selected.enumerated() {
                try storage.validate()
                let local = target.appendingPathComponent(file.name), partial = target.appendingPathComponent(UUID().uuidString + ".partial")
                self.status = L10n.message("Datei \(index + 1) von \(selected.count): \(file.name)")
                let base = completed
                do {
                        try await self.run(timeout: 7200) { channel in
                            try channel.download(remote: directory + "/" + file.name, local: partial, size: file.size) { count in
                                Task { @MainActor in self.progress = total == 0 ? 1 : min(1, Double(base + count) / Double(total)) }
                            }
                        }
                    try FileManager.default.moveItem(at: partial, to: local)
                } catch { try? FileManager.default.removeItem(at: partial); throw error }
                completed += file.size
            }
            self.status = L10n.text("Dateien empfangen."); NSWorkspace.shared.open(target)
        }
    }

}

typealias WindowsSSHExchangeController = GuestFileExchangeController
