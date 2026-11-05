import AppKit
import Foundation
import StratovoCore

@MainActor
final class AppUpdateInstaller: ObservableObject {
    @Published private(set) var busy = false
    @Published private(set) var status = ""

    func install(_ release: StratovoRelease, model: AppModel) async {
        guard Bundle.main.object(forInfoDictionaryKey: "StratovoBuildFlavor") as? String != "private" else {
            status = "Private Variante: Bitte ein privates Update verwenden."; return
        }
        guard let asset = release.assets?.first(where: { $0.isTrusted(for: release) }),
              let hash = asset.sha256, let version = release.version else {
            status = L10n.text("Kein geprüftes Apple-Silicon-App-Paket vorhanden. Bitte die Veröffentlichung öffnen."); return
        }
        await install(model: model, hash: hash, size: Int64(asset.size), version: version) {
            let config = URLSessionConfiguration.ephemeral; config.urlCache = nil
            let session = URLSession(configuration: config)
            defer { session.invalidateAndCancel() }
            var request = URLRequest(url: asset.browserDownloadURL); request.timeoutInterval = 180
            let (data, response) = try await session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw PrivateUpdateAPI.failure("Update-Download fehlgeschlagen.")
            }
            return data
        }
    }

    func installPrivate(_ artifact: PrivateUpdateArtifact, token: String, model: AppModel) async {
        guard Bundle.main.object(forInfoDictionaryKey: "StratovoBuildFlavor") as? String == "private",
              let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
              let currentBuild = Int(current), let build = artifact.build, build > currentBuild,
              let hash = artifact.sha256, !artifact.expired else {
            status = "Kein neueres privates Update vorhanden. Bitte erneut prüfen."; return
        }
        await install(model: model, hash: hash, size: artifact.size, privateBuild: build) {
            try await PrivateUpdateAPI(token: token).download(artifact)
        }
    }

    private func install(model: AppModel, hash: String, size: Int64,
                         version: StratovoVersion? = nil, privateBuild: Int? = nil,
                         download: () async throws -> Data) async {
        guard !busy, !model.busy, !model.running, !model.graphicsLab.active else {
            status = L10n.text("Bitte zuerst alle Gäste und den Grafikbau beenden."); return
        }
        guard let storage = model.storage, model.storageReady else {
            status = L10n.text("Datenordner nicht erreichbar"); return
        }
        busy = true; model.setGraphicsLabBusy(true)
        defer { busy = false; model.setGraphicsLabBusy(false) }
        do {
            try storage.validate()
            let current = Bundle.main.bundleURL.standardizedFileURL
            guard current.pathExtension == "app", current.lastPathComponent == "Stratovo.app",
                  current.resolvingSymlinksInPath() == current,
                  FileManager.default.isWritableFile(atPath: current.deletingLastPathComponent().path) else {
                throw PrivateUpdateAPI.failure("Kopiere Stratovo zunächst in einen beschreibbaren Programme-Ordner und starte sie von dort.")
            }
            // launchd can reject job files on volumes that do not enforce ownership.
            let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                .appendingPathComponent("Stratovo-update-" + UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            status = L10n.text("Update wird von GitHub geladen …")
            let data = try await download()
            status = L10n.text("Prüfsumme und App werden geprüft …")
            let prepared = try await Task.detached {
                try UpdatePackagePreparer.prepare(data: data, sha256: hash, size: size, directory: directory,
                                                 version: version, privateBuild: privateBuild)
            }.value
            try storage.validate()
            guard !model.running, !model.graphicsLab.active else { throw PrivateUpdateAPI.failure("Bitte alle Gäste vor dem Update beenden.") }
            guard let helper = Bundle.main.url(forResource: "install-update", withExtension: "sh") else { throw PrivateUpdateAPI.failure("Update-Helfer fehlt.") }
            let helperCopy = directory.appendingPathComponent("install-update.sh")
            try FileManager.default.copyItem(at: helper, to: helperCopy)
            let log = directory.appendingPathComponent("Installation.log")
            let label = "org.pwnedg0blin.stratovo.update." + UUID().uuidString
            let domain = "gui/\(getuid())"
            let job = directory.appendingPathComponent("install-update.plist")
            let configuration: [String: Any] = [
                "Label": label,
                "ProgramArguments": ["/bin/bash", helperCopy.path,
                    String(ProcessInfo.processInfo.processIdentifier), current.path, prepared.path,
                    directory.path, label],
                "RunAtLoad": true,
                "KeepAlive": false,
                "AbandonProcessGroup": true,
                "StandardOutPath": log.path,
                "StandardErrorPath": log.path
            ]
            let jobData = try PropertyListSerialization.data(fromPropertyList: configuration, format: .xml, options: 0)
            try jobData.write(to: job, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: job.path)
            let expectedBuild = Bundle(url: prepared)?.object(forInfoDictionaryKey: "CFBundleVersion") as? String
            let ready = directory.appendingPathComponent("ready")
            let failed = directory.appendingPathComponent("failed")
            do {
                let result = try await Task.detached {
                    try CommandCapture.run(CommandSpec(executable: "/bin/launchctl",
                        arguments: ["bootstrap", domain, job.path]), timeout: 12)
                }.value
                guard result.status == 0 else {
                    let diagnostic = "launchctl bootstrap (Exit \(result.status))\n\(result.output)"
                    try? Data(diagnostic.utf8).write(to: directory.appendingPathComponent("Launchctl.log"), options: .atomic)
                    throw PrivateUpdateAPI.failure("Update-Helfer konnte nicht gestartet werden. Updateordner: \(directory.path)")
                }
                var confirmed = false
                for _ in 0..<300 {
                    try Task.checkCancellation()
                    if FileManager.default.fileExists(atPath: failed.path) { break }
                    if let value = try? String(contentsOf: ready, encoding: .utf8),
                       value.trimmingCharacters(in: .whitespacesAndNewlines) == expectedBuild {
                        confirmed = true
                        break
                    }
                    try await Task.sleep(nanoseconds: 100_000_000)
                }
                guard confirmed, !model.running, !model.graphicsLab.active else {
                    throw PrivateUpdateAPI.failure("Update-Helfer hat die Übergabe nicht bestätigt. Protokoll: \(log.path)")
                }
                try Data("install".utf8).write(to: directory.appendingPathComponent("commit"), options: .atomic)
            } catch {
                _ = try? await Task.detached {
                    try CommandCapture.run(CommandSpec(executable: "/bin/launchctl",
                        arguments: ["bootout", domain + "/" + label]), timeout: 5)
                }.value
                throw error
            }
            status = L10n.text("Update geprüft. Stratovo wird ausgetauscht und neu gestartet …")
            model.setGraphicsLabBusy(false)
            NSApplication.shared.terminate(nil)
        } catch {
            // Download errors may contain signed URLs; never display or log them.
            status = (error as NSError).domain == "Stratovo.PrivateUpdates"
                ? error.localizedDescription : "Update fehlgeschlagen. Prüfe Internetverbindung und Datenlaufwerk. Die bisherige App bleibt erhalten."
        }
    }
}
