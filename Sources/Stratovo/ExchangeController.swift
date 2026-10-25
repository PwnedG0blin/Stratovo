import AppKit
import Combine
import StratovoCore

@MainActor
final class ExchangeController: ObservableObject {
    @Published private(set) var transferring = false
    @Published private(set) var status = ""
    private var transferTask: Task<Void, Never>?
    let windowsSSH = GuestFileExchangeController(kind: .windows)
    let ubuntuSSH = GuestFileExchangeController(kind: .ubuntu)
    func cancelTransfer() {
        transferTask?.cancel()
        windowsSSH.cancel(disconnect: true); ubuntuSSH.cancel(disconnect: true)
    }

    func openFinder(model: AppModel) {
        do {
            guard let storage = model.storage else { return }
            NSWorkspace.shared.open(try ExchangeFolder.prepare(storage: storage))
        } catch { status = error.localizedDescription }
    }

    func openSharingSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Sharing-Settings.extension")!)
    }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        status = L10n.text("Adresse kopiert")
    }

    private func run(adb: String, port: Int, storage: GuestStorage, arguments: [String]) async throws {
        try Task.checkCancellation()
        let result = try await Task.detached(priority: .utility) {
            try storage.validate()
            return try CommandCapture.run(CommandSpec(executable: adb, arguments: ["-s", "emulator-\(port)"] + arguments,
                environment: storage.environment), timeout: 7200)
        }.value
        try Task.checkCancellation()
        guard result.status == 0 else { throw StorageMigration.failure("Dateiübertragung fehlgeschlagen: " + result.output) }
    }

    func sendAndroid(model: AppModel) {
        guard !transferring, !model.busy, model.running, model.activeGuest == "android", model.androidBooted,
              let adb = model.adb, let port = model.androidExchangePort, let storage = model.storage else { return }
        let panel = NSOpenPanel()
        panel.title = L10n.text("Datei zu Android senden")
        panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        do { panel.directoryURL = try ExchangeFolder.prepare(storage: storage) }
        catch { status = error.localizedDescription; return }
        guard panel.runModal() == .OK, let file = panel.url else { return }
        transferring = true; model.setGraphicsLabBusy(true)
        status = L10n.text("Datei wird zu Android kopiert …")
        let remote = ExchangeFolder.androidDirectory + "/" + UUID().uuidString
        transferTask = Task {
            defer { transferring = false; transferTask = nil; if model.activeGuest == "android" { model.setGraphicsLabBusy(false) } }
            do {
                try await run(adb: adb, port: port, storage: storage, arguments: ["shell", "mkdir", "-p", remote])
                try await run(adb: adb, port: port, storage: storage, arguments: ["push", file.path, remote + "/"])
                status = L10n.text("Datei kopiert: Android → Downloads → Stratovo-Austausch. Jede Übertragung erhält einen eigenen Unterordner.")
            } catch { status = error.localizedDescription }
        }
    }

    func receiveAndroid(model: AppModel) {
        guard !transferring, !model.busy, model.running, model.activeGuest == "android", model.androidBooted,
              let adb = model.adb, let port = model.androidExchangePort, let storage = model.storage else { return }
        transferring = true; model.setGraphicsLabBusy(true)
        status = L10n.text("Android-Dateien werden abgeholt …")
        transferTask = Task {
            defer { transferring = false; transferTask = nil; if model.activeGuest == "android" { model.setGraphicsLabBusy(false) } }
            do {
                let target = try ExchangeFolder.newAndroidImport(storage: storage)
                try await run(adb: adb, port: port, storage: storage,
                              arguments: ["shell", "mkdir", "-p", ExchangeFolder.androidDirectory])
                try await run(adb: adb, port: port, storage: storage,
                              arguments: ["pull", ExchangeFolder.androidDirectory, target.path])
                status = L10n.text("Android-Dateien in einen neuen Importordner kopiert. Vorhandene Dateien bleiben erhalten.")
                NSWorkspace.shared.open(target)
            } catch { status = error.localizedDescription }
        }
    }
}


