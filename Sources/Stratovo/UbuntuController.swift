import AppKit
import Foundation
import Combine
import StratovoCore

@MainActor
final class UbuntuController: ObservableObject {
    @Published private(set) var downloading = false
    @Published private(set) var isoReady = false
    @Published private(set) var diskReady = false
    @Published private(set) var status = "Ubuntu noch nicht eingerichtet"

    func refresh(model: AppModel) {
        guard let root = model.storage?.url.appendingPathComponent("Ubuntu") else { return }
        isoReady = FileManager.default.fileExists(atPath: root.appendingPathComponent("ubuntu-26.04.1-desktop-arm64.iso").path)
        diskReady = FileManager.default.fileExists(atPath: root.appendingPathComponent("ubuntu.qcow2").path)
    }
    func resetAfterRemoval(model: AppModel) {
        status = L10n.text("Ubuntu noch nicht eingerichtet")
        refresh(model: model)
    }
    func download(model: AppModel) {
        guard !model.running, !model.busy, !downloading, let storage = model.storage,
              let helper = Bundle.main.resourceURL?.appendingPathComponent("GraphicsLab/ubuntu_vm.py") else { return }
        downloading = true; model.setGraphicsLabBusy(true)
        status = L10n.text("Ubuntu 26.04.1 LTS ARM64 wird geladen und geprüft …")
        Task {
            defer { downloading = false; model.setGraphicsLabBusy(false); refresh(model: model) }
            do {
                try storage.validate()
                let config = try Self.configuration(storage: storage)
                let result = try await Task.detached {
                    try CommandCapture.run(CommandSpec(executable: "/usr/bin/python3", arguments: [helper.path,
                        "--config", config.path, "download"]), timeout: 7200)
                }.value
                guard result.status == 0 else { throw GuestError.commandFailed(result.status, result.output) }
                status = L10n.text("Ubuntu geladen und SHA-256-geprüft · jetzt installieren")
            } catch { status = error.localizedDescription }
        }
    }
    static func configuration(storage: GuestStorage, extra: [String: Any] = [:]) throws -> URL {
        let root = storage.url.appendingPathComponent("Ubuntu")
        guard root.standardizedFileURL == root.resolvingSymlinksInPath() else { throw GuestError.invalidResources }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = root.appendingPathComponent("config.json")
        guard ((try? FileManager.default.attributesOfItem(atPath: file.path))?[.type] as? FileAttributeType) != .typeSymbolicLink else { throw GuestError.invalidResources }
        let data = ["root": storage.root, "storageID": storage.id] as [String: Any]
        try JSONSerialization.data(withJSONObject: data.merging(extra) { _, new in new }).write(to: file, options: .atomic)
        return file
    }
}

