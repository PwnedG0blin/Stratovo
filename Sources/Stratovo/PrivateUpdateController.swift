import Combine
import Foundation
import StratovoCore

@MainActor
final class PrivateUpdateController: ObservableObject {
    @Published private(set) var connected = false
    @Published private(set) var busy = false
    @Published private(set) var status = "GitHub einmalig verbinden, um private Updates direkt zu installieren."
    @Published private(set) var available: PrivateUpdateArtifact?
    @Published private(set) var needsUnlock = false
    private var token: String?
    private var restored = false
    private var checkedThisSession = false
    private let defaults: UserDefaults
    private let fetchLatest: (String) async throws -> PrivateUpdateArtifact?
    private let installedBuild: Int
    private let readCredential: (Bool) throws -> String?
    private let unlockCredential: () async throws -> String?
    init(installedBuild: Int? = nil, defaults: UserDefaults = .standard,
         fetchLatest: @escaping (String) async throws -> PrivateUpdateArtifact? = { try await PrivateUpdateAPI(token: $0).latest() },
         readCredential: ((Bool) throws -> String?)? = nil) {
        self.installedBuild = installedBuild ?? Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") ?? 0
        self.defaults = defaults
        self.fetchLatest = fetchLatest
        if let readCredential {
            self.readCredential = readCredential
            self.unlockCredential = { try readCredential(true) }
        } else {
            self.readCredential = { try PrivateUpdateCredential.read(allowInteraction: $0) }
            self.unlockCredential = {
                try await Task.detached { try PrivateUpdateCredential.read(allowInteraction: true) }.value
            }
        }
    }
    private let lastAttemptKey = "Stratovo.privateUpdates.lastAttempt"
    func restore() {
        guard !restored else { return }; restored = true
        do {
            token = try readCredential(false); connected = token != nil
            if connected { status = "Privater Updatekanal verbunden." }
        } catch PrivateUpdateCredential.AccessError.authorizationRequired {
            needsUnlock = true; status = "Der gespeicherte GitHub-Zugang benötigt eine Freigabe. Wähle Gespeicherten Zugang freigeben, wenn du nach Updates suchen möchtest."
        } catch { status = error.localizedDescription }
    }
    func unlockSavedCredential() async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        do {
            token = try await unlockCredential(); connected = token != nil
            needsUnlock = false
            if let token { checkedThisSession = true; update(try await fetchLatest(token)) }
            else { status = "Bitte GitHub verbinden." }
        } catch PrivateUpdateCredential.AccessError.authorizationRequired {
            status = "Der gespeicherte Zugang wurde nicht freigegeben. Du kannst es später erneut versuchen."
        } catch { status = safeMessage(error) }
    }
    func connect(_ input: String) async -> Bool {
        guard !busy else { return false }
        let candidate = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty, !candidate.contains("\n"), !candidate.contains("\r") else { return false }
        busy = true; available = nil; status = "GitHub-Zugang wird geprüft …"
        defer { busy = false }
        do {
            let latest = try await fetchLatest(candidate)
            try await Task.detached { try PrivateUpdateCredential.save(candidate) }.value
            checkedThisSession = true
            token = candidate; connected = true; needsUnlock = false; update(latest)
            defaults.set(Date(), forKey: lastAttemptKey)
            return true
        } catch { status = safeMessage(error); return false }
    }
    func disconnect() {
        guard !busy else { return }
        do {
            try PrivateUpdateCredential.remove(); token = nil; connected = false; available = nil; needsUnlock = false
            defaults.removeObject(forKey: lastAttemptKey)
            status = "GitHub-Zugang von diesem Mac entfernt."
        } catch { status = safeMessage(error) }
    }
    func checkIfDue() async {
        if checkedThisSession, let date = defaults.object(forKey: lastAttemptKey) as? Date,
           Date().timeIntervalSince(date) < 60 * 60 { return }
        await check()
    }
    func check() async {
        guard !busy else { return }
        restore()
        guard let token else { if !needsUnlock { status = "Bitte zuerst GitHub verbinden." }; return }
        let previousStatus = status
        checkedThisSession = true
        busy = true; status = "Private Builds werden geprüft …"
        defer { busy = false }
        defaults.set(Date(), forKey: lastAttemptKey)
        do { update(try await fetchLatest(token)) }
        catch {
            if Task.isCancelled { checkedThisSession = false; status = previousStatus; return }
            status = safeMessage(error)
        }
    }
    func install(using installer: AppUpdateInstaller, model: AppModel) async {
        guard !busy, let token, let available else { return }
        busy = true; defer { busy = false }
        await installer.installPrivate(available, token: token, model: model)
    }
    private func update(_ latest: PrivateUpdateArtifact?) {
        guard let latest, let build = latest.build else {
            available = nil
            status = "Noch kein direkt installierbares privates Update vorhanden. DMG-Downloads bleiben über GitHub verfügbar."; return
        }
        if installedBuild > 0 && build > installedBuild {
            available = latest; status = "Private Beta Build \(build) ist verfügbar."
        } else { available = nil; status = "Deine private Beta ist aktuell. Neuester Build: \(build)." }
    }
    private func safeMessage(_ error: Error) -> String {
        if error is PrivateUpdateCredential.AccessError { return error.localizedDescription }
        let domain = (error as NSError).domain
        return ["Stratovo.PrivateUpdates", "Stratovo.Credentials"].contains(domain) ? error.localizedDescription
            : "GitHub-Abfrage fehlgeschlagen. Prüfe die Internetverbindung und versuche es erneut."
    }
}
