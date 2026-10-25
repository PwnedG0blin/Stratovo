import AppKit
import Combine
import Darwin
import Foundation
import UniformTypeIdentifiers
import StratovoCore

struct AppSettings: Codable {
    var sdk = ""
    var qemu = ""
    var firmware = ""
    var swtpm = ""
    var iso = ""
    var driversISO = ""
    var installWindows = true
    var selectPro = true
    var localWindowsAccount = true
    var localWindowsUser = "Benutzer"
    var windowsNetwork = false
    var selectedAVD = ""
    var memoryGB = 4
    var cores = 4
    var coldBoot = false
    var gpu = "auto"

    static func load() -> AppSettings {
        guard let data = UserDefaults.standard.data(forKey: "OpenGuest.settings"),
              let decoded = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return decoded
    }
    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: "OpenGuest.settings") }
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var settings = AppSettings.load() { didSet { settings.save() } }
    @Published var androidProfile = AndroidPerformance(rawValue: UserDefaults.standard.string(forKey: "Pixelkoje.androidProfile") ?? "smooth") ?? .smooth {
        didSet { UserDefaults.standard.set(androidProfile.rawValue, forKey: "Pixelkoje.androidProfile") }
    }
    private let frameRateDefaults: UserDefaults
    @Published private var storedAndroidTargetFPS: Int
    // Keep validation outside a @Published didSet: assigning the wrapped
    // property from its own observer re-enters the setter through Combine.
    var androidTargetFPS: Int {
        get { storedAndroidTargetFPS }
        set {
            let value = AndroidFrameRate.limit(newValue)
            guard value != storedAndroidTargetFPS else { return }
            storedAndroidTargetFPS = value
            frameRateDefaults.set(value, forKey: "Pixelkoje.androidFPS")
        }
    }
    @Published var androidOutputMode: AndroidOutputMode {
        didSet { frameRateDefaults.set(androidOutputMode.rawValue, forKey: "Stratovo.androidOutputMode") }
    }
    @Published private(set) var activeAndroidOutputMode: AndroidOutputMode?
    @Published private(set) var androidWindowStatus = ""
    var androidUsesDirectDisplay: Bool {
        running && activeGuest == "android" && activeAndroidOutputMode == .direct
    }
    func guestWindowButtonTitle(kind: String) -> String {
        L10n.text(kind == "android" && androidUsesDirectDisplay ? "Android-Fenster öffnen" : "Player öffnen")
    }
    @Published private(set) var androidGuestRefreshHz = 60
    @Published var androidStreamQuality = AndroidStreamQuality(rawValue: UserDefaults.standard.string(forKey: "Stratovo.androidStreamQuality") ?? "sharp") ?? .sharp {
        didSet { UserDefaults.standard.set(androidStreamQuality.rawValue, forKey: "Stratovo.androidStreamQuality") }
    }
    @Published private(set) var appliedAndroidStreamQuality: AndroidStreamQuality?
    @Published private(set) var appliedAndroidTargetFPS: Int?

    @Published private(set) var androidRendererStatus = L10n.text("Grafikrenderer wird beim Android-Start geprüft")
    @Published private(set) var androidSoftwareRendering = false
    @Published private(set) var androidDisplayStatus = L10n.text("Leistungsprofil wird nach dem Android-Start angewendet")
    @Published var androidCustomDisplay = UserDefaults.standard.bool(forKey: "Pixelkoje.androidCustomDisplay") {
        didSet { UserDefaults.standard.set(androidCustomDisplay, forKey: "Pixelkoje.androidCustomDisplay") }
    }
    @Published var androidDisplayWidth = UserDefaults.standard.string(forKey: "Pixelkoje.androidWidth") ?? "720" {
        didSet { UserDefaults.standard.set(androidDisplayWidth, forKey: "Pixelkoje.androidWidth") }
    }
    @Published var androidDisplayHeight = UserDefaults.standard.string(forKey: "Pixelkoje.androidHeight") ?? "1600" {
        didSet { UserDefaults.standard.set(androidDisplayHeight, forKey: "Pixelkoje.androidHeight") }
    }
    @Published var androidDisplayDensity = UserDefaults.standard.string(forKey: "Pixelkoje.androidDensity") ?? "280" {
        didSet { UserDefaults.standard.set(androidDisplayDensity, forKey: "Pixelkoje.androidDensity") }
    }
    @Published private(set) var androidDisplayBusy = false
    func selectGalaxyS26UltraDisplay() {
        guard canEditAndroidDisplay else { return }
        androidDisplayWidth = "1440"; androidDisplayHeight = "3120"; androidDisplayDensity = "500"
        androidCustomDisplay = true
        androidDisplayStatus = L10n.text("S26-Ultra-Displayprofil gewählt · 1440 × 3120 · 500 dpi. Jetzt anwenden oder Android neu starten.")
        UserDefaults.standard.set(true, forKey: "Pixelkoje.playerFit.android")
    }
    private func requestedAndroidDisplay() throws -> AndroidCustomDisplay? {
        guard androidCustomDisplay else { return nil }
        guard let w = Int(androidDisplayWidth.trimmingCharacters(in: .whitespacesAndNewlines)),
              let h = Int(androidDisplayHeight.trimmingCharacters(in: .whitespacesAndNewlines)),
              let dpi = Int(androidDisplayDensity.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw GuestError.commandFailed(1, L10n.text("Bitte Breite, Höhe und Dichte als ganze Zahlen eingeben."))
        }
        return try AndroidCustomDisplay(width: w, height: h, density: dpi)
    }
    var androidDisplayIssue: String? {
        do { _ = try requestedAndroidDisplay(); return nil } catch { return error.localizedDescription }
    }
    var canEditAndroidDisplay: Bool { !busy && !androidDisplayBusy && (!running || (activeGuest == "android" && androidBooted)) }
    var canApplyAndroidDisplay: Bool { canEditAndroidDisplay && running && activeGuest == "android" && androidBooted && androidDisplayIssue == nil }
    func applyAndroidDisplayNow() async {
        guard canApplyAndroidDisplay, storageReady, let port = androidPort else { return }
        androidDisplayBusy = true
        defer { androidDisplayBusy = false }
        await applyAndroidDisplay(port: port)
    }
    func restoreAndroidDisplay() async {
        guard canEditAndroidDisplay else { return }
        androidCustomDisplay = false; androidProfile = .native
        if canApplyAndroidDisplay { await applyAndroidDisplayNow() }
        else { androidDisplayStatus = L10n.text("Originalauflösung wird beim nächsten Android-Start wiederhergestellt.") }
    }
    @Published private(set) var decoderFPS = 0.0
    @Published private(set) var decoderRecoveries = 0

    @Published private(set) var devices: [AndroidDevice] = []
    @Published private(set) var sdk: String?
    @Published private(set) var qemu: String?
    let graphicsLab = WindowsGraphicsLabController()
    @Published var windowsLabSelected = true
    let ubuntu = UbuntuController()
    let exchange = ExchangeController()
    var androidExchangePort: Int? { androidPort }
    func setGraphicsLabBusy(_ active: Bool) { busy = active }
    func recordGraphicsLabEvent(_ text: String) { recordDiagnostic("Experimentelles Grafiklabor", text) }
    @Published private(set) var firmware: String?
    @Published private(set) var swtpm: String?
    @Published private(set) var qemuImg: String?
    @Published private(set) var variablesTemplate: String?
    @Published private(set) var androidAcceleration = L10n.text("Noch nicht geprüft")
    @Published private(set) var windowsAcceleration = L10n.text("Noch nicht geprüft")
    @Published private(set) var windowsISOReady = false
    @Published private(set) var windowsISODetail = L10n.text("Noch keine Installations-DVD ausgewählt")
    @Published private(set) var windowsBootMediaStatus = L10n.text("DVD-Verbindung wird nach dem Start direkt bei QEMU geprüft")
    @Published private(set) var windowsIdentity: WindowsMachineIdentity?
    @Published private(set) var windowsIdentityStatus = L10n.text("Gerätekennung noch nicht geprüft")
    @Published private(set) var windowsIdentityCanRestore = false
    @Published private(set) var windowsISOHashStatus = L10n.text("Originalität der ISO noch nicht geprüft")
    @Published private(set) var windowsISOHashDigest = ""
    private var hashedISOPath = ""
    @Published var windowsGraphics: WindowsGraphics = .basic { didSet { saveWindowsDisplayChoice() } }
    @Published var windowsResolution: WindowsDisplayMode = .fullHD { didSet { saveWindowsDisplayChoice() } }
    private var loadingWindowsDisplay = false
    private func saveWindowsDisplayChoice() {
        guard !loadingWindowsDisplay, let storage else { return }
        UserDefaults.standard.set(windowsGraphics.rawValue, forKey: "Pixelkoje.windowsGraphics.\(storage.id)")
        UserDefaults.standard.set(windowsResolution.rawValue, forKey: "Pixelkoje.windowsResolution.\(storage.id)")
    }
    private func loadWindowsDisplayChoice() {
        guard let storage else { return }
        loadingWindowsDisplay = true
        defer { loadingWindowsDisplay = false }
        windowsGraphics = WindowsGraphics(rawValue: UserDefaults.standard.string(forKey: "Pixelkoje.windowsGraphics.\(storage.id)") ?? "") ?? .basic
        windowsResolution = WindowsDisplayMode(rawValue: UserDefaults.standard.string(forKey: "Pixelkoje.windowsResolution.\(storage.id)") ?? "") ?? .fullHD
    }
    @Published private(set) var androidPasteStatus = ""
    @Published private(set) var androidRepairStatus = ""
    var canRepairAndroidConnection: Bool { storageReady && adb != nil && !running && !busy }
    func repairAndroidConnection() async {
        guard canRepairAndroidConnection, let adb, let storage else { return }
        busy = true
        androidRepairStatus = L10n.text("Android-Verbindung wird repariert …")
        defer { busy = false }
        do {
            try storage.validate()
            for action in ["kill-server", "start-server"] {
                let result = try await Self.capture(CommandSpec(executable: adb, arguments: [action], environment: storage.environment), timeout: 15)
                guard result.status == 0 else { throw GuestError.commandFailed(result.status, result.output) }
            }
            settings.coldBoot = true
            androidRepairStatus = L10n.text("ADB neu gestartet · Kaltstart aktiviert. Jetzt Android starten.")
            recordDiagnostic(L10n.text("Android · Verbindung repariert"), L10n.text("ADB-Dienst auf ausdrücklichen Wunsch neu gestartet; Kaltstart aktiviert. Keine Gastdaten gelöscht."))
        } catch {
            androidRepairStatus = "Reparatur fehlgeschlagen: " + error.localizedDescription
            recordDiagnostic(L10n.text("Android · Verbindungsreparatur"), androidRepairStatus)
        }
    }
    @discardableResult
    func pasteAndroidText(_ input: AndroidClipboardText) async -> Bool {
        guard running, activeGuest == "android", androidBooted, !busy, let stream = androidStream else {
            androidPasteStatus = L10n.text("Android-Eingabeverbindung noch nicht bereit."); return false
        }
        do {
            try await stream.paste(input)
            androidPasteStatus = L10n.text("Text an Android gesendet. Das Eingabefeld muss im Gast aktiv sein.")
            return true
        } catch {
            // Clipboard contents and errors containing payload are never logged.
            androidPasteStatus = L10n.text("Text konnte nicht übertragen werden. Android-Verbindung prüfen und erneut versuchen.")
            return false
        }
    }
    func openWindowsDriverDisc() {
        if windowsPlayer == nil { sendWindowsKeys(["meta_l", "e"]); return }
        guard running, ["windows", "ubuntu"].contains(activeGuest), !windowsPasteBusy,
              windowsPlayer?.sendKeySequence(WindowsKeyboard.explorer) == true else { return }
        playerStatus = L10n.text("Windows-Explorer angefordert · Unter Dieser PC die eingelegte Treiber-CD öffnen.")
    }

    func refreshWindowsIdentity() {
        guard let storage, storageReady else { windowsIdentity = nil; windowsIdentityCanRestore = false; return }
        do {
            let saved = try WindowsIdentityStore.load(root: storage.windows)
            windowsIdentity = saved ?? (FileManager.default.fileExists(atPath: storage.windows.appendingPathComponent("windows.qcow2").path) ? .legacy : nil)
            windowsIdentityStatus = windowsIdentity?.summary ?? "Neue Windows-VM: eigene UUID, Seriennummer und MAC werden vor dem ersten Start gespeichert."
            windowsIdentityCanRestore = try WindowsIdentityStore.canRestore(root: storage.windows)
        } catch {
            windowsIdentity = nil; windowsIdentityCanRestore = false
            windowsIdentityStatus = "Gerätekennung nicht lesbar: " + error.localizedDescription
        }
    }
    func changeWindowsIdentity(restore: Bool = false) async {
        guard !running, !busy, let storage, storageReady else { return }
        busy = true
        defer { busy = false }
        do {
            let value = try await Task.detached(priority: .utility) {
                try WindowsIdentityStore.useUnique(storage: storage, restore: restore)
            }.value
            refreshWindowsIdentity()
            windowsIdentityStatus = (restore ? "Ursprüngliche Kennung wiederhergestellt. " : "Eigene Kennung gespeichert. ") + value.summary
            // Resume the existing OS; changing hardware is not a request to reinstall Windows.
            settings.installWindows = false
            recordDiagnostic("Windows · Gerätekennung", windowsIdentityStatus)
        } catch { errorMessage = error.localizedDescription }
    }
    func verifyWindowsISO() async {
        guard !running, !busy, storageReady, windowsISOReady else { return }
        busy = true
        let path = settings.iso
        hashedISOPath = path
        windowsISOHashDigest = ""
        windowsISOHashStatus = L10n.text("SHA-256 wird berechnet. Die vorhandene ISO wird nur gelesen …")
        defer { busy = false }
        do {
            let result = try await Task.detached(priority: .utility) { try WindowsISOHash.calculate(path: path) }.value
            guard settings.iso == path else { return }
            windowsISOHashDigest = result.sha256
            let checkedAt = DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .short)
            let detail = result.matchesMicrosoftGerman26H2
                ? L10n.text("Original bestätigt: Microsoft Windows 11 26H2 · ARM64 · Deutsch. SHA-256 stimmt überein.")
                : L10n.text("Kein Treffer für Microsoft Windows 11 26H2 ARM64 Deutsch. Andere Version/Sprache oder eine veränderte Datei möglich. Das allein beweist keine Beschädigung.")
            windowsISOHashStatus = L10n.message("Prüfergebnis vom \(checkedAt): ") + detail
            recordDiagnostic("Windows · ISO-Prüfsumme", windowsISOHashStatus + " SHA-256: " + result.sha256)
        } catch {
            windowsISOHashStatus = "Prüfsumme nicht ermittelt: " + error.localizedDescription
            recordDiagnostic("Windows · ISO-Prüfsumme", windowsISOHashStatus)
        }
    }
    @Published var windowsTextLayout = WindowsTextLayout(rawValue: UserDefaults.standard.string(forKey: "Pixelkoje.windowsTextLayout") ?? "german") ?? .german {
        didSet { UserDefaults.standard.set(windowsTextLayout.rawValue, forKey: "Pixelkoje.windowsTextLayout") }
    }
    @Published private(set) var windowsPasteBusy = false
    @Published private(set) var windowsPasteStatus = ""
    func refreshWindowsISO() {
        if hashedISOPath != settings.iso {
            hashedISOPath = settings.iso
            windowsISOHashDigest = ""
            windowsISOHashStatus = L10n.text("Originalität der ISO noch nicht geprüft")
        }
        do {
            let info = try WindowsISOInfo.check(path: settings.iso)
            windowsISOReady = true
            windowsISODetail = "ISO-Datei lesbar · " + ByteCountFormatter.string(fromByteCount: info.bytes, countStyle: .file)
        } catch {
            windowsISOReady = false
            windowsISODetail = settings.iso.isEmpty ? L10n.text("Keine DVD-ISO ausgewählt") : error.localizedDescription
        }
    }
    func chooseWindowsISO() {
        guard !running, !busy else { return }
        let panel = NSOpenPanel()
        panel.title = L10n.text("Windows-ARM64-ISO als Installations-DVD auswählen")
        panel.prompt = "Als DVD verwenden"
        panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType(filenameExtension: "iso") ?? .data]
        if !settings.iso.isEmpty { panel.directoryURL = URL(fileURLWithPath: settings.iso).resolvingSymlinksInPath().deletingLastPathComponent() }
        else if let storage { panel.directoryURL = storage.url.appendingPathComponent("Installationsmedien") }
        if panel.runModal() == .OK, let url = panel.url {
            settings.iso = url.path
            settings.installWindows = true
            refreshWindowsISO()
        }
    }

    @Published private(set) var windowsFolderStatus = L10n.text("Windows-Ordner noch nicht geprüft.")
    @Published var windowsDiskSize = "80" {
        didSet {
            if let storage, let value = try? WindowsDisk.capacityGiB(windowsDiskSize) {
                UserDefaults.standard.set(value, forKey: "OpenGuest.windowsDiskGiB.\(storage.id)")
            }
        }
    }
    @Published private(set) var windowsDiskBytes: Int64?
    @Published private(set) var windowsDiskStatus = L10n.text("Größe für die virtuelle Windows-Festplatte wählen.")
    var windowsCapacityGiB: Int? { try? WindowsDisk.capacityGiB(windowsDiskSize) }
    var windowsCapacityIssue: String? {
        do {
            let value = try WindowsDisk.capacityGiB(windowsDiskSize)
            if let current = windowsDiskBytes { _ = try WindowsDisk.requiresGrowth(currentBytes: current, requestedGiB: value) }
            return nil
        } catch { return error.localizedDescription }
    }
    func applyWindowsDiskSize() async {
        guard !busy, !running, let storage, storageReady, let qemuImg else { return }
        do {
            let value = try WindowsDisk.capacityGiB(windowsDiskSize)
            busy = true
            defer { busy = false }
            let bytes = try await Task.detached {
                try WindowsDiskImage.prepare(qemuImg: qemuImg, storage: storage, capacityGiB: value)
            }.value
            windowsDiskBytes = bytes
            windowsDiskStatus = L10n.message("Virtuelle Festplatte: \(value) GB. Zusätzlichen Speicher nach einer Vergrößerung in Windows zuordnen.")
            recordDiagnostic("Windows · Festplatte", L10n.message("Größe angewendet: \(value) GB"))
        } catch { windowsDiskStatus = error.localizedDescription; errorMessage = error.localizedDescription }
    }
    func prepareWindowsFolder() {
        guard !busy, !running, let storage else { return }
        do {
            try storage.prepareWindowsFolder()
            windowsFolderStatus = "Windows-Ordner vorhanden und beschreibbar."
            recordDiagnostic("Windows · Datenordner", L10n.message("Angelegt / geprüft: \(storage.windows.path)"))
        } catch { windowsFolderStatus = error.localizedDescription; errorMessage = error.localizedDescription }
    }
    func revealWindowsFolder() {
        guard let storage, storage.windowsFolderReady else { return }
        NSWorkspace.shared.open(storage.windows)
    }
    @Published private(set) var androidReady = false
    @Published private(set) var windowsReady = false
    @Published private(set) var busy = false
    @Published private(set) var running = false
    @Published private(set) var androidBooted = false
    @Published private(set) var apkBusy = false
    @Published private(set) var apkStatus = ""
    @Published private(set) var sessionName = L10n.text("Kein Gast gestartet")
    @Published private(set) var log = L10n.text("Stratovo 1.0 Beta 1\nSystem prüfen, dann einen Gast auswählen.").replacingOccurrences(of: "1.0 Beta 1", with: "1.0 Beta 6")
    @Published private(set) var lastCommand = ""
    @Published var errorMessage: String? {
        didSet {
            if let message = errorMessage, message != oldValue { recordDiagnostic(L10n.text("Fehler"), message) }
        }
    }
    @Published private(set) var diagnosticBusy = false
    @Published private(set) var diagnosticStatus = ""
    private var diagnosticEvents: [String] = []
    private var systemCheckLog = ""
    private func recordDiagnostic(_ category: String, _ message: String) {
        let event = DiagnosticReport.redact("\(category): \(message)")
        diagnosticEvents.append(event)
        if diagnosticEvents.count > 100 { diagnosticEvents.removeFirst(diagnosticEvents.count - 100) }
        if let storage { try? DiagnosticReport.record(event, storage: storage) }
    }
    func exportDiagnostics() async {
        guard !diagnosticBusy, let storage, storageReady else {
            if !storageReady { errorMessage = L10n.text("Für den Diagnoseexport bitte den gewählten Datenträger anschließen.") }
            return
        }
        diagnosticBusy = true
        diagnosticStatus = L10n.text("Android- und Windows-Protokolle werden zusammengeführt …")
        defer { diagnosticBusy = false }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Entwicklung"
        let snapshot = """
        Version: \(version)
        macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)
        Mac: \(supportedHost ? "Apple Silicon nativ" : "Nicht unterstützt / Rosetta") · \(totalMemoryGB) GB · \(hostCores) CPU-Kerne
        Datenordner: \(storage.root) · \(storageFree)
        Gast: \(activeGuest.isEmpty ? "Keiner" : activeGuest) · \(sessionName)
        Android: \(androidAcceleration)
        Android-Profil: \(settings.selectedAVD)
        Leistungsprofil: \(androidProfile.rawValue) · Gewähltes Ziel: \(androidTargetFPS) FPS · Aktives Limit: \(appliedAndroidTargetFPS.map(String.init) ?? "—")
        Streamqualität: \(appliedAndroidStreamQuality?.rawValue ?? "Nicht verbunden") · Gewählt: \(androidStreamQuality.rawValue)
        Empfangenes Bild: \(Int(playerSize.width)) × \(Int(playerSize.height)) px
        Android-Ausgabe: \(activeAndroidOutputMode?.rawValue ?? "Nicht gestartet") · nächster Start: \(androidOutputMode.rawValue)
        Android-Bildschirm: \(androidDisplayStatus)
        Android-Grafikrenderer: \(androidRendererStatus)
        Decoder-Zuführung: \(Int(decoderFPS.rounded())) FPS · Wiederanläufe: \(decoderRecoveries) · verworfene verspätete Frames: \(androidDroppedFrames)
        Grafik gewählt: \(settings.gpu) · RAM: \(settings.memoryGB) GB · CPU: \(settings.cores)
        Player: \(playerStatus) · Video-Frames/s: \(Int(streamFPS.rounded()))
        Windows: \(windowsAcceleration)
        Windows-Player-Bilder: \(windowsFrameCount)
        Windows-Ordner: \(windowsFolderStatus)
        Gewünschte Windows-Festplatte: \(windowsDiskSize) GB · Geprüfte Größe in Bytes: \(windowsDiskBytes.map { String($0) } ?? "Noch nicht ermittelt")
        Festplattenstatus: \(windowsDiskStatus)
        Windows-Gerätekennung: \(windowsIdentityStatus)
        ISO-Prüfsumme: \(windowsISOHashStatus) · \(windowsISOHashDigest)
        Windows-Einrichtung: \(settings.installWindows) · lokales Konto: \(settings.localWindowsAccount)
        Benutzername-Länge: \(settings.localWindowsUser.count)
        Kennwortlänge: \(localPassword.count) · Wiederholungslänge: \(localPasswordConfirmation.count) · Übereinstimmung: \(localPassword == localPasswordConfirmation)
        Kontoprüfung (nur Eingabefelder): \(localAccountIssue ?? "Gültig")
        Kennwort merken: \(rememberWindowsCredential)
        Schlüsselbund-Status: \(credentialStatus)
        SDK: \(sdk ?? "Fehlt")
        QEMU: \(qemu ?? "Fehlt")
        swtpm: \(swtpm ?? "Fehlt")
        Firmware: \(firmware ?? "Fehlt")
        Windows-ISO: \(settings.iso)
        DVD-Dateiprüfung: \(windowsISODetail)
        DVD bei QEMU: \(windowsBootMediaStatus)
        Treiber-ISO: \(settings.driversISO)
        Letzte Meldung: \(errorMessage ?? "Keine")
        """
        let check = systemCheckLog
        let events = diagnosticEvents.joined(separator: "\n")
        do {
            let file = try await Task.detached(priority: .utility) {
                try DiagnosticReport.export(storage: storage, snapshot: snapshot, systemCheck: check, recentEvents: events)
            }.value
            diagnosticStatus = "Gemeinsames Protokoll erstellt: \(file.lastPathComponent)"
            NSWorkspace.shared.activateFileViewerSelecting([file])
        } catch { diagnosticStatus = "Diagnoseexport fehlgeschlagen."; errorMessage = error.localizedDescription }
    }
    @Published private(set) var storage = GuestStorage.load()
    @Published var showStorageSetup = GuestStorage.load() == nil
    @Published var proposedStoragePath = ""
    @Published private(set) var storageStatus = L10n.text("Wähle einen Datenordner, bevor Android oder Windows eingerichtet wird.")
    @Published private(set) var backupPaths: [String] = []
    @Published var storageTested = false
    var storageReady: Bool { guard let storage else { return false }; return (try? storage.validate()) != nil }
    var storageFree: String {
        guard let bytes = storage?.freeBytes, storageReady else { return L10n.text("Speicherort nicht erreichbar") }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) + " frei"
    }
    @Published var localPassword = ""
    @Published var localPasswordConfirmation = ""
    @Published var rememberWindowsCredential = UserDefaults.standard.object(forKey: "Pixelkoje.rememberWindowsCredential") as? Bool ?? true {
        didSet { UserDefaults.standard.set(rememberWindowsCredential, forKey: "Pixelkoje.rememberWindowsCredential") }
    }
    @Published private(set) var credentialStatus = L10n.text("Schlüsselbund noch nicht geprüft. Vorhandene Kontodaten können geladen werden.")
    private func persistWindowsCredential(_ account: WindowsEdition.LocalAccount, storage: GuestStorage) async throws {
        let credential = WindowsSetupKeychain.Credential(name: account.name, password: account.password)
        do {
            try await Task.detached { try WindowsSetupKeychain.save(credential, storageID: storage.id) }.value
            credentialStatus = L10n.text("Benutzername und Kennwort im macOS-Schlüsselbund gespeichert und durch erneutes Lesen geprüft.")
            recordDiagnostic(L10n.text("Windows · Schlüsselbund"), L10n.text("Speichern und Leseprüfung erfolgreich"))
        } catch {
            credentialStatus = error.localizedDescription
            throw error
        }
    }
    private func restoreWindowsCredentialSilently() async {
        guard rememberWindowsCredential, localPassword.isEmpty, localPasswordConfirmation.isEmpty,
              let storage, storageReady else { return }
        do {
            if let credential = try await Task.detached(operation: {
                try WindowsSetupKeychain.load(storageID: storage.id, allowInteraction: false)
            }).value {
                settings.localWindowsUser = credential.name
                localPassword = credential.password
                localPasswordConfirmation = credential.password
                credentialStatus = L10n.text("Benutzername und Kennwort aus dem macOS-Schlüsselbund wiederhergestellt.")
            } else { credentialStatus = L10n.text("Für diesen Datenordner sind noch keine Kontodaten im Schlüsselbund gespeichert.") }
        } catch { credentialStatus = error.localizedDescription }
        recordDiagnostic(L10n.text("Windows · Schlüsselbund"), credentialStatus)
    }
    var localAccountIssue: String? {
        do {
            _ = try WindowsEdition.validateSetupAccount(name: settings.localWindowsUser, password: localPassword,
                                                       confirmation: localPasswordConfirmation)
            return nil
        } catch { return error.localizedDescription }
    }
    func saveWindowsCredential() async {
        guard !busy, !running, let storage, storageReady else { return }
        do {
            recordDiagnostic(L10n.text("Windows · Schlüsselbund speichern"), "Benutzername-Länge \(settings.localWindowsUser.count), Kennwortlänge \(localPassword.count), Wiederholungslänge \(localPasswordConfirmation.count), Übereinstimmung \(localPassword == localPasswordConfirmation)")
            let account = try WindowsEdition.validateSetupAccount(name: settings.localWindowsUser,
                password: localPassword, confirmation: localPasswordConfirmation)
            busy = true
            defer { busy = false }
            try await persistWindowsCredential(account, storage: storage)
        } catch { errorMessage = error.localizedDescription }
    }
    func loadWindowsCredential() async {
        guard !busy, !running, let storage, storageReady else { return }
        busy = true
        defer { busy = false }
        do {
            recordDiagnostic(L10n.text("Windows · Schlüsselbund"), L10n.text("Laden angefordert"))
            if let credential = try await Task.detached(operation: { try WindowsSetupKeychain.load(storageID: storage.id) }).value {
                settings.localWindowsUser = credential.name
                localPassword = credential.password
                localPasswordConfirmation = credential.password
                credentialStatus = L10n.text("Kontodaten aus dem macOS-Schlüsselbund geladen.")
            } else { credentialStatus = L10n.text("Für diesen Datenordner sind noch keine Kontodaten gespeichert.") }
            recordDiagnostic(L10n.text("Windows · Schlüsselbund"), credentialStatus)
        } catch { credentialStatus = error.localizedDescription; errorMessage = error.localizedDescription }
    }
    @Published var windowsEmbeddedPlayer = UserDefaults.standard.bool(forKey: "Stratovo.windowsEmbeddedPlayer") {
        didSet {
            UserDefaults.standard.set(windowsEmbeddedPlayer, forKey: "Stratovo.windowsEmbeddedPlayer")
            graphicsLab.refresh(model: self)
        }
    }
    @Published var windowsWriteLimit = WindowsWriteLimit(rawValue: UserDefaults.standard.integer(forKey: "Stratovo.windowsWriteLimit")) ?? .off {
        didSet { UserDefaults.standard.set(windowsWriteLimit.rawValue, forKey: "Stratovo.windowsWriteLimit") }
    }
    @Published var windowsRefreshRate = WindowsRefreshRate(rawValue: UserDefaults.standard.integer(forKey: "Stratovo.windowsRefreshRate")) ?? .automatic {
        didSet { UserDefaults.standard.set(windowsRefreshRate.rawValue, forKey: "Stratovo.windowsRefreshRate") }
    }
    @Published private(set) var windowsUsesDirectDisplay = false
    let windowsFrames = WindowsFrameStore()
    var playerImage: NSImage? { windowsFrames.image }
    @Published private(set) var playerSize = CGSize.zero
    @Published private(set) var playerStatus = L10n.text("Player noch nicht gestartet")
    @Published private(set) var activeGuest = ""
    @Published private(set) var streamFPS = 0.0
    @Published private(set) var androidDroppedFrames = 0
    @Published private(set) var androidReconnectBusy = false
    @Published var androidScrollSpeed = GuestScrollSpeed.percent(UserDefaults.standard.object(forKey: "Pixelkoje.scrollSpeed.android") as? Double ?? 50) {
        didSet { UserDefaults.standard.set(GuestScrollSpeed.percent(androidScrollSpeed), forKey: "Pixelkoje.scrollSpeed.android"); resetScroll() }
    }
    @Published var ubuntuScrollSpeed = GuestScrollSpeed.percent(UserDefaults.standard.object(forKey: "Stratovo.scrollSpeed.ubuntu") as? Double ?? 50) {
        didSet { UserDefaults.standard.set(GuestScrollSpeed.percent(ubuntuScrollSpeed), forKey: "Stratovo.scrollSpeed.ubuntu"); resetScroll() }
    }
    @Published var windowsScrollSpeed = GuestScrollSpeed.percent(UserDefaults.standard.object(forKey: "Pixelkoje.scrollSpeed.windows") as? Double ?? 50) {
        didSet { UserDefaults.standard.set(GuestScrollSpeed.percent(windowsScrollSpeed), forKey: "Pixelkoje.scrollSpeed.windows"); resetScroll() }
    }
    @Published var androidVulkanEnabled = UserDefaults.standard.object(forKey: "Pixelkoje.androidVulkanEnabled") as? Bool ?? true {
        didSet { UserDefaults.standard.set(androidVulkanEnabled, forKey: "Pixelkoje.androidVulkanEnabled"); settings.coldBoot = true }
    }
    private(set) var windowsFrameCount = 0
    @Published private(set) var googleServicesStatus = L10n.text("Google-Dienste werden nach dem Android-Start geprüft.")
    let h264Player = H264Player()
    let audio = GuestAudioController()
    let installer = SetupInstaller()
    private let playerWindows = GuestPlayerWindows()

    func showPlayer(kind: String) {
        if kind == "android", androidUsesDirectDisplay {
            playerWindows.hide(kind: kind)
            activateAndroidGraphics()
        } else if kind == "windows", windowsUsesDirectDisplay {
            playerWindows.hide(kind: kind)
            activateWindowsGraphics()
        } else { playerWindows.show(kind: kind, model: self) }
    }
    private func activateAndroidGraphics() {
        guard androidUsesDirectDisplay, let child = process else { return }
        let pid = child.processIdentifier
        Task { [weak self] in
            for _ in 0..<5 {
                guard let self, self.androidUsesDirectDisplay, self.process?.processIdentifier == pid else { return }
                // The SDK launcher may start a separate QEMU/Qt child. Only activate
                // this launch's descendants, never an unrelated Android instance.
                let result = try? await Self.capture(CommandSpec(executable: "/bin/ps", arguments: ["-axo", "pid=,ppid="]), timeout: 2)
                guard self.androidUsesDirectDisplay, self.process?.processIdentifier == pid else { return }
                let descendants = AndroidProcessTree.descendants(of: pid, snapshot: result?.output ?? "")
                for candidate in [pid] + descendants {
                    if let app = NSRunningApplication(processIdentifier: candidate),
                       app.activate(options: [.activateAllWindows, .activateIgnoringOtherApps]) {
                        self.androidWindowStatus = ""
                        return
                    }
                }
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
            guard let self, self.androidUsesDirectDisplay, self.process?.processIdentifier == pid else { return }
            self.androidWindowStatus = L10n.text("Das native Android-Fenster bei Bedarf über das Dock auswählen. Ein geschlossenes Emulatorfenster kann Android beenden; danach neu starten.")
        }
    }
    private func activateWindowsGraphics() {
        guard running, activeGuest == "windows", let child = process else { return }
        let pid = child.processIdentifier
        Task { [weak self] in
            for _ in 0..<10 {
                guard let self, self.running, self.process?.processIdentifier == pid else { return }
                if let app = NSRunningApplication(processIdentifier: pid),
                   app.activate(options: [.activateAllWindows, .activateIgnoringOtherApps]) { return }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
    }
    func togglePlayerFullScreen(kind: String) { playerWindows.toggleFullScreen(kind: kind) }
    func fitAndroidPlayerWindow() {
        UserDefaults.standard.set(true, forKey: "Pixelkoje.playerFit.android")
        playerWindows.fitAndroid(model: self)
    }

    var setupReady: Set<SetupComponent> {
        guard let storage, storageReady else { return [] }
        let fm = FileManager.default
        func externalFile(_ path: String) -> Bool {
            let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
            let root = storage.url.resolvingSymlinksInPath().path
            return !path.isEmpty && resolved.hasPrefix(root + "/") && fm.isReadableFile(atPath: path)
        }
        var ready: Set<SetupComponent> = []
        if fm.isExecutableFile(atPath: storage.sdk.appendingPathComponent("emulator/emulator").path),
           fm.isExecutableFile(atPath: storage.sdk.appendingPathComponent("platform-tools/adb").path) {
            for system in AndroidSystem.allCases {
                let relative = "system-images/\(system.platform)/google_apis_playstore/arm64-v8a/system.img"
                if fm.isReadableFile(atPath: storage.sdk.appendingPathComponent(relative).path),
                   devices.contains(where: { androidSystem(for: $0.name) == system }) {
                    ready.insert(system == .android16 ? .android : .android17)
                }
            }
        }
        if ScrcpySession.installed { ready.insert(.streaming) }
        if externalFile(settings.iso) { ready.insert(.windowsISO) }
        if externalFile(settings.driversISO) { ready.insert(.windowsDrivers) }
        return ready
    }

    func installComponents(_ selection: Set<SetupComponent>, microsoftLink: String, androidDataSource: String? = nil) async {
        guard !busy, !running, let storage, !selection.isEmpty else { return }
        busy = true
        errorMessage = nil
        var completed = false
        var copiedProfile: String?
        do {
            if selection.contains(.android) || selection.contains(.android17) { try await requireAndroidStopped() }
            let result = try await installer.install(selection, storage: storage, existingISO: settings.iso,
                existingDrivers: settings.driversISO, microsoftLink: microsoftLink, ready: setupReady, androidChannel: androidSDKChannel, preferredAndroidProfile: settings.selectedAVD,
                androidDataSource: androidDataSource, qemuImg: qemuImg)
            copiedProfile = result.androidProfile
            if let iso = result.iso { settings.iso = iso }
            if let drivers = result.drivers { settings.driversISO = drivers }
            // Pick up a driver ISO left by a previous interrupted setup as well.
            let drivers = storage.url.appendingPathComponent("Installationsmedien/utm-guest-tools.iso")
            if settings.driversISO.isEmpty, (try? SetupInstaller.validateISO(drivers)) != nil {
                settings.driversISO = drivers.path
            }
            completed = true
        } catch { errorMessage = error.localizedDescription }
        busy = false
        await refresh()
        guard completed else { return }
        androidCleanupPlan = nil
        if let copiedProfile, devices.contains(where: { $0.name == copiedProfile }) {
            settings.selectedAVD = copiedProfile
            settings.coldBoot = true
        } else if selection.contains(.android17), let device = devices.first(where: { androidSystem(for: $0.name) == .android17 }) {
            settings.selectedAVD = device.name
            settings.coldBoot = true
        } else if selection.contains(.android), let device = devices.first(where: { androidSystem(for: $0.name) == .android16 }) {
            settings.selectedAVD = device.name
            settings.coldBoot = true
        }
    }

    @Published var androidSDKChannel = min(3, max(0, UserDefaults.standard.integer(forKey: "Pixelkoje.androidSDKChannel"))) {
        didSet { UserDefaults.standard.set(androidSDKChannel, forKey: "Pixelkoje.androidSDKChannel") }
    }
    @Published var androidCheckUpdatesOnOpen = UserDefaults.standard.object(forKey: "Pixelkoje.androidCheckUpdatesOnOpen") as? Bool ?? true {
        didSet { UserDefaults.standard.set(androidCheckUpdatesOnOpen, forKey: "Pixelkoje.androidCheckUpdatesOnOpen") }
    }
    @Published var androidAutoUpdateBeforeStart = UserDefaults.standard.bool(forKey: "Pixelkoje.androidAutoUpdateBeforeStart") {
        didSet { UserDefaults.standard.set(androidAutoUpdateBeforeStart, forKey: "Pixelkoje.androidAutoUpdateBeforeStart") }
    }
    @Published private(set) var androidMaintenanceStatus = L10n.text("Android 16 ist das Standardsystem. Android 17 wird separat eingerichtet.")
    @Published private(set) var androidCleanupPlan: AndroidCleanupPlan?

    func androidSystem(for name: String) -> AndroidSystem? {
        guard let storage else { return nil }
        return AndroidSystem.detect(RuntimeDiscovery.avdConfig(name: name, environment: storage.environment))
    }
    var selectedAndroidSystem: AndroidSystem? { androidSystem(for: settings.selectedAVD) }
    var android16DataSource: String? {
        let source = selectedAndroidSystem == .android16 ? settings.selectedAVD
            : devices.first(where: { $0.supported && androidSystem(for: $0.name) == .android16 })?.name
        guard let source, let storage else { return nil }
        let profile = storage.avd.appendingPathComponent(source + ".avd")
        return ["userdata-qemu.img", "userdata-qemu.img.qcow2"].contains {
            FileManager.default.isReadableFile(atPath: profile.appendingPathComponent($0).path)
        } ? source : nil
    }
    var hasAndroid17DataCopy: Bool {
        devices.contains { $0.name == SetupInstaller.android17DataProfile && androidSystem(for: $0.name) == .android17 }
    }
    func selectAndroidSystem(_ system: AndroidSystem) {
        guard canManageAndroid else { return }
        let dataCopy = devices.first { $0.name == SetupInstaller.android17DataProfile && androidSystem(for: $0.name) == system }
        guard let device = dataCopy ?? devices.first(where: { $0.supported && androidSystem(for: $0.name) == system }) else { return }
        settings.selectedAVD = device.name
        settings.coldBoot = true
        androidCleanupPlan = nil
        androidMaintenanceStatus = L10n.message("Android \(system.rawValue) ausgewählt. Mit „Android starten“ öffnen.")
    }
    var canManageAndroid: Bool { storageReady && !running && !busy && !installer.running }

    func manageAndroidUpdates(install: Bool) async {
        guard canManageAndroid, let storage, let system = selectedAndroidSystem else { return }
        busy = true
        errorMessage = nil
        do {
            try await installer.manageAndroid(system, mode: install ? "update" : "check", channel: androidSDKChannel, storage: storage)
            if install { settings.coldBoot = true; androidCleanupPlan = nil }
            androidMaintenanceStatus = installer.status
            recordDiagnostic("Android · Updates", L10n.message("Android \(system.rawValue), Kanal \(androidSDKChannel), \(install ? "Abbild aktualisiert" : "Updateprüfung")"))
        } catch {
            androidMaintenanceStatus = error.localizedDescription
            errorMessage = error.localizedDescription
        }
        busy = false
        if install { await refresh() }
    }

    private func requireAndroidStopped() async throws {
        let result = try await Self.capture(CommandSpec(executable: "/usr/bin/pgrep", arguments: ["-f", "/emulator/qemu/|sdk/emulator/emulator"]))
        guard result.status == 1 else {
            throw StorageMigration.failure(L10n.text("Bitte auch separat gestartete Android-Emulatoren vollständig beenden."))
        }
    }
    func previewAndroidCleanup() async {
        guard canManageAndroid, let storage else { return }
        androidCleanupPlan = nil
        busy = true
        let name = settings.selectedAVD
        do {
            try await requireAndroidStopped()
            let plan = try await Task.detached { try AndroidMaintenance.plan(storage: storage, keeping: name) }.value
            androidCleanupPlan = plan
            androidMaintenanceStatus = plan.paths.isEmpty ? "Keine alten Android-Daten gefunden." : L10n.message("\(plan.paths.count) Einträge zur endgültigen Entfernung. Android 16 bleibt erhalten.")
        } catch { androidMaintenanceStatus = error.localizedDescription; errorMessage = error.localizedDescription }
        busy = false
    }
    func cleanupOldAndroid() async {
        guard canManageAndroid, let storage, let plan = androidCleanupPlan, plan.keeping == settings.selectedAVD else { return }
        busy = true
        do {
            try await requireAndroidStopped()
            try await Task.detached { try AndroidMaintenance.cleanup(storage: storage, expected: plan) }.value
            androidCleanupPlan = nil
            settings.coldBoot = true
            androidMaintenanceStatus = "Alte Android-Profile, andere Systemabbilder und erkannte alte Android-Sicherungen entfernt. Android 16 bleibt erhalten."
            recordDiagnostic("Android · Bereinigung", L10n.message("\(plan.paths.count) Einträge entfernt; Profil \(plan.keeping) erhalten"))
        } catch { androidMaintenanceStatus = error.localizedDescription; errorMessage = error.localizedDescription; androidCleanupPlan = nil }
        busy = false
        await refresh()
    }

    private var process: Process?
    private var output: FileHandle?
    private var logURL: URL?
    private var sessionCommand = ""
    private var timer: Timer?
    private var logReadTask: Task<Void, Never>?
    private var lastLogSize: UInt64?
    private var rendererInspected = false
    private var guestActivity: NSObjectProtocol?
    private var bootTask: Task<Void, Never>?
    private var androidPort: Int?
    private var windowsSession: WindowsSession?
    private var opened = false
    private var androidStream: ScrcpySession?
    private var windowsPlayer: RFBClient?
    private var displayTask: Task<Void, Never>?
    private var qmpSocket: String?
    private var windowsDisplaySocket: String?
    @Published private(set) var windowsReconnectBusy = false
    private var windowsBootProbe: Task<Void, Never>?
    private var windowsPasteTask: Task<Void, Never>?
    private var stopRequested = false

    let totalMemoryGB = Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824)
    let hostCores = ProcessInfo.processInfo.activeProcessorCount
    var maxMemoryGB: Int { max(2, min(8, totalMemoryGB / 2)) }
    var maxCores: Int { max(2, min(8, hostCores - 2)) }
    var supportedHost: Bool {
        #if arch(arm64)
        return true
        #else
        return false
        #endif
    }
    var hypervisorAvailable: Bool {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("kern.hv_support", &value, &size, nil, 0) == 0 && value == 1
    }
    var selectedDevice: AndroidDevice? { devices.first { $0.name == settings.selectedAVD } }
    var canStartAndroid: Bool {
        storageReady && supportedHost && hypervisorAvailable && androidReady && selectedDevice?.supported == true && adb != nil && androidOutputMode.canLaunch(streamInstalled: ScrcpySession.installed) && androidDisplayIssue == nil && !busy && !running
    }
    private var windowsHostReady: Bool {
        storageReady && storage?.windowsFolderReady == true && windowsCapacityIssue == nil && supportedHost && hypervisorAvailable && windowsReady && firmware != nil && settings.memoryGB >= 4 && !busy && !running
    }
    var canStartWindows: Bool {
        windowsHostReady && (settings.installWindows
            ? (windowsISOReady && (!settings.localWindowsAccount || localAccountIssue == nil))
            : windowsDiskBytes != nil)
    }
    var canResumeWindows: Bool { windowsHostReady && windowsDiskBytes != nil }
    var canInstallAPK: Bool { running && androidBooted && androidPort != nil && !apkBusy && !busy && !androidDisplayBusy && adb != nil }
    var adb: String? {
        guard let sdk else { return nil }
        let path = URL(fileURLWithPath: sdk).appendingPathComponent("platform-tools/adb").path
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }
    var resources: GuestResources { GuestResources(memoryMiB: settings.memoryGB * 1024, cores: settings.cores) }

    init(frameRateDefaults: UserDefaults = .standard, applyPerformanceDefaults: Bool = true) {
        self.frameRateDefaults = frameRateDefaults
        self.androidOutputMode = AndroidOutputMode(rawValue: frameRateDefaults.string(forKey: "Stratovo.androidOutputMode") ?? "player") ?? .player
        self.storedAndroidTargetFPS = AndroidFrameRate.limit(frameRateDefaults.object(forKey: "Pixelkoje.androidFPS") as? Int ?? 60)
        guard applyPerformanceDefaults else { return }
        if !UserDefaults.standard.bool(forKey: "Pixelkoje.performanceDefaultsApplied") {
            if settings.gpu == "auto" { settings.gpu = "host"; settings.save() }
            UserDefaults.standard.set(true, forKey: "Pixelkoje.performanceDefaultsApplied")
        }
        settings.memoryGB = min(max(2, settings.memoryGB), maxMemoryGB)
        settings.cores = min(max(2, settings.cores), maxCores)
    }

    func open() async {
        guard !opened else { return }
        opened = true
        guard storage != nil else { showStorageSetup = true; return }
        updateBackupPaths()
        await refresh()
        // Prefer the saved disk when upgrading from versions that kept DVD boot enabled.
        if windowsDiskBytes != nil { settings.installWindows = false }
        if androidCheckUpdatesOnOpen, canManageAndroid, selectedAndroidSystem != nil,
           Date().timeIntervalSince1970 - UserDefaults.standard.double(forKey: "Pixelkoje.androidLastUpdateCheck") > 86_400 {
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "Pixelkoje.androidLastUpdateCheck")
            await manageAndroidUpdates(install: false)
        }
        // Launching Stratovo only prepares the main window. Guests always start on an explicit click.
    }

    func refresh() async {
        guard !busy, !running else { return }
        guard let storage else { showStorageSetup = true; return }
        do { try storage.validate() } catch { errorMessage = error.localizedDescription; return }
        busy = true
        defer { busy = false; systemCheckLog = log; recordDiagnostic(L10n.text("Systemprüfung"), log) }
        refreshWindowsISO()
        refreshWindowsIdentity()
        loadWindowsDisplayChoice()
        windowsFolderStatus = storage.windowsFolderReady ? "Windows-Ordner vorhanden und beschreibbar." : "Bitte den Windows-Ordner vor dem ersten Start anlegen."
        androidReady = false
        windowsReady = false
        devices = []
        sdk = RuntimeDiscovery.sdk(preferred: storage.sdk.path, environment: storage.environment)
        qemu = RuntimeDiscovery.qemu(preferred: settings.qemu)
        swtpm = RuntimeDiscovery.swtpm(preferred: settings.swtpm)
        qemuImg = qemu.flatMap { RuntimeDiscovery.sibling(executable: $0, name: "qemu-img") }
        windowsDiskBytes = nil
        let image = storage.windows.appendingPathComponent("windows.qcow2")
        if let qemuImg, FileManager.default.fileExists(atPath: image.path) {
            do {
                windowsDiskBytes = try await Task.detached { try WindowsDiskImage.info(qemuImg: qemuImg, disk: image) }.value
                windowsDiskStatus = "Vorhandene Festplatte: \((windowsDiskBytes ?? 0) / 1_073_741_824) GB."
            } catch { windowsDiskStatus = L10n.message("Festplattengröße nicht prüfbar: \(error.localizedDescription)") }
        } else { windowsDiskStatus = L10n.text("Noch keine Windows-Festplatte angelegt. Sie wird mit der gewählten Größe erstellt.") }
        let saved = UserDefaults.standard.integer(forKey: "OpenGuest.windowsDiskGiB.\(storage.id)")
        let currentGiB = windowsDiskBytes.map { Int(($0 + 1_073_741_823) / 1_073_741_824) }
        windowsDiskSize = String(max(saved == 0 ? (currentGiB ?? 80) : saved, currentGiB ?? 0))
        firmware = qemu.flatMap { RuntimeDiscovery.firmware(qemu: $0, preferred: settings.firmware) }
        variablesTemplate = firmware.flatMap { RuntimeDiscovery.variablesTemplate(firmware: $0) }
        androidAcceleration = sdk == nil ? "Android Emulator fehlt" : L10n.text("Prüfung läuft …")
        windowsAcceleration = qemu == nil ? "QEMU fehlt" : L10n.text("Prüfung läuft …")
        log = "Mac: \(supportedHost ? "Apple Silicon (nativ)" : "Architektur nicht unterstützt / Rosetta") · \(totalMemoryGB) GB RAM · \(hostCores) Kerne\nHypervisor: \(hypervisorAvailable ? "verfügbar" : "nicht verfügbar")\n"

        if let sdk {
            let engine = URL(fileURLWithPath: sdk).appendingPathComponent("emulator/emulator").path
            let environment = storage.environment
            do {
                let result = try await Self.capture(CommandSpec(executable: engine, arguments: ["-accel-check"], environment: environment))
                androidReady = result.status == 0
                androidAcceleration = androidReady ? L10n.text("Hardwarebeschleunigung verfügbar") : L10n.text("Beschleunigung nicht nutzbar")
                log += "\nAndroid: \(result.output)\n"
                let list = try await Self.capture(CommandSpec(executable: engine, arguments: ["-list-avds"], environment: environment))
                guard list.status == 0 else { throw GuestError.commandFailed(list.status, list.output) }
                devices = list.output.components(separatedBy: .newlines)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty && !$0.contains(" ") && !$0.contains(":") && !$0.contains("/") }
                    .map { RuntimeDiscovery.device(name: $0, environment: environment) }
                if !devices.contains(where: { $0.name == settings.selectedAVD }) || selectedAndroidSystem == nil {
                    settings.selectedAVD = devices.first(where: { $0.supported && androidSystem(for: $0.name) == .android16 })?.name
                        ?? devices.first(where: { $0.supported && $0.googlePlay })?.name ?? devices.first(where: \.supported)?.name ?? devices.first?.name ?? ""
                }
                if devices.isEmpty { log += L10n.text("Kein AVD gefunden. In Android Studio ein arm64-v8a-Gerät erstellen.\n") }
            } catch {
                androidReady = false
                androidAcceleration = L10n.text("Android-Prüfung fehlgeschlagen")
                log += "\n\(error.localizedDescription)\n"
            }
        }
        if let qemu {
            do {
                let acceleration = try await Self.capture(CommandSpec(executable: qemu, arguments: ["-accel", "help"]))
                let display = try await Self.capture(CommandSpec(executable: qemu, arguments: ["-help"]))
                let hardware = try await Self.capture(CommandSpec(executable: qemu, arguments: ["-device", "help"]))
                let hasHVF = acceleration.output.components(separatedBy: .whitespacesAndNewlines).contains("hvf")
                let hasCocoa = display.output.contains("-vnc")
                let hasTPM = RuntimeDiscovery.hasDevice("tpm-tis-device", in: hardware.output)
                windowsReady = acceleration.status == 0 && display.status == 0 && hardware.status == 0 && hasHVF && hasCocoa && hasTPM && swtpm != nil && qemuImg != nil && variablesTemplate != nil
                windowsAcceleration = windowsReady ? L10n.text("HVF, VNC, TPM und UEFI-Dateien gefunden · Secure Boot nicht geprüft") : L10n.text("QEMU, swtpm oder passende UEFI-Dateien fehlen")
                log += "\nQEMU-Beschleuniger:\n\(acceleration.output)\nQEMU-Geräte:\n\(hardware.output)\n"
                if firmware == nil { log += L10n.text("ARM64-UEFI-Firmware fehlt. Bitte eine edk2-aarch64-code.fd auswählen.\n") }
                if swtpm == nil { log += L10n.text("swtpm fehlt. Für Windows wird ein dauerhaftes TPM 2.0 benötigt.\n") }
                if !hasTPM { log += L10n.text("QEMU-Build enthält kein ARM-TPM (tpm-tis-device).\n") }
                var missing: [String] = []
                if !hasHVF { missing.append("HVF") }
                if !hasCocoa { missing.append("VNC") }
                if !hasTPM { missing.append("ARM-TPM (tpm-tis-device)") }
                if swtpm == nil { missing.append("swtpm") }
                if qemuImg == nil { missing.append("qemu-img") }
                if firmware == nil { missing.append("ARM64-UEFI") }
                if variablesTemplate == nil { missing.append("passende UEFI-Variablen") }
                if !missing.isEmpty { windowsAcceleration = "Fehlt: " + missing.joined(separator: ", ") }
                if variablesTemplate == nil { log += L10n.text("edk2-arm-vars.fd fehlt neben der gewählten Firmware.\n") }
            } catch {
                windowsAcceleration = L10n.text("QEMU-Prüfung fehlgeschlagen")
                log += "\n\(error.localizedDescription)\n"
            }
        }
        await restoreWindowsCredentialSilently()
    }

    private static func capture(_ spec: CommandSpec, timeout: TimeInterval = 12) async throws -> CommandResult {
        try await Task.detached(priority: .userInitiated) { try CommandCapture.run(spec, timeout: timeout) }.value
    }

    func startAndroid() {
        if androidAutoUpdateBeforeStart, selectedAndroidSystem != nil {
            Task {
                await manageAndroidUpdates(install: true)
                if errorMessage == nil { launchAndroid() }
            }
        } else { launchAndroid() }
    }

    private func launchAndroid() {
        guard canStartAndroid, let sdk, let storage, let device = selectedDevice else { return }
        do {
            try checkStorageSpace(minimumGB: 16)
            let port = try AndroidPorts.available()
            let refreshChanged = try AndroidFrameRate.prepareAVD(root: storage.avd, name: device.name, fps: androidTargetFPS)
            androidGuestRefreshHz = AndroidFrameRate.displayHz(for: androidTargetFPS)
            let base = try LaunchPlan.android(sdk: sdk, device: device, resources: resources,
                                              coldBoot: settings.coldBoot || refreshChanged, gpu: settings.gpu, port: port, vulkan: androidVulkanEnabled, output: androidOutputMode)
            let spec = CommandSpec(executable: base.executable, arguments: base.arguments, environment: storage.environment)
            try start(spec, title: "Android · \(device.name)")
            activeGuest = "android"
            activeAndroidOutputMode = androidOutputMode
            androidWindowStatus = ""
            androidRendererStatus = L10n.text("Grafikrenderer wird geprüft"); androidSoftwareRendering = false
            androidDisplayStatus = L10n.text("Leistungsprofil wird angewendet, sobald Android bereit ist")
            streamFPS = 0; decoderFPS = 0; decoderRecoveries = 0
            recordDiagnostic("Android · Leistung", "Profil \(androidProfile.rawValue), Ziel \(androidTargetFPS) FPS, Ausgabe \(androidOutputMode.rawValue), GPU angefordert \(androidOutputMode.gpu(requested: settings.gpu)), Vulkan \(androidVulkanEnabled ? "erlaubt" : "aus"), begrenzte Stream-Warteschlange")
            playerStatus = "Android startet …"
            androidPort = port
            androidBooted = false
            apkStatus = "Android startet …"
            showPlayer(kind: "android")
            watchAndroidBoot(port: port)
        } catch { errorMessage = error.localizedDescription }
    }

    private var ubuntuSession: UbuntuSession?
    func startUbuntu(installing: Bool, memory: Int, cores: Int) {
        guard !running, !busy, let storage, let qemu, let qemuImg, let firmware, let variablesTemplate else {
            errorMessage = L10n.text("Zuerst Speicherort und QEMU-Werkzeuge unter Einrichtung prüfen.")
            return
        }
        busy = true
        Task {
            defer { busy = false }
            let session = UbuntuSession()
            do {
                let (spec, display, qmp) = try await session.prepare(storage: storage, qemu: qemu,
                    qemuImg: qemuImg, firmware: firmware, variablesTemplate: variablesTemplate,
                    installing: installing, memory: memory, cores: cores)
                ubuntuSession = session
                try start(spec, title: "Ubuntu ARM64")
                windowsBootArtwork = nil
                activeGuest = "ubuntu"; qmpSocket = qmp; windowsDisplaySocket = display
                audio.connect(.qmp(socket: qmp), kind: "ubuntu")
                showPlayer(kind: "ubuntu")
                connectWindowsPlayer(socket: display)
            } catch {
                session.stop(); ubuntuSession = nil
                errorMessage = error.localizedDescription
            }
        }
    }

    func startWindows() {
        refreshWindowsISO()
        Task { await startWindowsVM() }
    }

    func startExistingWindows() {
        guard canResumeWindows else { return }
        settings.installWindows = false
        startWindows()
    }

    private func startWindowsVM() async {
        guard canStartWindows, let capacity = windowsCapacityGiB, let qemu, let firmware, let qemuImg, let swtpm, let variablesTemplate else { return }
        let installing = settings.installWindows
        busy = true
        defer { busy = false }
        let session = WindowsSession()
        do {
            try checkStorageSpace(minimumGB: installing ? 25 : 2)
            var account: WindowsEdition.LocalAccount?
            if installing && settings.localWindowsAccount {
                account = try WindowsEdition.validateSetupAccount(name: settings.localWindowsUser,
                    password: localPassword, confirmation: localPasswordConfirmation)
            }
            guard FileManager.default.isReadableFile(atPath: firmware) else { throw GuestError.missingFile(firmware) }
            if installing { _ = try WindowsISOInfo.check(path: settings.iso) }
            if !settings.driversISO.isEmpty, settings.driversISO == settings.iso {
                throw StorageMigration.failure(L10n.text("Windows-ISO und Treiber-ISO sind identisch. Bitte die Treiber-Auswahl entfernen oder eine separate ARM64-Treiber-ISO wählen."))
            }
            if !settings.driversISO.isEmpty, !FileManager.default.isReadableFile(atPath: settings.driversISO) {
                throw GuestError.missingFile(settings.driversISO)
            }
            if rememberWindowsCredential, let account, let storage {
                try await persistWindowsCredential(account, storage: storage)
            }
            let files = try await session.prepare(qemuImg: qemuImg, swtpm: swtpm, variablesTemplate: variablesTemplate,
                                                  capacityGiB: capacity, selectPro: installing && settings.selectPro, localAccount: account)
            graphicsLab.refresh(model: self)
            guard graphicsLab.runtimeReady, let storage else {
                throw StorageMigration.failure(L10n.text("Bitte zuerst unter Windows die 3D-Grafik vorbereiten."))
            }
            guard let dependencyHelper = Bundle.main.resourceURL?.appendingPathComponent("GraphicsLab/runtime_dependencies.py") else {
                throw GuestError.missingFile("runtime_dependencies.py")
            }
            let graphicsRoot = storage.root + "/GraphicsLab"
            let dependencyCheck = try await Task.detached {
                try CommandCapture.run(CommandSpec(executable: "/usr/bin/python3", arguments: [dependencyHelper.path, graphicsRoot]), timeout: 30)
            }.value
            recordDiagnostic("Windows · Grafikbibliotheken", dependencyCheck.output)
            guard dependencyCheck.status == 0 else {
                throw GuestError.commandFailed(dependencyCheck.status, dependencyCheck.output)
            }
            let bootFirmware = try await preparePCBootAppearance(firmware: firmware, root: storage.windows)
            var bootArtworkPath: String?
            if let artwork = windowsBootArtwork {
                let target = URL(fileURLWithPath: files.qmpSocket).deletingLastPathComponent().appendingPathComponent("boot-artwork.json")
                do {
                    try JSONEncoder().encode(artwork).write(to: target, options: .atomic)
                    bootArtworkPath = target.path
                } catch { recordDiagnostic("Windows · Startdarstellung", error.localizedDescription) }
            }
            windowsDiskBytes = Int64(capacity) * 1_073_741_824
            let spec = try LaunchPlan.windowsVM(qemu: qemu, firmware: bootFirmware, variables: files.variables, disk: files.disk,
                                               tpmSocket: files.socket, iso: settings.iso, driversISO: settings.driversISO,
                                               proISO: files.proISO, installing: installing, resources: resources,
                                               displaySocket: files.displaySocket, network: settings.windowsNetwork, qmpSocket: files.qmpSocket, identity: files.identity,
                                               graphics: windowsGraphics, resolution: windowsResolution, metalRoot: storage.root+"/GraphicsLab", embeddedPlayer: windowsEmbeddedPlayer, bootArtwork: bootArtworkPath, writeLimit: windowsWriteLimit, refreshRate: windowsRefreshRate)
            recordDiagnostic("Windows · Grafik", windowsGraphics.title + " · bevorzugter Modus " + windowsResolution.title)
            recordDiagnostic("Windows · Schreiblimit", windowsWriteLimit.title)
            recordDiagnostic("Windows · Bildwiederholrate", windowsRefreshRate.title)
            windowsIdentity = files.identity
            windowsIdentityStatus = files.identity.summary
            recordDiagnostic("Windows · Gerätekennung", files.identity.summary)
            windowsSession = session
            try start(spec, title: "Windows 11 Pro Arm64")
            // Consume the DVD choice after a successful process launch, retaining its path.
            settings.installWindows = false
            recordDiagnostic("Windows · Startmedium", installing
                ? L10n.text("Einmaliger DVD-Start; nächster Start von der gespeicherten Festplatte.")
                : "Start von der gespeicherten Festplatte; keine Installations-DVD eingebunden.")
            activeGuest = "windows"
            windowsUsesDirectDisplay = !windowsEmbeddedPlayer
            qmpSocket = files.qmpSocket
            audio.connect(.qmp(socket: files.qmpSocket), kind: "windows")
            if windowsUsesDirectDisplay {
                windowsDisplaySocket = nil
                playerStatus = L10n.text("Windows Arm läuft im direkten Grafikfenster · Metal")
                recordDiagnostic("Windows · Bildausgabe", "Direktes Cocoa/Metal-Fenster; keine VNC-Bildkopie")
            } else {
                windowsDisplaySocket = files.displaySocket
                connectWindowsPlayer(socket: files.displaySocket)
            }
            showPlayer(kind: "windows")
            inspectWindowsBoot(socket: files.qmpSocket, installing: installing)
        } catch {
            await session.stop()
            windowsSession = nil
            errorMessage = error.localizedDescription
        }
    }

    private func watchAndroidBoot(port: Int) {
        bootTask?.cancel()
        guard let adb else { apkStatus = L10n.text("Für APK-Installation bitte Android SDK Platform-Tools installieren."); return }
        bootTask = Task { [weak self] in
            for _ in 0..<180 {
                guard !Task.isCancelled, let self, self.running, self.androidPort == port else { return }
                let result = try? await Self.capture(CommandSpec(executable: adb,
                    arguments: ["-s", "emulator-\(port)", "shell", "getprop", "sys.boot_completed"]), timeout: 8)
                guard !Task.isCancelled, self.running, self.androidPort == port else { return }
                if result?.status == 0 && result?.output.trimmingCharacters(in: .whitespacesAndNewlines) == "1" {
                    self.androidBooted = true
                    await self.applyAndroidDisplay(port: port)
                    guard !Task.isCancelled, self.running, self.androidPort == port else { return }
                    self.apkStatus = L10n.text("Android bereit · APKs können installiert werden")
                    self.audio.connect(.android(adb: adb, serial: "emulator-\(port)"), kind: "android")
                    if self.androidUsesDirectDisplay {
                        self.playerStatus = L10n.text("Direktes Emulatorfenster · ohne Stratovo-Videostream")
                        self.recordDiagnostic("Android · Anzeige", self.playerStatus)
                    } else {
                        await self.connectAndroidPlayer(port: port)
                    }
                    await self.checkGoogleServices(port: port)
                    return
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
            self?.apkStatus = L10n.text("Android noch nicht bereit. Gastfenster prüfen; danach Android erneut starten.")
        }
    }

    private func applyAndroidDisplay(port: Int) async {
        guard let adb else { return }
        let serial = "emulator-\(port)"
        do {
            let size = try await Self.capture(CommandSpec(executable: adb, arguments: ["-s", serial, "shell", "wm", "size"]))
            let density = try await Self.capture(CommandSpec(executable: adb, arguments: ["-s", serial, "shell", "wm", "density"]))
            guard size.status == 0, density.status == 0 else { throw GuestError.commandFailed(1, L10n.text("Bildschirmwerte nicht lesbar")) }
            let plan = try AndroidDisplayPlan(sizeOutput: size.output, densityOutput: density.output, profile: androidProfile,
                                             custom: requestedAndroidDisplay())
            do {
                for command in plan.commands {
                    try Task.checkCancellation()
                    guard running, androidPort == port else { return }
                    let result = try await Self.capture(CommandSpec(executable: adb, arguments: ["-s", serial, "shell"] + command))
                    guard result.status == 0, !result.output.lowercased().contains("error:") else {
                        throw GuestError.commandFailed(result.status, result.output)
                    }
                }
                androidDisplayStatus = plan.summary
            } catch {
                if running, androidPort == port {
                    for command in plan.rollback {
                        _ = try? await Self.capture(CommandSpec(executable: adb, arguments: ["-s", serial, "shell"] + command))
                    }
                }
                throw error
            }
        } catch { androidDisplayStatus = L10n.message("Auflösung nicht angepasst; bisherige Werte bleiben soweit möglich erhalten: \(error.localizedDescription)") }
        recordDiagnostic("Android · Bildschirm", androidDisplayStatus)
    }

    private func connectAndroidPlayer(port: Int) async {
        guard let adb, running, androidPort == port, activeAndroidOutputMode == .player else { return }
        h264Player.reset()
        let stream = ScrcpySession()
        h264Player.onSize = { [weak self, weak stream] size in
            self?.playerSize = size; stream?.setSize(size)
        }
        h264Player.onStatistics = { [weak self] fps, recoveries in
            self?.decoderFPS = fps; self?.decoderRecoveries = recoveries
        }
        stream.onPacket = { [weak self] data, pts, config in try await self?.h264Player.packet(data, pts: pts, configuration: config) }
        stream.onSize = { [weak self] size in self?.playerSize = size }
        stream.onStatus = { [weak self] text in self?.playerStatus = text }
        androidDroppedFrames = 0
        stream.onDiscontinuity = { [weak self] in self?.h264Player.resetReferences() }
        stream.onQueueDrops = { [weak self] count in self?.androidDroppedFrames = count }
        stream.onFPS = { [weak self] fps in
            self?.streamFPS = fps
            if fps == 0 { self?.decoderFPS = 0 }
        }
        androidStream = stream
        do {
            let quality = androidStreamQuality, fps = androidTargetFPS
            try await stream.start(adb: adb, serial: "emulator-\(port)", quality: quality, fps: fps)
            if running && androidPort == port && !Task.isCancelled {
                appliedAndroidStreamQuality = quality; appliedAndroidTargetFPS = fps
            }
            if Task.isCancelled || !running { await stream.stop() }
        } catch {
            await stream.stop()
            if !Task.isCancelled { playerStatus = "Android-Anzeige konnte nicht starten: \(error.localizedDescription)" }
        }
    }

    var canReconnectAndroidDisplay: Bool {
        running && activeGuest == "android" && activeAndroidOutputMode == .player && androidBooted && !busy && !androidReconnectBusy
    }
    func reconnectAndroidDisplay() async {
        guard canReconnectAndroidDisplay, let port = androidPort else { return }
        androidReconnectBusy = true
        defer { androidReconnectBusy = false }
        playerStatus = L10n.text("Android-Anzeige wird neu verbunden …")
        if let stream = androidStream { await stream.stop() }
        guard running, androidPort == port else { return }
        androidStream = nil
        await connectAndroidPlayer(port: port)
        recordDiagnostic("Android · Anzeige", L10n.text("Stream auf Benutzerwunsch neu verbunden; Gast nicht neu gestartet"))
    }

    private func inspectWindowsBoot(socket: String, installing: Bool) {
        windowsBootProbe?.cancel()
        windowsBootMediaStatus = installing ? L10n.text("Installations-DVD wird mit QEMU verbunden …") : "Start von gespeicherter Windows-Festplatte angefordert"
        windowsBootProbe = Task { [weak self] in
            let deadline = ProcessInfo.processInfo.systemUptime + 10
            while !FileManager.default.fileExists(atPath: socket), ProcessInfo.processInfo.systemUptime < deadline {
                guard !Task.isCancelled, self?.running == true else { return }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            guard let self, self.running, !Task.isCancelled else { return }
            do {
                let evidence = try await QMPClient.inspect(socket: socket)
                guard self.running, !Task.isCancelled else { return }
                if installing {
                    self.windowsBootMediaStatus = evidence.machineStatus + (evidence.dvdConnected
                        ? " · Installations-DVD verbunden: " + (evidence.dvdPath ?? self.settings.iso)
                        : " · QEMU meldet keine eingelegte, schreibgeschützte Installations-DVD")
                } else { self.windowsBootMediaStatus = evidence.machineStatus + " · Start von gespeicherter Festplatte" }
            } catch {
                guard !Task.isCancelled else { return }
                self.windowsBootMediaStatus = "DVD-/Startstatus konnte nicht von QEMU gelesen werden: \(error.localizedDescription)"
            }
            self.recordDiagnostic("Windows · Startmedium", self.windowsBootMediaStatus)
            do {
                let actual = try await QMPClient.machineUUID(socket: socket)
                guard self.running, !Task.isCancelled else { return }
                let expected = self.windowsIdentity?.uuid ?? "00000000-0000-0000-0000-000000000000"
                self.windowsIdentityStatus = actual == expected
                    ? "QEMU bestätigt VM-UUID: " + actual + (self.windowsIdentity?.mode == .legacy ? " · bisherige Standardkennung" : " · eigene Gerätekennung")
                    : "VM-UUID weicht von der gespeicherten Kennung ab: " + actual
            } catch {
                guard !Task.isCancelled else { return }
                self.windowsIdentityStatus = "VM-UUID nicht bei QEMU bestätigt: " + error.localizedDescription
            }
            self.recordDiagnostic(L10n.text("Windows · Gerätekennung geprüft"), self.windowsIdentityStatus)
        }
    }

    var canReconnectWindowsDisplay: Bool {
        running && !windowsUsesDirectDisplay && ["windows", "ubuntu"].contains(activeGuest) && !busy && !windowsReconnectBusy && !windowsPasteBusy
    }
    func reconnectWindowsDisplay() async {
        guard canReconnectWindowsDisplay, let socket = windowsDisplaySocket else { return }
        windowsReconnectBusy = true
        defer { windowsReconnectBusy = false }
        let previous = displayTask
        previous?.cancel(); windowsPlayer?.stop()
        await previous?.value
        guard running, ["windows", "ubuntu"].contains(activeGuest), windowsDisplaySocket == socket else { return }
        displayTask = nil; windowsPlayer = nil
        connectWindowsPlayer(socket: socket)
        recordDiagnostic("Windows · Anzeige", L10n.text("Bildverbindung neu angefordert; Windows läuft weiter"))
    }
    func openWindowsFirmwareMenu() {
        guard running, ["windows", "ubuntu"].contains(activeGuest), !windowsPasteBusy else { return }
        if windowsPlayer == nil { sendWindowsKeys(["esc"]); return }
        let escape = [WindowsKeyboard.Event(symbol: 0xff1b, down: true), WindowsKeyboard.Event(symbol: 0xff1b, down: false)]
        if windowsPlayer?.sendKeySequence(escape) == true {
            playerStatus = L10n.text("Escape an den Gast gesendet · UEFI-Startmenü ist nur während des Firmwarestarts verfügbar")
        }
    }

    private func connectWindowsPlayer(socket: String) {
        playerStatus = "Warte auf Windows-Bildschirmanschluss …"
        windowsFrameCount = 0
        displayTask = Task { [weak self] in
            let deadline = ProcessInfo.processInfo.systemUptime + 20
            while ProcessInfo.processInfo.systemUptime < deadline {
                guard let self, self.running, !Task.isCancelled else { return }
                if !FileManager.default.fileExists(atPath: socket) {
                    try? await Task.sleep(nanoseconds: 50_000_000)
                    continue
                }
                let client = RFBClient(bootArtwork: self.windowsBootArtwork)
                self.windowsPlayer = client
                client.onFrame = { [weak self] image in
                    guard let self else { return }
                    self.windowsFrames.publish(image)
                    if self.playerSize != image.size { self.playerSize = image.size }
                    self.windowsFrameCount += 1
                    if self.windowsFrameCount == 1 {
                        self.recordDiagnostic("Windows · Anzeige", "Erstes Bild empfangen: \(Int(image.size.width)) × \(Int(image.size.height))")
                    }
                }
                client.onStatus = { [weak self] text in
                    self?.playerStatus = text
                    self?.recordDiagnostic("Windows · Anzeige", text)
                }
                let firstFrameTimeout = Task {
                    try? await Task.sleep(nanoseconds: 15_000_000_000)
                    if !Task.isCancelled, self.windowsFrameCount == 0 { client.stop() }
                }
                do {
                    try await client.run(socket: socket)
                    firstFrameTimeout.cancel()
                    return
                } catch {
                    firstFrameTimeout.cancel()
                    if client.initialized {
                        if !Task.isCancelled {
                            self.playerStatus = self.windowsFrameCount == 0
                                ? "QEMU liefert kein erstes Bild. Bitte Gesamtprotokoll exportieren."
                                : "Windows-Anzeige: \(error.localizedDescription)"
                            self.recordDiagnostic("Windows · Anzeige", self.playerStatus)
                        }
                        return
                    }
                    self.recordDiagnostic("Windows · Anzeigeverbindung", error.localizedDescription)
                }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            self?.playerStatus = L10n.text("Windows-Bildschirm nicht erreichbar. DVD-/Startstatus und Gesamtprotokoll prüfen.")
            if let self { self.recordDiagnostic("Windows · Anzeige", self.playerStatus) }
        }
    }

    func pointer(x: Int, y: Int, mask: UInt8) {
        if ["windows", "ubuntu"].contains(activeGuest), windowsPasteBusy { return }
        if activeGuest == "android" { androidStream?.pointer(x: x, y: y, mask: mask) }
        else if ["windows", "ubuntu"].contains(activeGuest) { windowsPlayer?.pointer(x: x, y: y, mask: mask) }
    }

    func scroll(x: Int, y: Int, horizontal: Double, vertical: Double, mask: UInt8) {
        let speed = activeGuest == "android" ? androidScrollSpeed : (activeGuest == "ubuntu" ? ubuntuScrollSpeed : windowsScrollSpeed)
        let h = GuestScrollSpeed.scale(horizontal, percent: speed)
        let v = GuestScrollSpeed.scale(vertical, percent: speed)
        if ["windows", "ubuntu"].contains(activeGuest), !windowsPasteBusy { windowsPlayer?.scroll(x: x, y: y, vertical: v, mask: mask) }
        else if activeGuest == "android" { androidStream?.scroll(x: x, y: y, horizontal: h, vertical: v, mask: mask) }
    }
    func swipeAndroid(x: Int, y: Int, horizontal: Double, vertical: Double, phase: GuestTouchScrollPhase) {
        guard activeGuest == "android" else { return }
        androidStream?.swipe(x: x, y: y,
                             horizontal: GuestScrollSpeed.scale(horizontal, percent: androidScrollSpeed),
                             vertical: GuestScrollSpeed.scale(vertical, percent: androidScrollSpeed), phase: phase)
    }
    func resetScroll() { windowsPlayer?.resetScroll() }

    func openWindowsDisplaySettings() {
        if windowsPlayer == nil { sendWindowsKeys(["meta_l", "i"]); return }
        guard running, ["windows", "ubuntu"].contains(activeGuest), !windowsPasteBusy,
              windowsPlayer?.sendKeySequence(WindowsKeyboard.settings) == true else { return }
        playerStatus = L10n.text("Windows + I gesendet · Unter System → Anzeige Auflösung und Windows-Skalierung wählen.")
    }

    func openWindowsExchangeFolder() {
        guard running, activeGuest == "windows", settings.windowsNetwork,
              !windowsPasteBusy, let socket = qmpSocket else { return }
        windowsPasteBusy = true
        Task {
            defer { windowsPasteBusy = false }
            do {
                let address = try WindowsTextInput(text: ExchangeFolder.windowsAddress, layout: windowsTextLayout)
                try await QMPClient.sendKeys(["meta_l", "r"], socket: socket)
                try await Task.sleep(nanoseconds: 600_000_000)
                try await QMPClient.sendKeys(["ctrl", "a"], socket: socket)
                try await QMPClient.typeText(address, socket: socket) { _ in }
                try await QMPClient.sendKeys(["ret"], socket: socket)
                windowsPasteStatus = L10n.text("Austauschordner angefordert. Die SMB-Freigabe muss auf dem Mac eingerichtet sein.")
            } catch { windowsPasteStatus = error.localizedDescription }
        }
    }

    private var exchangeMedia: WindowsExchangeMedia?
    func prepareWindowsExchangeMedia(baseURL: String, publicKey: String? = nil, capture: Bool = false) async throws -> String {
        guard running, activeGuest == "windows", let socket = qmpSocket, let resources = Bundle.main.resourceURL else {
            throw StorageMigration.failure("Windows zuerst starten.")
        }
        let helper = resources.appendingPathComponent("WindowsExchange/Stratovo.exe")
        let media = try await Task.detached(priority: .utility) {
            try WindowsExchangeMedia.create(helper: helper, baseURL: baseURL, publicKey: publicKey, capture: capture)
        }.value
        do {
            try Task.checkCancellation()
            guard running, qmpSocket == socket else { throw CancellationError() }
            try await QMPClient.insertExchangeMedia(media.iso, socket: socket)
        } catch { media.remove(); throw error }
        exchangeMedia?.remove(); exchangeMedia = media
        // Windows needs a moment to enumerate the newly inserted CD.
        try await Task.sleep(nanoseconds: 2_000_000_000)
        return WindowsExchangeMedia.launch
    }

    private var exchangeSSHForward: (socket: String, port: Int)?

    func prepareGuestSSHExchange() async throws -> Int {
        guard running, ["windows", "ubuntu"].contains(activeGuest), (activeGuest != "windows" || settings.windowsNetwork), let socket = qmpSocket else {
            throw StorageMigration.failure("Das gewählte System mit Netzwerk starten.")
        }
        if let forward = exchangeSSHForward, forward.socket == socket { return forward.port }
        for _ in 0..<8 {
            let port = Int.random(in: 49152...65535)
            do {
                try await QMPClient.forwardSSH(port: port, socket: socket)
                guard running, ["windows", "ubuntu"].contains(activeGuest), qmpSocket == socket else { throw CancellationError() }
                exchangeSSHForward = (socket, port)
                return port
            } catch is CancellationError { throw CancellationError() }
            catch { continue }
        }
        throw StorageMigration.failure("SSH-Zugang zur VM nicht verfügbar. Windows neu starten und erneut verbinden.")
    }

    func runGuestExchangeSetup(_ command: String, kind: ExchangeGuest, layout: WindowsTextLayout? = nil, progress: @escaping (Int, Int) -> Void) async throws {
        guard running, activeGuest == kind.rawValue, !windowsPasteBusy, let socket = qmpSocket else {
            throw StorageMigration.failure("Das gewählte System starten und laufende Eingaben abwarten.")
        }
        let input = try WindowsTextInput(text: command, layout: layout ?? windowsTextLayout)
        windowsPasteBusy = true
        defer { windowsPasteBusy = false }
        try Task.checkCancellation()
        try await QMPClient.sendKeys(kind == .windows ? ["meta_l", "r"] : ["alt", "f2"], socket: socket)
        try await Task.sleep(nanoseconds: 900_000_000)
        try await QMPClient.sendKeys(["ctrl", "a"], socket: socket)
        try await QMPClient.typeText(input, socket: socket, interval: 0.12) { progress($0, input.count) }
        try Task.checkCancellation()
        try await QMPClient.sendKeys(["ret"], socket: socket)
    }

    func keyboard(code: UInt16, text: String, down: Bool) {
        if ["windows", "ubuntu"].contains(activeGuest), windowsPasteBusy { return }
        if activeGuest == "android" {
            let special: [UInt16: UInt32] = [36: 66, 51: 67, 48: 61, 53: 111, 123: 21, 124: 22, 125: 20, 126: 19,
                117: 112, 115: 122, 119: 123, 116: 92, 121: 93, 56: 59, 60: 60, 59: 113, 62: 114, 58: 57, 61: 58, 55: 117, 54: 118]
            if let key = special[code] { androidStream?.key(key, down: down) }
            else if down && !text.isEmpty { androidStream?.text(text) }
        } else if ["windows", "ubuntu"].contains(activeGuest) {
            if let symbol = WindowsKeyboard.symbol(code: code, text: text) { windowsPlayer?.key(symbol, down: down) }
        }
    }

    func openWindowsSetupConsole() {
        if windowsPlayer == nil { sendWindowsKeys(["shift", "f10"]); return }
        guard running, ["windows", "ubuntu"].contains(activeGuest), !windowsPasteBusy,
              windowsPlayer?.sendKeySequence(WindowsKeyboard.setupConsole) == true else { return }
        playerStatus = "Shift + F10 an Windows gesendet · Zum Tippen in das Windows-Bild klicken."
    }

    func sendWindowsKeys(_ keys: [String]) {
        guard running, ["windows", "ubuntu"].contains(activeGuest), !windowsPasteBusy, let socket = qmpSocket else { return }
        Task {
            do { try await QMPClient.sendKeys(keys, socket: socket) }
            catch { playerStatus = error.localizedDescription }
        }
    }
    func activateWindows() {
        guard activeGuest == "windows" else { return }
        showPlayer(kind: "windows")
    }
    private var windowsBootArtwork: BootArtwork?
    private func preparePCBootAppearance(firmware: String, root: URL) async throws -> String {
        windowsBootArtwork = nil
        guard let helper = Bundle.main.resourceURL?.appendingPathComponent("GraphicsLab/boot_appearance.py") else { return firmware }
        do {
            let result = try await Self.capture(CommandSpec(executable: "/usr/bin/python3", arguments: [helper.path,
                "--firmware", firmware]), timeout: 30)
            if result.status == 0 {
                windowsBootArtwork = try? JSONDecoder().decode(BootArtwork.self, from: Data(result.output.utf8))
            }
        } catch { recordDiagnostic("Windows · Startlogo", error.localizedDescription) }
        return firmware
    }

    func pasteWindowsText(_ input: WindowsTextInput) {
        guard running, ["windows", "ubuntu"].contains(activeGuest), !windowsPasteBusy, let socket = qmpSocket else { return }
        windowsPasteBusy = true
        windowsPasteStatus = L10n.message("Text wird eingefügt: 0 / \(input.count) Zeichen …")
        windowsPasteTask = Task { [weak self] in
            guard let self else { return }
            var completed = 0
            defer { self.windowsPasteBusy = false; self.windowsPasteTask = nil }
            do {
                try await QMPClient.typeText(input, socket: socket) { count in
                    completed = count
                    self.windowsPasteStatus = L10n.message("Text wird eingefügt: \(count) / \(input.count) Zeichen …")
                }
                self.windowsPasteStatus = L10n.message("\(input.count) Zeichen an Windows übertragen. Bei einem Befehl jetzt Enter im Windows-Fenster drücken.")
            } catch {
                self.windowsPasteStatus = Task.isCancelled
                    ? L10n.text("Einfügen abgebrochen. Bereits übertragener Text bleibt im Windows-Feld stehen.")
                    : L10n.message("Einfügen unterbrochen (\(completed) / \(input.count) Zeichen bestätigt). \(error.localizedDescription)")
            }
        }
    }

    func cancelWindowsPaste() { windowsPasteTask?.cancel() }

    func androidNavigation(_ code: UInt32) { androidStream?.key(code, down: true); androidStream?.key(code, down: false) }

    private func checkGoogleServices(port: Int) async {
        guard let adb, running, androidPort == port else { return }
        do {
            let packages = try await Self.capture(CommandSpec(executable: adb, arguments: ["-s", "emulator-\(port)", "shell", "pm", "list", "packages"]))
            let names = Set(packages.output.components(separatedBy: .newlines))
            let services = names.contains("package:com.google.android.gms")
            let store = names.contains("package:com.android.vending")
            let games = names.contains("package:com.google.android.play.games")
            googleServicesStatus = "Play-Dienste: \(services ? "vorhanden" : "fehlen") · Play Store: \(store ? "vorhanden" : "fehlt") · Play Spiele: \(games ? "installiert" : "im Store verfügbar")"
        } catch { googleServicesStatus = L10n.text("Google-Dienste konnten nicht geprüft werden.") }
    }

    func openPlayGames() { androidIntent(["-a", "android.intent.action.VIEW", "-d", "market://details?id=com.google.android.play.games"]) }
    func openSyncSettings() { androidIntent(["-a", "android.settings.SYNC_SETTINGS"]) }
    func openBackupSettings() { androidIntent(["-a", "android.settings.BACKUP_SETTINGS"]) }
    private func androidIntent(_ arguments: [String]) {
        guard canInstallAPK, let adb, let port = androidPort else { return }
        Task {
            do {
                let result = try await Self.capture(CommandSpec(executable: adb, arguments: ["-s", "emulator-\(port)", "shell", "am", "start"] + arguments))
                if result.status != 0 || result.output.contains("Error:") { throw GuestError.commandFailed(result.status, result.output) }
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func shutdownGuest() {
        windowsPasteTask?.cancel()
        guard running else { return }
        playerStatus = "Geordnetes Herunterfahren angefordert …"
        Task {
            do {
                if let adb, let port = androidPort {
                    _ = try await Self.capture(CommandSpec(executable: adb, arguments: ["-s", "emulator-\(port)", "shell", "reboot", "-p"]))
                } else if let qmpSocket { try await QMPClient.shutdown(socket: qmpSocket) }
            } catch { errorMessage = "Herunterfahren konnte nicht angefordert werden: \(error.localizedDescription)" }
        }
    }

    func chooseAndInstallAPK() {
        guard canInstallAPK, let path = chooseFile(title: L10n.text("APK installieren · einzelne .apk-Datei auswählen")) else { return }
        Task { await installAPK(path) }
    }

    private func installAPK(_ path: String) async {
        guard canInstallAPK, let port = androidPort, let adb else { return }
        apkBusy = true
        apkStatus = L10n.text("APK wird installiert …")
        defer { apkBusy = false }
        do {
            let spec = try LaunchPlan.installAPK(adb: adb, port: port, apk: path)
            let result = try await Self.capture(spec, timeout: 120)
            guard result.status == 0 else { throw GuestError.commandFailed(result.status, result.output) }
            apkStatus = "\(URL(fileURLWithPath: path).lastPathComponent) installiert"
        } catch {
            apkStatus = "APK-Installation fehlgeschlagen"
            errorMessage = error.localizedDescription
        }
    }

    func openGoogleInMacBrowser() {
        // Use the normal browser and its existing profile; no embedded web view or private session.
        let url = URL(string: "https://accounts.google.com/AccountChooser?continue=https%3A%2F%2Fmyaccount.google.com%2F")!
        if !NSWorkspace.shared.open(url) {
            errorMessage = L10n.text("Der Mac-Standardbrowser konnte nicht geöffnet werden. Bitte einen Standardbrowser in macOS festlegen.")
        }
    }

    func openGoogleAccountSettings() {
        guard canInstallAPK, let port = androidPort, let adb else { return }
        Task {
            do {
                let result = try await Self.capture(CommandSpec(executable: adb, arguments: [
                    "-s", "emulator-\(port)", "shell", "am", "start", "-a", "android.settings.ADD_ACCOUNT_SETTINGS"
                ]))
                if result.status != 0 { throw GuestError.commandFailed(result.status, result.output) }
            } catch { errorMessage = error.localizedDescription }
        }
    }

    private func start(_ spec: CommandSpec, title: String) throws {
        guard process == nil else { return }
        guard FileManager.default.isExecutableFile(atPath: spec.executable) else { throw GuestError.missingFile(spec.executable) }
        guard let storage else { throw StorageMigration.failure(L10n.text("Bitte zuerst einen Speicherort wählen.")) }
        try storage.validate()
        let directory = storage.logs
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let kind = title.hasPrefix("Android") ? "android" : (title.hasPrefix("Ubuntu") ? "ubuntu" : "windows")
        let url = directory.appendingPathComponent("\(kind)-session-\(UUID().uuidString).log")
        let header = DiagnosticReport.redact("Stratovo · \(title)\nStart: \(ISO8601DateFormatter().string(from: Date()))\n\(spec.display)\n\n")
        guard FileManager.default.createFile(atPath: url.path, contents: Data(header.utf8), attributes: [.posixPermissions: 0o600]) else { throw GuestError.missingFile(url.path) }
        let handle = try FileHandle(forWritingTo: url)
        _ = try handle.seekToEnd()
        let child = Process()
        child.executableURL = URL(fileURLWithPath: spec.executable)
        child.arguments = spec.arguments
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "STRATOVO_NATIVE_PLAYER")
        environment.removeValue(forKey: "STRATOVO_BOOT_ARTWORK")
        environment.removeValue(forKey: "STRATOVO_DISPLAY_HZ")
        environment.removeValue(forKey: "STRATOVO_APP_ICON")
        if kind == "windows", spec.environment["STRATOVO_NATIVE_PLAYER"] == "1",
           let icon = Bundle.main.url(forResource: "Stratovo", withExtension: "icns") {
            environment["STRATOVO_APP_ICON"] = icon.path
        }
        if kind == "windows", spec.environment["STRATOVO_EMBEDDED_V1"] == nil {
            environment.removeValue(forKey: "STRATOVO_EMBEDDED_V1")
        }
        child.environment = environment.merging(spec.environment) { _, new in new }
        child.standardInput = FileHandle.nullDevice
        child.standardOutput = handle
        child.standardError = handle
        child.terminationHandler = { [weak self] finished in
            let code = finished.terminationStatus
            Task { @MainActor [weak self] in await self?.didExit(code: code) }
        }
        do { try child.run() }
        catch { try? handle.close(); try? FileManager.default.removeItem(at: url); throw error }
        process = child
        output = handle
        logURL = url
        sessionName = title
        lastCommand = spec.display
        sessionCommand = spec.display
        running = true
        if let guestActivity { ProcessInfo.processInfo.endActivity(guestActivity) }
        guestActivity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: L10n.text("Stratovo · interaktive Gastsitzung"))
        lastLogSize = nil; rendererInspected = false
        recordDiagnostic(L10n.text("Gaststart"), "\(title) · \(url.lastPathComponent)")
        stopRequested = false
        windowsFrames.publish(nil)
        playerSize = .zero
        streamFPS = 0
        log = "Prozess gestartet. Der Gast ist erst bereit, wenn sein Startbildschirm sichtbar ist.\n\n\(sessionCommand)\n"
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.readLog() }
        }
    }

    private func readLog() {
        guard logReadTask == nil, let url = logURL else { return }
        let previous = lastLogSize
        let inspectRenderer = activeGuest == "android" && !rendererInspected
        logReadTask = Task { [weak self] in
            let snapshot = await Task.detached(priority: .utility) {
                try? SessionLogReader.read(url: url, previousSize: previous, includeHeader: inspectRenderer)
            }.value
            guard let self else { return }
            defer { self.logReadTask = nil }
            guard self.logURL == url, let snapshot else { return }
            self.lastLogSize = snapshot.size
            let text = self.sessionCommand + "\n\n" + snapshot.tail
            if self.log != text { self.log = text }
            if inspectRenderer {
                let renderer = AndroidRenderer.inspect(snapshot.header + snapshot.tail)
                if renderer.kind != .unknown {
                    self.rendererInspected = true
                    if renderer.summary != self.androidRendererStatus {
                        self.androidRendererStatus = renderer.summary
                        self.androidSoftwareRendering = renderer.kind == .software
                        self.recordDiagnostic("Android · Grafik", renderer.summary)
                    }
                }
            }
        }
    }

    private func didExit(code: Int32) async {
        recordDiagnostic(L10n.text("Gast beendet"), "\(sessionName) · Exit-Code \(code) · Beenden angefordert: \(stopRequested)")
        busy = true
        defer { busy = false }
        exchange.cancelTransfer()
        audio.disconnect()
        appliedAndroidStreamQuality = nil; appliedAndroidTargetFPS = nil
        bootTask?.cancel()
        bootTask = nil
        displayTask?.cancel(); displayTask = nil
        windowsBootProbe?.cancel(); windowsBootProbe = nil
        windowsPasteTask?.cancel()
        await windowsPasteTask?.value
        windowsPasteTask = nil
        windowsPlayer?.stop(); windowsPlayer = nil
        if let androidStream { await androidStream.stop() }
        androidStream = nil
        h264Player.reset()
        androidPort = nil
        androidBooted = false
        activeAndroidOutputMode = nil; androidWindowStatus = ""
        timer?.invalidate()
        timer = nil
        await logReadTask?.value
        readLog()
        await logReadTask?.value
        log += "\n\nProzess beendet · Exit-Code \(code)\n"
        if let logURL { log += "Protokoll: \(logURL.path)\n" }
        try? output?.close()
        output = nil
        process = nil
        running = false
        windowsUsesDirectDisplay = false
        if let guestActivity { ProcessInfo.processInfo.endActivity(guestActivity) }
        guestActivity = nil
        if let windowsSession { await windowsSession.stop() }
        windowsSession = nil
        ubuntuSession?.stop(); ubuntuSession = nil
        exchangeMedia?.remove(); exchangeMedia = nil; exchangeSSHForward = nil
        qmpSocket = nil
        windowsDisplaySocket = nil
        activeGuest = ""
        playerStatus = L10n.text("Gast beendet · Daten bleiben gespeichert")
        sessionName = L10n.text("Kein Gast gestartet")
        if code != 0 && !stopRequested { errorMessage = "Der Gastprozess wurde mit Code \(code) beendet. Details stehen im Protokoll." }
    }

    func terminateGuest() {
        // Only this app's retained Process receives SIGTERM. No killall or global cleanup.
        guard let process, process.isRunning else { return }
        stopRequested = true
        process.terminate()
        log += L10n.text("\nBeenden angefordert. Warte auf den Gastprozess …\n")
    }

    func revealLogs() {
        if let logURL { NSWorkspace.shared.activateFileViewerSelecting([logURL]) }
    }

    func openSetupScript(_ name: String) {
        guard storageReady else { showStorageSetup = true; return }
        guard ["Android_einrichten.command", "Android_Streaming_einrichten.command", "Windows_Treiber_einrichten.command"].contains(name) else { return }
        let bundled = Bundle.main.resourceURL?.appendingPathComponent(name)
        let development = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(name)
        guard let script = [bundled, development].compactMap({ $0 }).first(where: { FileManager.default.isReadableFile(atPath: $0.path) }) else {
            errorMessage = L10n.text("Einrichtungsskript fehlt im App-Paket.")
            return
        }
        NSWorkspace.shared.open([script], withApplicationAt: URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"),
                                configuration: NSWorkspace.OpenConfiguration()) { [weak self] _, error in
            guard let error else { return }
            let detail = error.localizedDescription
            Task { @MainActor in
                self?.errorMessage = L10n.message("Skript konnte nicht geöffnet werden: \(detail)")
            }
        }
    }

    func chooseStorageFolder() {
        let panel = NSOpenPanel()
        panel.title = L10n.text("Speicherort für Android, Windows und Downloads")
        panel.prompt = "Diesen Ort verwenden"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Volumes", isDirectory: true)
        if panel.runModal() == .OK, let parent = panel.url {
            proposedStoragePath = (["Stratovo", "Pixelkoje", "OpenGuest"].contains(parent.lastPathComponent) ? parent : parent.appendingPathComponent("Stratovo")).path
        }
    }

    func configureStorage() {
        guard !busy, !running, !proposedStoragePath.isEmpty else { return }
        let root = URL(fileURLWithPath: proposedStoragePath, isDirectory: true)
        let downloads = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads").path + "/"
        let media = [settings.iso, settings.driversISO].filter { $0.hasPrefix(downloads) && $0.lowercased().hasSuffix(".iso") }
        busy = true
        errorMessage = nil
        storageStatus = L10n.text("Prüfe laufende Programme …")
        Task {
            do {
                try await assertNoStorageWriters()
                let result = try await Task.detached(priority: .userInitiated) { [weak self] in
                    try StorageMigration.prepare(root: root, mediaSources: media) { status in
                        Task { @MainActor [weak self] in self?.storageStatus = status }
                    }
                }.value
                try result.save()
                storage = result
                settings.sdk = result.sdk.path
                if media.contains(settings.iso) { settings.iso = result.url.appendingPathComponent("Installationsmedien").appendingPathComponent(URL(fileURLWithPath: settings.iso).lastPathComponent).path }
                if media.contains(settings.driversISO) { settings.driversISO = result.url.appendingPathComponent("Installationsmedien").appendingPathComponent(URL(fileURLWithPath: settings.driversISO).lastPathComponent).path }
                settings.selectedAVD = ""
                storageTested = false
                updateBackupPaths()
                storageStatus = L10n.text("Speicherort eingerichtet. Vorhandene Daten sind kopiert und per SHA-256 geprüft. Interne Sicherungen bleiben bis zur Bereinigung erhalten.")
                showStorageSetup = false
            } catch { errorMessage = error.localizedDescription; storageStatus = error.localizedDescription }
            busy = false
            if storageReady { await refresh() }
        }
    }

    func updateBackupPaths() {
        backupPaths = storage.flatMap { try? StorageMigration.backupPaths($0) } ?? []
    }

    func confirmStorageCleanup() {
        guard storageTested, !busy, !running, !backupPaths.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = L10n.text("Geprüfte interne Sicherungen endgültig entfernen?")
        alert.informativeText = backupPaths.joined(separator: "\n") + L10n.text("\n\nDie aktiven Daten im gewählten Datenordner bleiben erhalten. Diese Kopien werden ohne Papierkorb entfernt und geben dadurch Speicherplatz frei.")
        alert.addButton(withTitle: "Interne Sicherungen entfernen")
        alert.addButton(withTitle: L10n.text("Abbrechen"))
        if alert.runModal() == .alertFirstButtonReturn { cleanupInternalCopies() }
    }

    func cleanupInternalCopies() {
        guard !busy, !running, storageTested, let storage else { return }
        busy = true
        Task {
            do {
                try await assertNoStorageWriters()
                try await Task.detached(priority: .userInitiated) { [weak self] in
                    try StorageMigration.cleanup(storage) { status in
                        Task { @MainActor [weak self] in self?.storageStatus = status }
                    }
                }.value
                updateBackupPaths()
                storageStatus = L10n.text("Geprüfte interne Sicherungen entfernt. Die aktiven Daten bleiben im gewählten Speicherordner.")
            } catch { errorMessage = error.localizedDescription; storageStatus = error.localizedDescription }
            busy = false
        }
    }

    private func assertNoStorageWriters() async throws {
        let result = try await Self.capture(CommandSpec(executable: "/bin/ps", arguments: ["-axo", "pid=,comm="]))
        guard result.status == 0 else { throw StorageMigration.failure(L10n.text("Laufende Programme konnten nicht geprüft werden.")) }
        for line in result.output.components(separatedBy: .newlines) {
            let parts = line.trimmingCharacters(in: .whitespaces).split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
            guard parts.count == 2, let pid = Int32(parts[0]), pid != getpid() else { continue }
            let name = String(parts[1])
            if name.contains("/emulator/") || name.hasSuffix("/qemu-system-aarch64") ||
                name.contains("Android Studio.app/") || (name.hasSuffix("/Stratovo") || name.hasSuffix("/Pixelkoje") || name.hasSuffix("/OpenGuest")) {
                throw StorageMigration.failure("Bitte Android/Windows herunterfahren, Android Studio und weitere Stratovo-Fenster beenden. Noch aktiv: \(name)")
            }
        }
    }

    private func checkStorageSpace(minimumGB: Int64) throws {
        guard let storage else { throw StorageMigration.failure(L10n.text("Speicherort fehlt.")) }
        try storage.validate()
        if let free = storage.freeBytes, free < minimumGB * 1_000_000_000 {
            throw StorageMigration.failure(L10n.message("Am gewählten Speicherort \(storage.root) sind nur \(ByteCountFormatter.string(fromByteCount: free, countStyle: .file)) frei. Für diesen Start sind mindestens \(minimumGB) GB Reserve vorgesehen."))
        }
    }

    func revealStorage() {
        if let storage, storageReady { NSWorkspace.shared.open(storage.url) }
    }

    func chooseFolder() -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = L10n.text("SDK auswählen")
        return panel.runModal() == .OK ? panel.url?.path : nil
    }

    func chooseFile(title: String) -> String? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        return panel.runModal() == .OK ? panel.url?.path : nil
    }
}

